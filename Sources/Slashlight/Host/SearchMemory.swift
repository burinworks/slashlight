import Foundation

/// What you picked for what you typed ("his" → Clipboard History), so the next time the same or a similar query
/// ranks it first. Like Alfred's knowledge: counts fade with a 30-day half-life, and a query also learns from
/// longer and shorter ones ("hi" from "his", "hist" from "his"). Stays on this Mac.
@MainActor
final class SearchMemory {
    static let shared = SearchMemory(url: Paths.support.appendingPathComponent("search-memory.json"))

    struct Pick: Codable, Equatable {
        var count: Double
        var last: Date
    }

    /// Typed query → item key ("apps|/Applications/Safari.app") → how often and when.
    private(set) var picks: [String: [String: Pick]]
    private let url: URL?
    private let halfLife: TimeInterval = 30 * 86_400
    private let maxQueries = 600

    init(url: URL?) {
        self.url = url
        picks = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: [String: Pick]].self, from: $0) } ?? [:]
    }

    static func normalize(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func decayed(_ p: Pick, now: Date) -> Double {
        p.count * pow(0.5, now.timeIntervalSince(p.last) / halfLife)
    }

    func record(query: String, key: String, now: Date = Date()) {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return }
        let old = picks[q]?[key]
        picks[q, default: [:]][key] = Pick(count: (old.map { decayed($0, now: now) } ?? 0) + 1, last: now)
        if picks.count > maxQueries { forgetOldest() }
        save()
    }

    /// Points to add to a result's score: 0 for something never picked, up to about 700 for a habit.
    func boost(query: String, key: String, now: Date = Date()) -> Int {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return 0 }
        var weight = 0.0
        for (stored, items) in picks {
            guard let p = items[key] else { continue }
            let w: Double
            if stored == q { w = 1 }
            else if stored.hasPrefix(q) { w = 0.7 }   // typed "hi", picked it for "his"
            else if q.hasPrefix(stored) { w = 0.5 }   // typed "hist", picked it for "his"
            else { continue }
            weight += w * decayed(p, now: now)
        }
        guard weight > 0.05 else { return 0 }
        return min(700, Int(250 * log2(1 + weight)))
    }

    func clear() {
        picks = [:]
        save()
    }

    private func forgetOldest() {
        let newest = picks.mapValues { $0.values.map(\.last).max() ?? .distantPast }
        for (q, _) in newest.sorted(by: { $0.value < $1.value }).prefix(picks.count - maxQueries) { picks[q] = nil }
    }

    private func save() {
        guard let url else { return }
        try? JSONEncoder().encode(picks).write(to: url, options: .atomic)
    }
}
