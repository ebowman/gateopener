import SwiftUI
import GateOpenerCore

/// Sign-in screen shown whenever `GateControllerObservable.state ==
/// .needsSetup` (see `RootView`).
///
/// Calls `GateController.performFirstTimeSetup(username:password:)`, which
/// logs in, discovers gates, and auto-selects the top-ranked candidate
/// (`GateClient.candidateGates` ranks `LOCK_GENERIC` first) — see that
/// method's doc comment in `Sources/GateOpenerCore/GateController.swift`.
/// Because selection is fully automatic, this screen never needs a
/// multi-gate picker: on success `state` leaves `.needsSetup` and
/// `RootView` switches away on its own; on failure (including
/// `GateClientError.noGateFound`, i.e. discovery succeeded but yielded no
/// candidate) a short inline message is shown here instead.
struct SignInView: View {
    let observable: GateControllerObservable

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !isSigningIn && !username.isEmpty && !password.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $username)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            }

            Section {
                HStack {
                    Button("Sign In") {
                        signIn()
                    }
                    .disabled(!canSubmit)

                    if isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Text("Your credentials are stored only in this device's Keychain, never synced, and are used to keep you signed in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sign In")
        #if DEBUG
        .onAppear(perform: runDebugSignInAttemptIfRequested)
        #endif
    }

    /// Local copies so the password never lingers in `@State` any longer
    /// than needed for the call below; both are cleared from `@State`
    /// immediately after the attempt completes (success or failure)
    /// rather than kept around for redisplay. A second tap while a
    /// request is already in flight is a no-op because `canSubmit` (and
    /// therefore the button's `disabled` state) already covers it, and
    /// this guard covers the `onSubmit` (Return key) path too, which does
    /// not go through the button's `disabled` modifier.
    private func signIn() {
        guard canSubmit else { return }

        let user = username
        let pass = password

        errorMessage = nil
        isSigningIn = true

        Task { @MainActor in
            defer {
                isSigningIn = false
                // Never keep the password around longer than the call.
                password = ""
            }
            do {
                try await observable.controller.performFirstTimeSetup(username: user, password: pass)
                // On success `RootView` switches away because `state`
                // (mirrored by `observable.state`) leaves `.needsSetup` —
                // nothing further to do here.
                username = ""
            } catch {
                errorMessage = shortErrorMessage(for: error)
            }
        }
    }

    #if DEBUG
    /// Debug-only launch-argument hook so this screen's failure path can
    /// be exercised end to end on a simulator without a human typing into
    /// the fields (see bead gateopener-672.8's verification steps).
    ///
    /// Launch with:
    ///   `--signin-debug-attempt <username> <password>`
    /// and this pre-fills both fields and submits automatically on
    /// appear. Gated by `#if DEBUG` (and, for safety, the `#if DEBUG`
    /// build config only — this code is compiled out of Release/App
    /// Store builds entirely, not just skipped at runtime) so it can
    /// never ship or run in production.
    private func runDebugSignInAttemptIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--signin-debug-attempt"),
              arguments.count > flagIndex + 2 else { return }
        username = arguments[flagIndex + 1]
        password = arguments[flagIndex + 2]
        signIn()
    }
    #endif
}

// MARK: - Short, human-readable error mapping (view-layer copy)
//
// `GateController.shortMessage(for:)` (`Sources/GateOpenerCore/
// GateController.swift`) implements the canonical short-message mapping
// but is `internal` to `GateOpenerCore`, not `public`, so it is not
// visible from this target — and that file is off-limits to this bead.
// This is a deliberate, sign-in-specific variant of the same idea already
// established in `Sources/GateOpener/SettingsView.swift` for the macOS
// app: the wording here is tailored to the sign-in context (nothing is
// being "opened" yet on this screen), so it intentionally does NOT match
// `shortMessage(for:)`/`shortErrorMessage(for:)` verbatim. It still never
// surfaces a raw `Error` description (which could contain a URL, status
// body fragment, or other implementation detail unsuitable for end-user
// display).
private func shortErrorMessage(for error: Error) -> String {
    if let comelitError = error as? ComelitError {
        switch comelitError {
        case .invalidCredentials:
            return "Wrong username or password"
        case .network:
            return "Can't reach Comelit. Check your connection and try again."
        case .server, .missingRefreshToken, .decoding:
            return "Sign-in failed. Please try again."
        }
    }
    if let gateClientError = error as? GateClientError {
        switch gateClientError {
        case .noEndpointsFound, .noGateFound:
            return "No gate found on this account"
        }
    }
    // `URLError` (offline, timeout, host not found, etc.) surfaces
    // directly from `URLSession` rather than being wrapped in
    // `ComelitError.network` in every code path, so it needs its own
    // check here to land on the network message rather than the generic
    // sign-in fallback below.
    if error is URLError {
        return "Can't reach Comelit. Check your connection and try again."
    }
    return "Sign-in failed. Please try again."
}
