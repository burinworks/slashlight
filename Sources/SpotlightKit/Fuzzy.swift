import Foundation

/// Fuzzy matching shared by all extensions so ranking feels the same everywhere.
public enum Fuzzy {
    /// Higher is better; `nil` means no match. An empty query matches everything with score 0.
    public static func score(_ query: String, _ text: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return 0 }
        let t = text.lowercased()

        if let range = t.range(of: q) {
            let offset = t.distance(from: t.startIndex, to: range.lowerBound)
            var score = 1000 - offset * 5 - t.count
            if offset == 0 { score += 500 }
            else if isWordStart(t, range.lowerBound) { score += 250 }
            return score
        }

        // Subsequence match ("vsc" → "Visual Studio Code").
        let chars = Array(t)
        var index = 0
        var last = -2
        var score = 0
        for c in q where !c.isWhitespace {
            guard let found = chars[index...].firstIndex(of: c) else { return nil }
            score += 10
            if found == last + 1 { score += 15 }
            if found == 0 || !chars[found - 1].isLetter && !chars[found - 1].isNumber { score += 25 }
            last = found
            index = found + 1
            if index > chars.count { return nil }
        }
        return score - chars.count
    }

    /// Best score across several fields (title, keywords…).
    public static func score(_ query: String, _ fields: [String]) -> Int? {
        fields.compactMap { score(query, $0) }.max()
    }

    private static func isWordStart(_ s: String, _ i: String.Index) -> Bool {
        guard i > s.startIndex else { return true }
        let prev = s[s.index(before: i)]
        return !prev.isLetter && !prev.isNumber
    }
}
