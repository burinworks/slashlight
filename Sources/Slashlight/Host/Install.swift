import AppKit
import ServiceManagement

/// Telling a new installation from a relaunch or an update, and removing the app.
@MainActor
enum Install {
    /// Identifies this copy of the app on disk. Copying it from a disk image again makes a new folder, so the
    /// marker changes; relaunching or moving it within the disk keeps it. Updates change it too, but the updater
    /// sets `updateInstalling` first.
    static var marker: String? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
              let file = attrs[.systemFileNumber], let disk = attrs[.systemNumber] else { return nil }
        return "\(disk):\(file)"
    }

    /// Called at launch: a new installation shows the welcome tour again.
    static func noteLaunch() {
        guard let marker else { return }
        let s = Host.shared.settings
        guard marker != s.installMarker || s.updateInstalling else { return }
        // An unknown previous marker means this version is the first to record one: not a reinstall.
        let reinstalled = s.installMarker != nil && marker != s.installMarker && !s.updateInstalling
        Host.shared.update {
            $0.installMarker = marker
            $0.updateInstalling = false
            if reinstalled { $0.onboardingCompleted = false }
        }
    }

    static func confirmUninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall \(BuildInfo.name)?"
        alert.informativeText = "Moves \(Bundle.main.bundleURL.lastPathComponent) to the Trash, removes its permissions and its login item, and quits. Installing it again starts with the welcome tour."
        alert.alertStyle = .warning
        let data = NSButton(checkboxWithTitle: "Also delete settings, clipboard history, snippets, scripts and extensions", target: nil, action: nil)
        data.state = .on
        alert.accessoryView = data
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uninstall(deleteData: data.state == .on)
    }

    static func uninstall(deleteData: Bool) {
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "All", id]
            try? task.run()
            task.waitUntilExit()
        }
        if deleteData {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ClipboardVault.service] as CFDictionary)
            try? FileManager.default.removeItem(at: Paths.support)
        } else {
            Host.shared.update { $0.onboardingCompleted = false }
        }
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            NSWorkspace.shared.recycle([app]) { _, _ in
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Shows the welcome tour now and on the next launch until it is finished.
    static func resetOnboarding() {
        Host.shared.update { $0.onboardingCompleted = false }
        OnboardingWindowController.shared.show()
    }
}
