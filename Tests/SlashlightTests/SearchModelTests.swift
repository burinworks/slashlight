import Foundation
import Testing
import SlashlightKit
@testable import Slashlight

@Suite("Predictive calculator")
@MainActor
struct PredictiveCalculatorTests {
    @Test(arguments: [("12*(3+", "36"), ("2+3*", "5"), ("(1+2", "3"), ("2+", "2"), ("10 / (2 + 3", "2")])
    func answersUnfinishedMath(text: String, value: String) throws {
        let a = try #require(CalculatorExtension.calculate(text))
        #expect(a.value == value)
    }

    @Test(arguments: ["12", "hello", "4k", "safari", "2024"])
    func leavesSearchesAlone(text: String) {
        #expect(CalculatorExtension.calculate(text) == nil)
        if let (_, unit) = CalculatorExtension.splitQuantity(text) {
            #expect(CalculatorExtension.defaultTarget(unit) == nil, "\(text) read as a quantity")
        }
    }

    @Test(arguments: [("5 km", "mi"), ("20 c", "f"), ("3 kg", "lb"), ("100 usd", nil), ("5 km to", "mi"), ("2 h", "min")])
    func quantityWithoutTarget(text: String, target: String?) throws {
        let (_, unit) = try #require(CalculatorExtension.splitQuantity(text))
        #expect(CalculatorExtension.defaultTarget(unit) == target)
    }
}

@Suite("Recents")
struct RecentsListTests {
    private func entry(_ ext: String, _ item: String? = nil, _ t: TimeInterval) -> RecentsList.Entry {
        .init(ext: ext, item: item, title: item.map { "Title \($0)" }, date: Date(timeIntervalSince1970: t))
    }

    @Test func eachExtensionPicksWhatItShows() {
        var list = RecentsList()
        list.record(entry("clipboard", nil, 1))
        list.record(entry("commands", "my-ip", 2))
        list.record(entry("calculator", nil, 3))
        list.record(entry("clipboard", nil, 4))
        list.record(entry("commands", "gh", 5))
        let modes: [String: RecentsMode] = ["clipboard": .wholeExtension, "commands": .actions, "calculator": .hidden]
        let picks = list.home(limit: 5) { modes[$0] }
        #expect(picks == [
            .item(ext: "commands", id: "gh", title: "Title gh"),
            .wholeExtension("clipboard"),
            .item(ext: "commands", id: "my-ip", title: "Title my-ip"),
        ])
    }

    @Test func runningAgainMovesToTop() {
        var list = RecentsList()
        list.record(entry("commands", "a", 1))
        list.record(entry("commands", "b", 2))
        list.record(entry("commands", "a", 3))
        #expect(list.entries.map(\.item) == ["a", "b"])
        #expect(list.lastUsed(ext: "commands", item: "a") == Date(timeIntervalSince1970: 3))
    }

    @Test func keepsALimit() {
        var list = RecentsList()
        for i in 0..<(RecentsList.limit + 10) { list.record(entry("commands", "c\(i)", TimeInterval(i))) }
        #expect(list.entries.count == RecentsList.limit)
        #expect(list.entries.first?.item == "c\(RecentsList.limit + 9)")
    }
}
