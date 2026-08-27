import AppKit
import SwiftUI
import GateOpenerCore

/// The SwiftUI content of the Settings window (bead gateopener-4ub.9).
///
/// Hosted by `SettingsWindowController` via `NSHostingController`. Binds
/// directly to the shared `GateControllerObservable`, and routes every
/// mutation through `GateControllerObservable.controller` (never writes
/// `AppSettings` directly) so `onStateChange`-driven observers (the status
/// item, this view) stay consistent — see the routing-rule doc comment on
/// `GateController`.
///
/// NOTE on the `aptId` field mentioned in the original bead description:
/// CANCELLED per the bead's notes (live-verified 2026-08-27 as unnecessary
/// for discovery). No aptId control appears anywhere in this view.
struct SettingsView: View {
    @Bindable var observable: GateControllerObservable

    /// Which of the two top-level forms to show, derived from
    /// `observable.state`: `.needsSetup` is the ONLY state that means "no
    /// usable credentials or no selected gate yet" (see `GateState`'s doc
    /// comment in `GateOpenerCore`), so this can never drift from the real
    /// signed-in state the way a separately-tracked `@State` bool could.
    private var isSignedIn: Bool {
        observable.state != .needsSetup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GateOpener Settings")
                .font(.title2)
                .bold()

            LaunchAtLoginSectionView()

            Divider()

            if isSignedIn {
                SignedInView(observable: observable)
            } else {
                SignInFormView(observable: observable)
            }

            Divider()

            LogSectionView(observable: observable)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Launch at Login

/// "Launch at Login" toggle (bead gateopener-4ub.11), backed by
/// `SMAppService.mainApp` via the `LaunchAtLogin` helper.
///
/// Deliberately does NOT keep a persisted/cached boolean of its own: the
/// toggle's `@State` is only ever a mirror of `LaunchAtLogin.isEnabled`
/// (the true `SMAppService.mainApp.status`), refreshed on `.task` (view
/// appears) and again after every write attempt — so it can never show
/// "on" while the system actually has it registered "off" or vice versa.
private struct LaunchAtLoginSectionView: View {
    @State private var isEnabled = false
    @State private var isUpdating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at Login", isOn: launchAtLoginBinding)
                .disabled(isUpdating)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .task {
            refreshFromSystem()
        }
    }

    /// A binding that optimistically reflects the requested value in the
    /// UI, then immediately reconciles `isEnabled` back to the TRUE
    /// post-write status — including on failure, where it reverts to
    /// whatever `SMAppService.mainApp.status` actually reports rather than
    /// trusting the toggle gesture. The toggle never "lies".
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                setEnabled(newValue)
            }
        )
    }

    private func refreshFromSystem() {
        isEnabled = LaunchAtLogin.isEnabled
    }

    private func setEnabled(_ newValue: Bool) {
        errorMessage = nil
        isUpdating = true
        do {
            try LaunchAtLogin.setEnabled(newValue)
        } catch {
            // `LaunchAtLogin.setEnabled` is a typed `throws(LaunchAtLoginError)`,
            // so `error` here is always a `LaunchAtLoginError` carrying a
            // short, human-readable message — never a raw `Error`.
            errorMessage = error.message
        }
        // Reconcile to the REAL status regardless of success or failure —
        // this is what makes the toggle never lie about its state.
        refreshFromSystem()
        isUpdating = false
    }
}

// MARK: - Short, human-readable error mapping (view-layer copy)
//
// `GateController.shortMessage(for:)` (`Sources/GateOpenerCore/GateController.swift`)
// implements the canonical short-message mapping but is `internal` to
// `GateOpenerCore`, not `public`, so it is not visible from this target —
// and that file is off-limits to this bead. This is a small, deliberate
// duplication of the same mapping so this view never surfaces a raw
// `Error` description (which could contain a URL, status body fragment, or
// other implementation detail unsuitable for end-user display). Keep in
// sync with `GateController.shortMessage(for:)` if either changes.
private func shortErrorMessage(for error: Error) -> String {
    if let comelitError = error as? ComelitError {
        switch comelitError {
        case .invalidCredentials:
            return "Wrong username or password"
        case .network, .server, .missingRefreshToken, .decoding:
            return "Could not reach the gate"
        }
    }
    if let gateClientError = error as? GateClientError {
        switch gateClientError {
        case .noEndpointsFound, .noGateFound:
            return "No gate found"
        }
    }
    return "Could not open the gate"
}

// MARK: - Sign-in form (not configured / signed out)

private struct SignInFormView: View {
    let observable: GateControllerObservable

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !isSigningIn && !username.isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in with your Comelit account")
                .font(.headline)

            TextField("Email", text: $username)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                #if os(macOS)
                .textContentType(.username)
                #endif

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                #if os(macOS)
                .textContentType(.password)
                #endif

            HStack {
                Button("Sign In") {
                    signIn()
                }
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)

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
    }

    private func signIn() {
        // Local copies so the password never lingers in `@State` any
        // longer than needed for the call below; both are cleared from
        // `@State` immediately after the attempt completes (success or
        // failure) rather than kept around for redisplay.
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
                // On success the view switches to `SignedInView` because
                // `isSignedIn` (derived from `observable.state`, which
                // `performFirstTimeSetup` updates to `.idle`) flips —
                // nothing further to do here.
                username = ""
            } catch {
                // `.invalidCredentials` must read EXACTLY "Wrong username
                // or password" per the bead's done-criteria; that mapping
                // lives in `shortErrorMessage(for:)` above.
                errorMessage = shortErrorMessage(for: error)
            }
        }
    }
}

// MARK: - Signed-in view

private struct SignedInView: View {
    let observable: GateControllerObservable

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountSectionView(observable: observable)
            Divider()
            GatePickerView(observable: observable)
            Divider()
            TestSectionView(observable: observable)
        }
    }
}

// MARK: - Account section (username, change password, sign out)

private struct AccountSectionView: View {
    let observable: GateControllerObservable

    @State private var isChangingPassword = false
    @State private var newPassword = ""
    @State private var changePasswordUsername = ""
    @State private var isSubmittingChange = false
    @State private var changeError: String?
    @State private var changeSucceeded = false

    @State private var isConfirmingSignOut = false

    /// Read-only display lookups.
    ///
    /// `GateController` (`Sources/GateOpenerCore/GateController.swift`,
    /// off-limits to this bead) does not expose its private
    /// `appSettings`/`credentialStore` for reading, so this view reads them
    /// directly for DISPLAY ONLY — never mutates through them (every
    /// mutation still goes through `observable.controller`'s own methods).
    /// This is safe in both modes: the real `KeychainCredentialStore`'s
    /// service name is a fixed constant (not environment-dependent), and in
    /// `GATEOPENER_MOCK=1` mode the controller itself uses an in-memory
    /// `MockCredentialStore`, so this read never touches (or is touched by)
    /// mock state — it simply returns nil/whatever the real keychain holds.
    /// `AppSettings()` (`.standard`) HAS a known mock-mode caveat: under
    /// `GATEOPENER_MOCK=1` the controller uses a throwaway UserDefaults
    /// suite for its own reads/writes (see the doc comment in
    /// `GateOpenerApp.swift`), so this display-only read of `.standard`
    /// will not reflect the mock gate name while running the self-test —
    /// harmless for the self-test (which never opens Settings) but flagged
    /// here for the human checklist (bead .12).
    private var displayUsername: String? {
        try? KeychainCredentialStore().loadCredentials()?.username
    }

    private var displaySelectedGateName: String? {
        AppSettings().selectedEndpointName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account").font(.headline)

            if let username = displayUsername {
                Text(username)
                    .font(.body)
            }

            if let gateName = displaySelectedGateName {
                Text("Selected gate: \(gateName)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Change password…") {
                    changePasswordUsername = displayUsername ?? ""
                    newPassword = ""
                    changeError = nil
                    changeSucceeded = false
                    isChangingPassword = true
                }

                Button("Sign Out") {
                    isConfirmingSignOut = true
                }
                .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isChangingPassword) {
            ChangePasswordSheet(
                observable: observable,
                username: $changePasswordUsername,
                newPassword: $newPassword,
                isSubmitting: $isSubmittingChange,
                errorMessage: $changeError,
                succeeded: $changeSucceeded,
                isPresented: $isChangingPassword
            )
        }
        .confirmationDialog(
            "Sign out of GateOpener?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                observable.controller.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your stored credentials from the Keychain. You will need to sign in again to open the gate.")
        }
    }
}

/// Modal sheet for "Change password…". Re-saves credentials to the
/// keychain and re-logs in, routed entirely through
/// `controller.performFirstTimeSetup` (the only method that both saves
/// credentials and re-authenticates) rather than a direct
/// `CredentialStore` write.
private struct ChangePasswordSheet: View {
    let observable: GateControllerObservable
    @Binding var username: String
    @Binding var newPassword: String
    @Binding var isSubmitting: Bool
    @Binding var errorMessage: String?
    @Binding var succeeded: Bool
    @Binding var isPresented: Bool

    private var canSubmit: Bool {
        !isSubmitting && !username.isEmpty && !newPassword.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change Password").font(.headline)

            TextField("Email", text: $username)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder)

            if isSubmitting {
                ProgressView().controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if succeeded {
                Text("Password updated.")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Save") {
                    submit()
                }
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func submit() {
        let user = username
        let pass = newPassword
        errorMessage = nil
        isSubmitting = true

        Task { @MainActor in
            defer {
                isSubmitting = false
                // Never linger in `@State` beyond the call.
                newPassword = ""
            }
            do {
                try await observable.controller.performFirstTimeSetup(username: user, password: pass)
                succeeded = true
            } catch {
                errorMessage = shortErrorMessage(for: error)
            }
        }
    }
}

// MARK: - Gate picker

private struct GatePickerView: View {
    let observable: GateControllerObservable

    @State private var candidates: [Endpoint] = []
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var selectedEndpointId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gate").font(.headline)

            HStack {
                if candidates.isEmpty {
                    Text("No candidates yet — tap Refresh.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Gate", selection: Binding(
                        get: { selectedEndpointId ?? AppSettings().selectedEndpointId },
                        set: { newId in
                            selectedEndpointId = newId
                            if let endpoint = candidates.first(where: { $0.endpointId == newId }) {
                                observable.controller.selectGate(endpoint)
                            }
                        }
                    )) {
                        ForEach(candidates) { endpoint in
                            Text(pickerLabel(for: endpoint))
                                .tag(Optional(endpoint.endpointId))
                        }
                    }
                    .labelsHidden()
                }

                Button {
                    refresh()
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(isRefreshing)
            }

            if let refreshError {
                Text(refreshError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .task {
            // Best-effort initial population so the picker is not empty on
            // first open; a failure here is inline-only and never clears
            // any existing selection (there is none to clear yet at this
            // point beyond what AppSettings already has).
            refresh()
        }
    }

    private func pickerLabel(for endpoint: Endpoint) -> String {
        let category = endpoint.displayCategories.first ?? "device"
        return "\(endpoint.friendlyName) — \(category)"
    }

    private func refresh() {
        isRefreshing = true
        refreshError = nil

        Task { @MainActor in
            defer { isRefreshing = false }
            do {
                let result = try await observable.controller.refreshGates()
                candidates = result
            } catch {
                // Discovery failure: show inline, and — critically — do NOT
                // clear `candidates` (leaves any already-working selection
                // visible/usable) or touch AppSettings.
                refreshError = shortErrorMessage(for: error)
            }
        }
    }
}

// MARK: - Test button

private struct TestSectionView: View {
    let observable: GateControllerObservable

    @State private var isTesting = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test").font(.headline)

            Button {
                runTest()
            } label: {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Test — this will actually open the gate")
                }
            }
            .disabled(isTesting)

            if let resultMessage {
                Text(resultMessage)
                    .foregroundStyle(resultIsError ? .red : .green)
                    .font(.callout)
            }
        }
    }

    private func runTest() {
        isTesting = true
        resultMessage = nil
        resultIsError = false

        Task { @MainActor in
            await observable.controller.openGate()
            isTesting = false
            switch observable.state {
            case .succeeded:
                resultMessage = "Gate opened successfully."
                resultIsError = false
            case .failed(let message):
                resultMessage = message
                resultIsError = true
            default:
                // .opening/.idle/.needsSetup: openGate() already awaited
                // completion, so this is only reachable if the auto-reset
                // already fired back to .idle before this line ran.
                resultMessage = nil
            }
        }
    }
}

// MARK: - Log section

/// "Show Log" disclosure with a Copy button (bead gateopener-4ub.10).
///
/// Reads `observable.eventLog` (set once by `AppDelegate` — see
/// `GateOpenerApp.swift`) and renders its current contents via
/// `EventLog.formattedText()`. Read-only: this view never calls any
/// mutating method on `EventLog` (no `clear()`, no direct `append`; there
/// is no public `append` to call anyway).
private struct LogSectionView: View {
    let observable: GateControllerObservable

    @State private var isExpanded = false
    @State private var didCopy = false

    private var logText: String {
        observable.eventLog?.formattedText() ?? ""
    }

    var body: some View {
        DisclosureGroup("Show Log", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if logText.isEmpty {
                    Text("No events logged yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ScrollView {
                        Text(logText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }

                HStack {
                    Button("Copy") {
                        copyLogToPasteboard()
                    }
                    .disabled(logText.isEmpty)

                    if didCopy {
                        Text("Copied.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func copyLogToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logText, forType: .string)
        didCopy = true
    }
}
