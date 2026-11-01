import SwiftUI

/// The Updates section of Settings → General.
struct UpdateSettings: View {
    @ObservedObject var model: SettingsModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        return "\(short) (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

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
                    Text("Updates work in release builds").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!Updater.shared.isAvailable)
    }
}
