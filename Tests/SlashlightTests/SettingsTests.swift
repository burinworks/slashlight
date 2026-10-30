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

    @Test func statisticsStayUnaskedUntilChosen() throws {
        #expect(Settings().shareStatistics == nil)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"hotkey": "opt+space"}"#.utf8))
        #expect(old.shareStatistics == nil)
        for choice in [true, false] {
            var s = Settings()
            s.shareStatistics = choice
            let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(back.shareStatistics == choice)
        }
    }
}
