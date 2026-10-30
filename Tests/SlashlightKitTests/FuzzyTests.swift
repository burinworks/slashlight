import Testing
@testable import SlashlightKit

@Suite("Fuzzy matching")
struct FuzzyTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(Fuzzy.score("", "Safari") == 0)
        #expect(Fuzzy.score("   ", "Safari") == 0)
    }

    @Test func noMatchIsNil() {
        #expect(Fuzzy.score("xyz", "Safari") == nil)
    }

    @Test func caseInsensitive() {
        #expect(Fuzzy.score("SAF", "safari") != nil)
    }

    @Test func prefixBeatsWordStartBeatsMiddle() throws {
        let prefix = try #require(Fuzzy.score("term", "Terminal"))
        let wordStart = try #require(Fuzzy.score("term", "New Terminal"))
        let middle = try #require(Fuzzy.score("term", "Determine"))
        #expect(prefix > wordStart)
        #expect(wordStart > middle)
    }

    @Test func substringBeatsSubsequence() throws {
        let substring = try #require(Fuzzy.score("code", "Visual Studio Code"))
        let subsequence = try #require(Fuzzy.score("vsc", "Visual Studio Code"))
        #expect(substring > subsequence)
    }

    @Test func subsequenceAcrossWords() {
        #expect(Fuzzy.score("vsc", "Visual Studio Code") != nil)
        #expect(Fuzzy.score("csv", "Visual Studio Code") == nil)
    }

    @Test func shorterTextRanksHigherForSameMatch() throws {
        let short = try #require(Fuzzy.score("mail", "Mail"))
        let long = try #require(Fuzzy.score("mail", "Mailspring Beta Edition"))
        #expect(short > long)
    }

    @Test func bestFieldWins() throws {
        let best = try #require(Fuzzy.score("sw", ["Window Switcher", "switch"]))
        let title = try #require(Fuzzy.score("sw", "Window Switcher"))
        #expect(best >= title)
        #expect(Fuzzy.score("zz", ["a", "b"]) == nil)
    }
}
