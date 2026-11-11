import SwiftUI

/// The Updates section of Settings → General.
struct UpdateSettings: View {
    @ObservedObject var model: SettingsModel

    private var version: String { BuildInfo.fullVersion }

    var body: some View {
        Section("Updates") {
            Toggle("Automatically install updates", isOn: model.binding(\.autoInstallUpdates))
            Toggle(isOn: model.binding(\.betaUpdates)) {
                Text("Join the beta program")
                Text("Get new features early. Leaving keeps you on the beta until a newer stable version ships.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            } label: {
                Text("Version \(version)")
                if !Updater.shared.isAvailable {
                    Text(BuildInfo.isPreview ? "\(BuildInfo.name) doesn't update itself: install a newer build to update it"
                         : "Updates work in release builds").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!Updater.shared.isAvailable)
    }
}
