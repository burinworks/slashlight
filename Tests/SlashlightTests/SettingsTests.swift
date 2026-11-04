import Foundation
import Testing
@testable import Slashlight

@Suite("Settings")
struct SettingsTests {
    @Test func newSettingsStartTheWelcomeTour() {
        #expect(Settings().onboardingCompleted == false)
    }

    @Test func settingsFromBeforeTheTourSkipIt() throws {
        let old = #"{"hotkey": "cmd+space", "appearance": "dark"}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(s.hotkey == "cmd+space")
        #expect(s.onboardingCompleted)
    }

    @Test func onboardingFlagRoundTrips() throws {
        var s = Settings()
        s.onboardingCompleted = true
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let fresh = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings()))
        #expect(fresh.onboardingCompleted == false)
    }

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
