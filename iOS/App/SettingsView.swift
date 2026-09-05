import SwiftUI
import GateOpenerCore

/// The Settings screen presented from `MainView`'s gear button (bead
/// gateopener-672.10).
///
/// Every mutation the user can trigger here is routed through
/// `observable.controller` (never a direct write to `AppSettings`), so
/// `onStateChange`-driven observers (the widget snapshot, this screen
/// itself) never drift out of sync — see the routing-rule doc comment on
/// `GateController`.
///
/// Filtering of which endpoints count as candidate gates lives ENTIRELY in
/// `GateClient.candidateGates(from:)` (already applied by both
/// `GateController.refreshGates()` and `performFirstTimeSetup()` before the
/// result is ever persisted to `appSettings.cachedGates`). This view must
/// not re-filter `appSettings.cachedGates` — it is trusted to already be
/// the filtered list.
struct SettingsView: View {
    var environment: AppEnvironment
    var observable: GateControllerObservable
    var appSettings: AppSettings

    @Environment(\.dismiss) private var dismiss

    /// Bumped after every mutation made through this view (gate selection,
    /// toggle flips) so SwiftUI re-renders reads of `appSettings`, which is
    /// a plain (non-`@Observable`) class — see `AppSettings`'s file-level
    /// doc comment on why `GateOpenerCore` cannot depend on the Observation
    /// framework. This mirrors the pattern already used by
    /// `GateControllerObservable` (an app-layer wrapper) but inline, since
    /// this view needs no other wrapping behavior.
    @State private var refreshToken = 0

    @State private var isRefreshing = false
    @State private var refreshErrorMessage: String?
    @State private var isConfirmingSignOut = false

    private var username: String? {
        (try? environment.credentialStore.loadCredentials())?.username
    }

    private var appVersion: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(shortVersion) (\(build))"
    }

    private static let repositoryURL = URL(string: "https://github.com/ebowman/gateopener")!

    /// The one-line unofficial-client disclaimer, mirrored from
    /// `DISCLAIMER.md`'s opening sentence (kept as a literal string here
    /// rather than loaded from the file at runtime, since `DISCLAIMER.md`
    /// is not bundled into the app).
    private static let disclaimerLine =
        "GateOpener is an unofficial, third-party client and is not affiliated with, endorsed by, sponsored by, or in any way officially connected to Comelit Group S.p.A."

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var lastUpdatedText: String {
        guard let date = appSettings.lastDiscoveryDate else { return "Never" }
        return "Last updated \(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    var body: some View {
        NavigationStack {
            Form {
                defaultGateSection
                videoSection
                quickAccessSection
                lockScreenSection
                accountSection
                aboutSection
            }
            // Reading `refreshToken` here (even though its value is never
            // used for anything) registers it as a body dependency, so
            // bumping it after a mutation to the plain (non-`@Observable`)
            // `appSettings` class — see this file's field-level doc
            // comment on `refreshToken` — reliably triggers a re-render of
            // every section above that reads `appSettings` directly.
            .id(refreshToken)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Default gate

    private var defaultGateSection: some View {
        Section {
            if appSettings.cachedGates.isEmpty {
                refreshGatesRow
            } else {
                Picker("Default gate", selection: selectedEndpointIdBinding) {
                    ForEach(appSettings.cachedGates) { gate in
                        Text(gate.friendlyName).tag(Optional(gate.endpointId))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if !appSettings.cachedGates.isEmpty {
                refreshGatesRow
            }

            if let refreshErrorMessage {
                Text(refreshErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Default gate")
        } footer: {
            Text(lastUpdatedText)
        }
    }

    /// A `Binding` over `appSettings.selectedEndpointId` that routes writes
    /// through `controller.selectGate(_:)` (never a direct `AppSettings`
    /// write — see this file's routing-rule doc comment) and re-publishes
    /// the widget snapshot so the widget picks up the new gate name
    /// immediately, not just on the next state transition.
    private var selectedEndpointIdBinding: Binding<String?> {
        Binding(
            get: { appSettings.selectedEndpointId },
            set: { newId in
                guard let newId, let gate = appSettings.cachedGates.first(where: { $0.endpointId == newId }) else { return }
                observable.controller.selectGate(gate)
                environment.publishSnapshot()
                refreshToken += 1
            }
        )
    }

    private var refreshGatesRow: some View {
        Button {
            Task { await refreshGates() }
        } label: {
            HStack {
                Text("Refresh gates")
                Spacer()
                if isRefreshing {
                    ProgressView()
                }
            }
        }
        .disabled(isRefreshing)
    }

    private func refreshGates() async {
        isRefreshing = true
        refreshErrorMessage = nil
        defer { isRefreshing = false }

        do {
            _ = try await observable.controller.refreshGates()
            refreshToken += 1
        } catch {
            refreshErrorMessage = "Could not refresh gates"
        }
    }

    // MARK: - Video

    private var videoSection: some View {
        Section {
            Toggle("Show door camera when opening", isOn: autoShowDoorVideoOnOpenBinding)
        } header: {
            Text("Video")
        }
    }

    private var autoShowDoorVideoOnOpenBinding: Binding<Bool> {
        Binding(
            get: { appSettings.autoShowDoorVideoOnOpen },
            set: { newValue in
                appSettings.autoShowDoorVideoOnOpen = newValue
                refreshToken += 1
            }
        )
    }

    // MARK: - Quick access

    /// Text-only hint row (bead gateopener-672.15 step 3) pointing the
    /// operator at the three one-tap surfaces `OpenGateIntent` powers:
    /// the Control Center control (`GateControl`), the Action Button, and
    /// the Home/Lock Screen widget (`GateWidget`). Deliberately its own
    /// section — named "Quick access" rather than folded into "Lock
    /// Screen" — so gateopener-672.16's "Allow opening while locked"
    /// toggle can still land in `lockScreenSection` without reshuffling
    /// this content.
    private var quickAccessSection: some View {
        Section {
            Text("Control Center: tap + in Control Center, then Add a Control → GateOpener → Open Gate.")
            Text("Action Button: Settings → Action Button → Controls → Open Gate.")
            Text("Home Screen: touch and hold the Home Screen, tap +, then add the GateOpener widget.")
        } header: {
            Text("Quick access")
        } footer: {
            Text("Open the gate from Control Center, the Action Button, or a Home Screen widget without opening this app.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - Lock Screen (reserved for bead gateopener-672.16)

    private var lockScreenSection: some View {
        // Reserved for bead gateopener-672.16: "Allow opening while
        // locked" toggle, wiring `KeychainAccessibility` between
        // `.afterFirstUnlockThisDeviceOnly` (default) and
        // `.whenUnlockedThisDeviceOnly`. Deliberately no UI yet — this
        // section exists only so the Lock Screen section's position in
        // the form is stable once .16 adds its content.
        Section {
            EmptyView()
        } header: {
            Text("Lock Screen")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            if let username {
                Text("Signed in as \(username)")
                    .foregroundStyle(.secondary)
            }

            Button("Sign Out", role: .destructive) {
                isConfirmingSignOut = true
            }
        } header: {
            Text("Account")
        }
        .confirmationDialog(
            "Sign out of GateOpener?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                observable.controller.signOut()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your stored credentials from the Keychain. You will need to sign in again to open the gate.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
            Link("View on GitHub", destination: Self.repositoryURL)
            Text(Self.disclaimerLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("About")
        }
    }
}
