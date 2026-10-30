import Foundation
import Testing
@testable import Slashlight

@Suite("Settings file")
struct SettingsTests {
    @Test func olderFilesGetUpdateDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"hotkey": "cmd+space"}"#.utf8))
        #expect(s.hotkey == "cmd+space")
        #expect(s.autoInstallUpdates)
        #expect(!s.betaUpdates)
    }

    @Test func updateSwitchesRoundTrip() throws {
        var s = Settings()
        s.autoInstallUpdates = false
        s.betaUpdates = true
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)) == s)
    }
}
