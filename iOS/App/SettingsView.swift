import SwiftUI

/// Placeholder Settings screen presented from `MainView`'s gear button.
///
/// This is a deliberate stub: the real default-actuator picker, Refresh,
/// account/sign-out, video toggle, and version display are bead
/// gateopener-672.10, which replaces this file's body wholesale. Kept in
/// its own file (rather than nested inside `MainView.swift`) for exactly
/// that reason — .10 only has to touch this one file.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Settings are coming in bead 672.10.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
