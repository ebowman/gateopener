# Comelit cloud API — reverse-engineered protocol notes

This document records the shape of the Comelit cloud API that GateOpener
depends on. None of this is published or documented by Comelit; it was
derived by observing the traffic of the operator's own account, on their own
network, using their own credentials — the same technique any developer uses
to interoperate with a service their own device already legitimately talks
to. This document, and the code in `Sources/GateOpenerCore`, are the extent
of what was captured; no attempt was made to explore the API beyond what
GateOpener itself needs.

Nothing here should be treated as official or stable. Comelit can change any
of it at any time without notice, and this app has no relationship with
Comelit beyond being a client of the same public cloud endpoints their own
mobile app uses.

## Base URL and client identity

- API base: `https://api.comelitgroup.com`
- OAuth redirect URI: `https://app.comelitgroup.com/oauth_redirect/comelit`
- `User-Agent: ktor-client` — matches the Comelit Android app's HTTP client
  and is sent on every request; a different UA has not been verified to work.
- `clientId: kgDV0WRlQcSF4jPsz887lOTPyVVtP7Oh` — a public client id baked
  into the Comelit mobile app itself, the same for every user. This is not a
  per-account secret; it identifies "the Comelit app" as an OAuth client, not
  a user or a device.

## Authentication: OAuth2 Authorization Code + PKCE

Login is a standard two-step Authorization Code flow with PKCE, but the code
verifier is generated in a non-standard way:

- **PKCE verifier**: a lowercase UUIDv4 string (e.g.
  `3f9a1c2e-...`), not raw random bytes as PKCE normally recommends. This
  matches what the real Comelit app does, and the server only accepts this
  shape.
- **PKCE challenge**: `base64url(SHA256(verifier))` with padding stripped
  (`S256` method) — standard PKCE from that point on.

**Step 1 — `POST /o-auth-2/auth`** with a JSON body:

```json
{
  "username": "...",
  "password": "...",
  "responseType": "code",
  "clientId": "kgDV0WRlQcSF4jPsz887lOTPyVVtP7Oh",
  "redirectUri": "https://app.comelitgroup.com/oauth_redirect/comelit",
  "scope": "all",
  "state": "<uuid>",
  "codeChallenge": "<S256 challenge>",
  "codeChallengeMethod": "S256"
}
```

The authorization `code` comes back in one of several shapes depending on
server mood, and GateOpener checks all of them in order: a `location` field
in the JSON body (a URL whose query string carries `code=...`), a bare
`code` field, an HTTP `Location` header, or the final (possibly redirected)
response URL's query string. Wrong credentials do not reliably come back as
a distinct HTTP status — they are detected by the response **body**
containing the literal substring `wrong_username_or_password`, regardless of
status code.

**Step 2 — `POST /o-auth-2/token`** exchanges the code for tokens using a
standard `authorization_code` grant, `client_id`, `redirect_uri`, `scope`,
`code`, and `code_verifier` (the original PKCE verifier).

**Refresh** uses a standard `refresh_token` grant against the same token
endpoint.

Tokens are treated as expired 5 minutes before their real expiry (a
deliberate skew) so a caller never starts a request with a token that could
die mid-flight.

## Device discovery

**`GET /servicerest/devicecom/endpoints/discovery`**, with an optional
`aptId` query parameter (the Comelit "apartment id").

**Load-bearing finding: `aptId` is not required.** Discovery was verified
live against the real API with the parameter omitted entirely (not sent as
empty — omitted), and it returns the identical set of endpoints as with it
present. GateOpener therefore never asks the user for an `aptId` and never
ships one as a default; it treats `aptId` as purely optional, derived after
the fact (see below), never required up front. Do not "fix" this back to
required — it isn't.

Each endpoint in the response array looks like:

```json
{
  "endpointId": "_DA_<aptId>_<deviceUuid>-00001_VIP#OD#SB100001.1",
  "friendlyName": "Front Gate",
  "capabilities": ["PowerController"],
  "displayCategories": ["LOCK_GENERIC"]
}
```

`aptId` can be parsed back out of any `endpointId` you already have (it's
the third `_`-separated component) — GateOpener does this once discovery
returns, purely so it can be passed to *subsequent* discovery calls as a
minor optimization; it is never required for the *first* call.

### Picking the real gate out of the endpoint list

An account's endpoint list mixes real gate locks with cameras, doorbells,
and — critically — a **decoy actuator** that looks exactly like a working
gate lock at the API level but is not wired to anything physical:

- It advertises `PowerController` in `capabilities`, exactly like a real
  gate.
- Sending it an open command returns HTTP 202, exactly like a real gate.
- It simply does nothing. Offering it as "the gate" in a UI means a person
  presses a button that appears to work and nothing happens.

GateOpener calls this the **Generic Actuator trap** and filters it out with
two independent discriminators, so that either one alone is enough to catch
it:

1. **By id**: the known-bad actuator's endpoint id ends in the exact
   component `VIP#OD#SBIO0255.0`. The match is case-insensitive, trims
   whitespace, and only matches when that string is the *entire final*
   `_`-separated component of the id — not merely a suffix — so a sibling id
   like `...VIP#OD#SBIO0299.0` (untested, possibly a real device) is not
   swept up in the exclusion.
2. **By category**: any endpoint whose `displayCategories` includes
   `VIP_ACTUATOR` is excluded outright, regardless of its id. Real gates
   report `LOCK_GENERIC` instead. This category check also catches untested
   siblings of the known decoy without needing a blanket id-family ban.

Among what survives both filters, endpoints reporting `LOCK_GENERIC` in
`displayCategories` are ranked first, since that's what real gates report.

## Opening the gate

**`PUT /servicerest/devicecom/endpoint/{percent-encoded endpointId}/power`**
with body `{"value":true}`.

There is deliberately no "close" or "toggle" call anywhere in this codebase.
Sending `{"value":false}` causes the live API to return HTTP 500 — it is not
a supported operation for this device class, and GateOpener never sends it.

Success is HTTP 202 (the documented code) or HTTP 200 (accepted
defensively, observed occasionally in practice).

### Retry behavior

The live API is not perfectly reliable, so `open` retries with bounded
exponential backoff (base ~400ms, jittered, capped at ~6s of total sleep
across attempts, 3 attempts by default, 3s per-request timeout):

- **Retried**: any HTTP 5xx, HTTP 429, and transport-level (network) errors.
- **Not retried**: other 4xx statuses (e.g. 400, 403) — these indicate a
  request the server will never accept no matter how many times it's sent.
- **HTTP 401**: treated specially — the cached token is invalidated and
  exactly one additional retry is made with a freshly resolved token, on top
  of (not consuming from) the normal retry budget, but still bounded overall
  by the attempt limit so a persistently-401ing server cannot loop forever.
- **Wrong credentials** (`invalidCredentials`, detected during token
  resolution, not during the open call itself) are never retried — retrying
  a wrong password against a live account-security-sensitive service is
  actively harmful and could contribute to a lockout.

## Live door-camera video (WebRTC)

GateOpener's door-camera feature exists in a separate, harder-won layer.
That protocol (single-round-trip WebRTC signaling with no trickle ICE, the
libwebrtc-fingerprinting behavior, the ~28–30s session limit, and the
Chromium-canvas-capture workaround) is Comelit-account traffic captured and
documented in exhaustive, hard-won detail in the sibling reference
implementation's history and is out of scope to duplicate here; see that
project's own documentation if you are extending this app's video path.
