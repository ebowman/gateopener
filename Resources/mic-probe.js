// Bead gateopener-1pm.1 SPIKE probe body: answers, from INSIDE
// `door-video.html`'s own `file://` page (loaded via `loadFileURL`, exactly
// as `DoorVideoSession` loads it), whether `navigator.mediaDevices
// .getUserMedia({audio:true})` works at all, and -- per this bead's NOTES
// (the viewdoor-capture-2026-09-27 analysis) -- whether, once granted, a
// throwaway `RTCPeerConnection`'s local SDP contains a real (non-mDNS) LAN
// host candidate.
//
// Deliberately a SEPARATE file from door-video.html: this is a one-off
// diagnostic, never part of the production negotiation path, and must never
// be able to accidentally affect it.
//
// Swift (`MicProbe.swift`) wraps this file's TEXT (not a function
// declaration -- this is a plain statement list) as the body of an async
// arrow function IIFE passed to `WKWebView.callAsyncJavaScript`, i.e.
// effectively:
//   return await (async () => { <this file's contents> })();
// so a bare top-level `return JSON.stringify(result);` at the end is valid
// and is what `callAsyncJavaScript` receives back as its `Any?` result.
//
// NEVER logs a full IP address -- only the first two octets of any host
// candidate address found (matching `door-video.html`'s own diag()
// privacy rule) -- and never logs anything beyond the mic track's LABEL
// (never a device id).

const result = {
  isSecureContext: window.isSecureContext,
  hasMediaDevices: typeof navigator.mediaDevices !== "undefined" && navigator.mediaDevices !== null,
};

let gum;
if (result.hasMediaDevices) {
  // Raced against a 10s timeout (bead gateopener-1pm.1 fix pass): the probe's
  // web view is not always guaranteed a live prompt path (e.g. if the host
  // app fails to attach it to a window before this runs), and an unanswered
  // `getUserMedia` call never rejects on its own -- it just hangs forever,
  // which would otherwise wedge this whole probe (and, via `run()`, the
  // "Run mic probe" Settings row) indefinitely instead of reporting a clear
  // diagnostic.
  const TIMEOUT_MS = 10000;
  try {
    const stream = await Promise.race([
      navigator.mediaDevices.getUserMedia({ audio: true }),
      new Promise((_, reject) => {
        setTimeout(() => reject(new Error("no prompt answer in " + (TIMEOUT_MS / 1000) + "s")), TIMEOUT_MS);
      }),
    ]);
    const track = stream.getAudioTracks()[0];
    gum = "ok:" + (track ? track.label : "");
    if (track) {
      track.stop();
    }
  } catch (e) {
    if (e && e.message && e.message.indexOf("no prompt answer") !== -1) {
      gum = "error:Timeout: " + e.message;
    } else {
      gum = "error:" + (e && e.name) + ": " + (e && e.message);
    }
  }
} else {
  gum = "error:unavailable: navigator.mediaDevices is undefined";
}
result.gum = gum;

// Host-candidate baseline probe (bead 1pm.1 NOTES): run REGARDLESS of
// whether getUserMedia above succeeded, so a failure still tells us the
// baseline (expected: "mdns-only", since WebKit only lifts mDNS filtering
// for a document once getUserMedia has been GRANTED).
// NOTE (bead gateopener-1pm.1 fix pass): `window.__ICE_SERVERS__` is
// deliberately NEVER injected by `MicProbe.swift` -- unlike
// `DoorVideoSession.injectIceServers(_:)`, which requires a real session's
// authenticated STUN/TURN config fetch (a network round trip through
// `ComelitAPI`/token machinery this probe intentionally has none of, per
// `MicProbe`'s own doc comment). An empty `iceServers` list is fine for the
// host-candidate check below: it only inspects LOCAL "typ host" candidates
// in the offer's SDP, which are gathered from the device's own network
// interfaces and do not depend on any STUN/TURN server being configured.
let hostCandidate;
try {
  const iceServers = (window.__ICE_SERVERS__ && window.__ICE_SERVERS__.length) ? window.__ICE_SERVERS__ : [];
  const pc = new RTCPeerConnection({ iceServers: iceServers.map((url) => ({ urls: url })) });
  // Same m-line order as door-video.html's real recipe (audio before
  // video) -- not load-bearing for THIS throwaway pc (it is closed right
  // after gathering and never sent anywhere), but kept identical so this
  // probe cannot mislead by testing a shape the real page does not use.
  pc.addTransceiver("audio", { direction: "recvonly" });
  pc.addTransceiver("video", { direction: "recvonly" });
  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  await new Promise((resolve) => {
    if (pc.iceGatheringState === "complete") {
      resolve();
      return;
    }
    const timeoutId = setTimeout(() => {
      pc.removeEventListener("icegatheringstatechange", onChange);
      resolve();
    }, 5000);
    function onChange() {
      if (pc.iceGatheringState === "complete") {
        clearTimeout(timeoutId);
        pc.removeEventListener("icegatheringstatechange", onChange);
        resolve();
      }
    }
    pc.addEventListener("icegatheringstatechange", onChange);
  });

  const sdp = (pc.localDescription && pc.localDescription.sdp) || "";
  const hostLines = sdp.split("\r\n").filter((line) => line.indexOf(" typ host") !== -1);
  const nonMdnsLine = hostLines.find((line) => line.toLowerCase().indexOf(".local") === -1);

  if (nonMdnsLine) {
    // "candidate:<foundation> <component> <proto> <priority> <address> <port> typ host ..."
    const match = nonMdnsLine.match(/candidate:\S+ \d+ (udp|tcp) \d+ (\S+) \d+ typ host/i);
    if (match) {
      const proto = match[1].toLowerCase();
      const address = match[2];
      const octets = address.split(".");
      if (octets.length === 4) {
        hostCandidate = octets[0] + "." + octets[1] + ".x.x " + proto + " host";
      } else {
        // IPv6 or unrecognized -- never logged verbatim.
        hostCandidate = proto + " host (non-IPv4)";
      }
    } else {
      hostCandidate = "host (unparsed)";
    }
  } else if (hostLines.length > 0) {
    hostCandidate = "mdns-only";
  } else {
    hostCandidate = "none";
  }

  pc.close();
} catch (e) {
  hostCandidate = "error:" + (e && e.name);
}
result.hostCandidate = hostCandidate;

return JSON.stringify(result);
