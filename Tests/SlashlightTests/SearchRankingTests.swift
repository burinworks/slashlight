import Foundation
import SlashlightKit
import Testing
@testable import Slashlight

@Suite("Main search ranking") @MainActor
struct SearchRankingTests {
    private func item(_ id: String, _ title: String) -> Item { Item(id: id, title: title, primary: Action("Open") { .close }) }

    /// What the main search gets back for a query, in the order the extensions answer.
    private func results(apps: [String], extensions: [(String, String)] = [], web: Bool = true) -> [(String?, Section)] {
        var parts: [(String?, Section)] = [("apps", Section("Applications", apps.map { item("/Applications/\($0).app", $0) }))]
        parts += extensions.map { ($0.0, Section("Extensions", [item("open-\($0.0)", $0.1)])) }
        if web { parts.append(("web-search", Section("Search the Web", [item("google", "Search Google")]))) }
        return parts
    }

    private func titles(_ parts: [(String?, Section)]) -> [String] { parts.map(\.1.title) }
    private func topHit(_ parts: [(String?, Section)]) -> String? {
        parts.first { $0.1.title == RootRanking.topHit }?.1.items.first?.title
    }

    @Test func aWordThatStartsWithTheQueryBeatsLettersInsideAWord() {
        let parts = results(apps: ["About This Mac", "Keychain Access"], extensions: [("clipboard", "Clipboard History")])
        let ranked = RootRanking.rank(parts, query: "his", topHit: true) { _ in 0 }
        #expect(topHit(ranked) == "Clipboard History")
        #expect(titles(ranked) == ["Top Hit", "Applications", "Search the Web"])
    }

    @Test func anAppWhoseNameStartsWithTheQueryStillWins() {
        let parts = results(apps: ["Safari"], extensions: [("snippets", "Snippets")])
        #expect(topHit(RootRanking.rank(parts, query: "saf", topHit: true) { _ in 0 }) == "Safari")
    }

    @Test func whatYouPickedBeforeWins() {
        let memory = SearchMemory(url: nil)
        let parts = results(apps: ["Calendar"], extensions: [("clipboard", "Clipboard History")])
        let calendar = RootRanking.key("apps", item("/Applications/Calendar.app", "Calendar"))
        // Equal by name and kind would favour the extension; three picks of Calendar for "c" turn it around.
        for _ in 0..<3 { memory.record(query: "c", key: calendar) }
        let ranked = RootRanking.rank(parts, query: "c", topHit: true) { memory.boost(query: "c", key: $0) }
        #expect(topHit(ranked) == "Calendar")
    }

    @Test func picksCarryToLongerAndShorterQueriesAndFade() {
        let memory = SearchMemory(url: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        memory.record(query: "His", key: "k", now: now)
        #expect(memory.boost(query: "his", key: "k", now: now) > memory.boost(query: "hi", key: "k", now: now))
        #expect(memory.boost(query: "hi", key: "k", now: now) > memory.boost(query: "hist", key: "k", now: now))
        #expect(memory.boost(query: "hist", key: "k", now: now) > 0)
        #expect(memory.boost(query: "x", key: "k", now: now) == 0)
        #expect(memory.boost(query: "his", key: "other", now: now) == 0)
        let later = now.addingTimeInterval(120 * 86_400)
        #expect(memory.boost(query: "his", key: "k", now: later) < memory.boost(query: "his", key: "k", now: now) / 4)
    }

    @Test func theWebIsNeverTheTopHitAndAlwaysLast() {
        let parts: [(String?, Section)] = [("web-search", Section("Search the Web", [item("google", "Search Google")]))]
        #expect(topHit(RootRanking.rank(parts, query: "zzz", topHit: true) { _ in 0 }) == nil)
        let mixed = results(apps: ["Zoom"])
        #expect(titles(RootRanking.rank(mixed, query: "zzz", topHit: false) { _ in 0 }).last == "Search the Web")
    }

    @Test func anAnswerAlwaysComesFirst() {
        var parts = results(apps: ["Calculator"])
        parts.insert(("calculator", Section("Calculator", [item("result", "4")])), at: 1)
        #expect(topHit(RootRanking.rank(parts, query: "2+2", topHit: true) { _ in 0 }) == "4")
    }

    @Test func extensionListsStayTogether() {
        let parts = results(apps: ["Snipping Tool"], extensions: [("snippets", "Snippets"), ("emoji", "Emoji")])
        let ranked = RootRanking.rank(parts, query: "sni", topHit: false) { _ in 0 }
        #expect(titles(ranked).filter { $0 == "Extensions" }.count == 2)
        let i = titles(ranked).firstIndex(of: "Extensions")!
        #expect(titles(ranked)[i + 1] == "Extensions")
    }
}
