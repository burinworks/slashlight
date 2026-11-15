import SlashlightKit

/// Orders the main search's results across extensions. Each extension still ranks its own list; this decides
/// which list comes first and which single result is the Top Hit.
///
/// A result's score is
/// - how well its name matches (`Fuzzy.score`: the whole name, then its start, then the start of a word, then
///   anywhere; "his" scores far higher in "Clipboard *His*tory" than in "About T*his* Mac"),
/// - plus what you picked before for this query (`SearchMemory`),
/// - plus a small preference by kind: an answer (the calculator) always wins, extensions and commands come
///   slightly before apps, files after them, and the web search is never the Top Hit and always last.
enum RootRanking {
    static let topHit = "Top Hit"

    static func key(_ extensionID: String?, _ item: Item) -> String { "\(extensionID ?? "-")|\(item.id)" }

    static func prior(extensionID: String?, section: String) -> Int {
        switch extensionID {
        case "calculator": return 3000
        case "web-search": return -100_000
        case "files": return -150
        case "apps": return 0
        default: return section == "Extensions" ? 120 : 60
        }
    }

    /// A result the extension returned without its name matching (a keyword, a path) still counts as a match.
    static func matchScore(_ query: String, _ item: Item) -> Int {
        Fuzzy.score(query, item.title) ?? 300
    }

    static func score(_ query: String, _ extensionID: String?, _ section: String, _ item: Item, boost: (String) -> Int) -> Int {
        matchScore(query, item) + prior(extensionID: extensionID, section: section) + boost(key(extensionID, item))
    }

    /// Sorts each list by score, orders the lists by their best result (the web last), and, when `topHit` is set,
    /// lifts the best result into a Top Hit section of its own.
    static func rank(_ parts: [(String?, Section)], query: String, topHit: Bool, boost: (String) -> Int) -> [(String?, Section)] {
        var lists: [(ext: String?, section: Section, best: Int, order: Int)] = []
        for (i, (ext, section)) in parts.enumerated() where !section.items.isEmpty {
            let scored = section.items.enumerated()
                .map { (score: score(query, ext, section.title, $0.element, boost: boost), offset: $0.offset, item: $0.element) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            var s = section
            s.items = scored.map(\.item)
            lists.append((ext, s, scored.first?.score ?? .min, i))
        }
        // Lists sharing a title (one "Extensions" list per extension) stay together, so each title shows once.
        var groupBest: [String: Int] = [:]
        var groupOrder: [String: Int] = [:]
        for l in lists {
            groupBest[l.section.title] = max(groupBest[l.section.title] ?? .min, l.best)
            groupOrder[l.section.title] = min(groupOrder[l.section.title] ?? .max, l.order)
        }
        lists.sort { a, b in
            let ga = a.section.title, gb = b.section.title
            if ga != gb {
                return groupBest[ga]! != groupBest[gb]! ? groupBest[ga]! > groupBest[gb]! : groupOrder[ga]! < groupOrder[gb]!
            }
            return a.best != b.best ? a.best > b.best : a.order < b.order
        }

        guard topHit, let first = lists.first, first.ext != "web-search", let hit = first.section.items.first else {
            return lists.map { ($0.ext, $0.section) }
        }
        lists[0].section.items.removeFirst()
        return [(first.ext, Section(Self.topHit, [hit]))] + lists.filter { !$0.section.items.isEmpty }.map { ($0.ext, $0.section) }
    }
}
