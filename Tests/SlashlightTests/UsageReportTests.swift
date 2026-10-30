import Foundation
import Testing
@testable import Slashlight

@Suite("Usage report")
struct UsageReportTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    // Friday 30 Oct 2026, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_372_400)

    private func at(daysAgo: Int, hour: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    private func run(_ ext: String, _ item: String?, daysAgo: Int = 0, hour: Int = 10, rank: Int = 0,
                     input: UsageEvent.Input = .key, latency: Int = 1000) -> UsageEvent {
        UsageEvent(time: at(daysAgo: daysAgo, hour: hour), kind: .run, ext: ext, item: item, action: "Open",
                   rank: rank, queryLength: 3, latency: latency, input: input)
    }

    private func report(_ events: [UsageEvent], _ period: UsageReport.Period = .week) -> UsageReport {
        UsageReport(events: events, period: period,
                    extensions: ["apps": "All Apps", "terminal": "Terminal", "emoji": "Emoji & Symbols"],
                    now: now, calendar: calendar)
    }

    @Test func emptyLogHasFriendlyInsight() {
        let r = report([])
        #expect(r.actions == 0)
        #expect(r.streak == 0)
        #expect(r.insights.count == 1)
        #expect(r.daily.count == 7)
    }

    @Test func countsAndRanking() {
        let r = report([
            run("apps", "Safari"), run("apps", "Safari"), run("apps", "Safari"), run("apps", "Mail"),
            run("terminal", "Run  ls"),
            UsageEvent(time: at(daysAgo: 0, hour: 9), kind: .open),
        ])
        #expect(r.actions == 5)
        #expect(r.opens == 1)
        #expect(r.byExtension.first == .init(key: "All Apps", count: 4))
        #expect(r.topItems.first == .init(key: "Safari", detail: "All Apps", count: 3))
        #expect(r.unused == ["Emoji & Symbols"])
        #expect(r.insights.first == "Your most-used item is Safari: 3 times.")
    }

    @Test func periodExcludesOlderEvents() {
        let events = [run("apps", "Safari", daysAgo: 0), run("apps", "Safari", daysAgo: 10), run("apps", "Safari", daysAgo: 40)]
        #expect(report(events, .week).actions == 1)
        #expect(report(events, .month).actions == 2)
        #expect(report(events, .all).actions == 3)
    }

    @Test func streakCountsBackFromToday() {
        let events = [0, 1, 2, 4].map { run("apps", "Safari", daysAgo: $0) }
        #expect(report(events).streak == 3)
    }

    @Test func streakStartsYesterdayWhenTodayIsEmpty() {
        let events = [1, 2].map { run("apps", "Safari", daysAgo: $0) }
        #expect(report(events).streak == 2)
    }

    @Test func dailySeriesEndsToday() throws {
        let r = report([run("apps", "Safari", daysAgo: 0), run("apps", "Safari", daysAgo: 0), run("apps", "Safari", daysAgo: 6)])
        let last = try #require(r.daily.last)
        #expect(last.date == calendar.startOfDay(for: now))
        #expect(last.count == 2)
        #expect(r.daily.first?.count == 1)
    }

    @Test func hourlyAndShares() {
        let r = report([
            run("apps", "A", hour: 9, rank: 0, input: .key, latency: 800),
            run("apps", "B", hour: 9, rank: 2, input: .click, latency: 1200),
            run("apps", "C", hour: 14, rank: 0, input: .number, latency: 90_000),
            run("apps", "D", hour: 14, rank: 0, input: .key, latency: 1000),
        ])
        #expect(r.hourly[9] == 2)
        #expect(r.hourly[14] == 2)
        #expect(r.firstResultShare == 0.75)
        #expect(r.keyboardShare == 0.75)
        // Latencies over a minute (panel left open) are ignored.
        #expect(r.medianLatency == 1000)
    }
}

@Suite("Usage event format")
struct UsageEventTests {
    @Test func compactKeys() throws {
        let e = UsageEvent(time: Date(timeIntervalSince1970: 100), kind: .run, ext: "apps", item: "Safari", action: "Open",
                           rank: 0, queryLength: 3, latency: 900, input: .key)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(e), as: UTF8.self)
        #expect(json == #"{"a":"Open","d":900,"e":"apps","i":"Safari","k":"run","m":"key","q":3,"r":0,"t":100}"#)
    }

    @Test func sampleDataIsOrderedAndPlausible() {
        let events = UsageStore.sample()
        #expect(events.count > 100)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.time <= $1.time })
    }
}
