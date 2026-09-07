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
                errorMessage = GateErrorMessage.signIn(for: error)
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
