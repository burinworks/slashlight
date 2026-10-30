import Foundation
import Testing
@testable import Slashlight

@Suite("Telemetry report")
struct TelemetryReportTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let day = Date(timeIntervalSince1970: 1_793_232_000) // 2026-10-29 00:00 UTC

    private let env = TelemetryReport.Environment(
        app: .init(version: "0.4.0", build: 7, channel: "stable"),
        system: .init(macos: "26.1", arch: "arm64", region: "DE", language: "en"),
        settings: .init(hotkey: "opt+space", appearance: "system", disabled: [], externalExtensions: 1),
        builtIns: ["apps", "terminal", "clipboard"])

    private func event(_ kind: UsageEvent.Kind, _ ext: String? = nil, hour: Int = 10, item: String? = nil,
                       rank: Int? = 0, input: UsageEvent.Input? = .key, latency: Int? = 1000, query: Int? = 3) -> UsageEvent {
        UsageEvent(time: day.addingTimeInterval(Double(hour) * 3600), kind: kind, ext: ext, item: item, action: kind == .run ? "Open" : nil,
                   rank: kind == .run ? rank : nil, queryLength: kind == .run ? query : nil,
                   latency: kind == .run ? latency : nil, input: kind == .run ? input : nil)
    }

    private func make(_ events: [UsageEvent]) -> TelemetryReport? {
        TelemetryReport.make(day: day, events: events, install: "ID", environment: env, calendar: calendar)
    }

    @Test func noEventsNoReport() {
        #expect(make([]) == nil)
        // Events on other days don't count.
        #expect(make([UsageEvent(time: day.addingTimeInterval(-3600), kind: .open)]) == nil)
    }

    @Test func countsUsage() throws {
        let r = try #require(make([
            event(.open), event(.open),
            event(.run, "apps", item: "Safari", rank: 0, input: .key, latency: 800, query: 2),
            event(.run, "apps", item: "Mail", rank: 1, input: .click, latency: 1500, query: 4),
            event(.run, "terminal", rank: 0, input: .number, latency: 1200, query: 6),
            event(.run, "my-private-extension", rank: 0, input: .key, latency: 90_000, query: 3),
        ]))
        #expect(r.day == "2026-10-29")
        #expect(r.usage.opens == 2)
        #expect(r.usage.actions == 4)
        #expect(r.usage.byExtension == ["apps": 2, "terminal": 1, "external": 1])
        #expect(r.usage.inputs == ["key": 2, "click": 1, "number": 1])
        #expect(r.usage.firstResult == 3)
        #expect(r.usage.ranked == 4)
        #expect(r.usage.latencyP50 == 1200)
        #expect(r.usage.queryLengthP50 == 4)
    }

    @Test func neverContainsTitlesOrExternalNames() throws {
        let r = try #require(make([event(.run, "my-private-extension", item: "Secret project.pdf")]))
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!json.contains("Secret"))
        #expect(!json.contains("my-private-extension"))
    }

    @Test func schemaFields() throws {
        let r = try #require(make([event(.open)]))
        let json = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(r)) as? [String: Any])
        #expect(Set(json.keys) == ["schema", "install", "day", "app", "system", "settings", "usage"])
        #expect(json["schema"] as? Int == 1)
    }
}

@Suite("Built-in ids")
@MainActor
struct BuiltInIDTests {
    @Test func idsMatchTheBuiltIns() {
        #expect(Set(BuiltIns.all().map(\.manifest.id)) == Set(BuiltIns.ids))
    }
}
