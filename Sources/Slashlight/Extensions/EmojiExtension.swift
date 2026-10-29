import AppKit
import SlashlightKit

/// `/emoji`: a grid of emoji and typographic symbols (⌘ ⌥ → … ©), searchable by Unicode name.
/// ↵ copies, ⌘↵ pastes; the last 24 used come first. `/emoji heart` also answers inline in command mode.
final class EmojiExtension: Extension {
    struct Emoji {
        let char: String
        /// Lowercased Unicode name, e.g. "grinning face".
        let name: String
        let category: String
    }

    static let filters = ["All", "Smileys", "People", "Animals & Nature", "Food", "Objects", "Symbols", "Flags"]

    private var recent: [String] = []
    private let recentLimit = 24

    override var manifest: Manifest {
        Manifest(id: "emoji", title: "Emoji & Symbols", subtitle: "Search emoji by name, plus ⌘ ⌥ → … © and friends", icon: .text("😀"))
    }

    override var triggers: [Trigger] { [.commands, .command("emoji")] }

    override func activate(context: ExtensionContext) async {
        recent = context.storage(.persistent).value([String].self, forKey: "recent") ?? []
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "Search emoji and symbols…",
                 layout: .grid(columns: 8), filters: Self.filters) { [unowned self] q in try await self.search(q) }
    }

    override func search(_ query: Query) async throws -> [Section] {
        if query.mode == .command {
            // Only "/emoji <name>" — other command text belongs to other extensions.
            let parts = query.text.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "emoji" else { return [] }
            return [Section("Emoji", Array(matches(parts[1], in: Self.all).prefix(12)).map(item))]
        }

        let pool = query.filter == nil || query.filter == "All" ? Self.all : Self.all.filter { $0.category == query.filter }
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return [Section("Results", matches(text, in: pool).map(item))] }

        var sections: [Section] = []
        let byChar = Dictionary(pool.map { ($0.char, $0) }, uniquingKeysWith: { a, _ in a })
        let used = recent.compactMap { byChar[$0] }
        if !used.isEmpty { sections.append(Section("Recent", used.map(item))) }
        for category in Self.filters.dropFirst() {
            let list = pool.filter { $0.category == category }
            if !list.isEmpty { sections.append(Section(category, list.map(item))) }
        }
        return sections
    }

    /// Substring matches on the name (fuzzy subsequences are too loose across ~2000 names), best first.
    private func matches(_ text: String, in pool: [Emoji]) -> [Emoji] {
        let q = text.lowercased()
        return pool
            .compactMap { e -> (Int, Emoji)? in
                if e.char == text { return (Int.max, e) }
                guard e.name.contains(q), let s = Fuzzy.score(q, e.name) else { return nil }
                return (s, e)
            }
            .sorted { $0.0 > $1.0 }
            .map { $0.1 }
    }

    private func item(_ e: Emoji) -> Item {
        Item(id: e.char, title: e.name.prefix(1).uppercased() + e.name.dropFirst(), icon: .text(e.char),
             primary: Action("Copy", icon: .symbol("doc.on.doc")) { [weak self] in
                 self?.use(e.char)
                 self?.context.copy(e.char)
                 return .hud("Copied \(e.char)")
             },
             secondary: Action("Paste", icon: .symbol("arrow.down.doc")) { [weak self] in
                 self?.use(e.char)
                 return .paste(e.char)
             },
             more: [
                Action("Copy Name", icon: .symbol("textformat"), shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                    self?.context.copy(e.name)
                    return .hud("Copied “\(e.name)”")
                },
             ])
    }

    private func use(_ char: String) {
        recent.removeAll { $0 == char }
        recent.insert(char, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        context.storage(.persistent).set(recent, forKey: "recent")
    }

    // MARK: Catalogue

    /// Built once from the Unicode tables shipped with the OS, so new emoji appear with OS updates.
    static let all: [Emoji] = {
        var list: [Emoji] = []
        // Faces first, so each category starts with its most used emoji.
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F, 0x1F90C...0x1F9FF, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF, 0x1FA70...0x1FAFF,
            0x1F004...0x1F0CF, 0x1F170...0x1F251, 0x1F7E0...0x1F7EB, 0x2300...0x23FF, 0x2600...0x27BF, 0x2B05...0x2B55, 0x2934...0x2935,
            0x3030...0x3030, 0x303D...0x303D, 0x3297...0x3299,
        ]
        for range in ranges {
            for v in range {
                guard let scalar = Unicode.Scalar(v) else { continue }
                let p = scalar.properties
                guard p.isEmoji, !p.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(v), let name = p.name else { continue }
                // Text-default emoji (☀ ❤ ✈) need the emoji variation selector to render in colour.
                let char = p.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                list.append(Emoji(char: char, name: name.lowercased(), category: category(v, name)))
            }
        }
        list += sequences.map { Emoji(char: $0.0, name: $0.1, category: $0.2) }

        let english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }), let country = english.localizedString(forRegionCode: code) else { continue }
            let flag = code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }.map(String.init).joined()
            list.append(Emoji(char: flag, name: "flag \(country.lowercased())", category: "Flags"))
        }

        list += symbols.map { Emoji(char: $0.0, name: $0.1, category: "Symbols") }
        return list
    }()

    /// Common ZWJ sequences, which the scalar scan cannot produce.
    private static let sequences: [(String, String, String)] = [
        ("❤️‍🔥", "heart on fire", "Smileys"), ("❤️‍🩹", "mending heart", "Smileys"), ("😮‍💨", "face exhaling", "Smileys"),
        ("😵‍💫", "face with spiral eyes", "Smileys"), ("🧑‍💻", "technologist", "People"), ("🧑‍🚀", "astronaut", "People"),
        ("🧑‍🍳", "cook", "People"), ("🧑‍🎨", "artist", "People"), ("👨‍👩‍👧‍👦", "family", "People"),
        ("🐕‍🦺", "service dog", "Animals & Nature"), ("🐈‍⬛", "black cat", "Animals & Nature"), ("🐻‍❄️", "polar bear", "Animals & Nature"),
        ("🏳️‍🌈", "rainbow flag", "Flags"), ("🏳️‍⚧️", "transgender flag", "Flags"), ("🏴‍☠️", "pirate flag", "Flags"),
    ]

    /// Keyboard and typographic symbols people look for while writing docs and shortcuts.
    private static let symbols: [(String, String)] = [
        ("⌘", "command key"), ("⌥", "option key"), ("⌃", "control key"), ("⇧", "shift key"), ("⇪", "caps lock key"),
        ("↵", "return key"), ("⏎", "return symbol"), ("⌫", "delete key backspace"), ("⌦", "forward delete key"), ("⎋", "escape key"),
        ("⇥", "tab key"), ("\u{F8FF}", "apple logo"), ("→", "right arrow"), ("←", "left arrow"), ("↑", "up arrow"), ("↓", "down arrow"),
        ("↔", "left right arrow"), ("⇒", "double right arrow implies"), ("⇐", "double left arrow"), ("⇔", "double left right arrow iff"),
        ("•", "bullet"), ("·", "middle dot"), ("…", "ellipsis"), ("—", "em dash"), ("–", "en dash"),
        ("©", "copyright sign"), ("®", "registered sign"), ("™", "trade mark sign"), ("°", "degree sign"), ("±", "plus minus sign"),
        ("×", "multiplication sign"), ("÷", "division sign"), ("≠", "not equal to"), ("≈", "almost equal to"), ("≤", "less than or equal to"),
        ("≥", "greater than or equal to"), ("∞", "infinity"), ("√", "square root"), ("π", "pi"), ("∑", "sum sigma"), ("Δ", "delta"),
        ("Ω", "omega ohm"), ("µ", "micro sign"), ("‰", "per mille sign"), ("½", "one half"), ("¼", "one quarter"), ("¾", "three quarters"),
        ("✓", "check mark"), ("✗", "ballot x cross"), ("★", "black star"), ("☆", "white star"), ("€", "euro sign"), ("£", "pound sign"),
        ("¥", "yen sign"), ("¢", "cent sign"), ("§", "section sign"), ("¶", "pilcrow paragraph sign"), ("†", "dagger"),
        ("«", "left guillemet quote"), ("»", "right guillemet quote"), ("“", "left double quotation mark"), ("”", "right double quotation mark"),
        ("‘", "left single quotation mark"), ("’", "right single quotation mark apostrophe"), ("№", "numero sign"), ("′", "prime minutes feet"),
        ("″", "double prime seconds inches"),
    ]

    private static let peopleWords: Set<String> = [
        "PERSON", "MAN", "WOMAN", "MEN", "WOMEN", "BOY", "GIRL", "BABY", "CHILD", "ADULT", "OLDER", "HAND", "HANDS", "FINGER", "FINGERS",
        "THUMBS", "FIST", "PEOPLE", "FAMILY", "COUPLE", "PRINCE", "PRINCESS", "GUARDSMAN", "DETECTIVE", "WORKER", "ANGEL", "SANTA",
        "MERPERSON", "ELF", "GENIE", "ZOMBIE", "VAMPIRE", "FAIRY", "MAGE", "TROLL", "SELFIE", "BICEPS", "LEG", "FOOT", "EAR", "NOSE",
        "EYE", "EYES", "TONGUE", "MOUTH", "BRAIN", "TOOTH", "BONE", "FOOTPRINTS", "BUST", "BUSTS", "DANCER", "HANDSHAKE", "PREGNANT",
        "NAIL", "HEAD", "LUNGS", "ANATOMICAL", "NINJA", "SUPERHERO", "SUPERVILLAIN", "MRS", "MX", "SKIER", "SNOWBOARDER", "SURFER", "SWIMMER",
        "ROWBOAT", "BICYCLIST", "WRESTLERS", "JUGGLING", "CARTWHEEL", "LOTUS",
    ]

    private static func category(_ v: UInt32, _ name: String) -> String {
        let words = Set(name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init))
        let faceRanges: [ClosedRange<UInt32>] = [0x1F600...0x1F644, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1FAE0...0x1FAEF]
        if faceRanges.contains(where: { $0.contains(v) }) { return "Smileys" }
        let food: [ClosedRange<UInt32>] = [0x1F32D...0x1F32F, 0x1F345...0x1F37F, 0x1F942...0x1F944, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADF, 0x2615...0x2615]
        if food.contains(where: { $0.contains(v) }) { return "Food" }
        let nature: [ClosedRange<UInt32>] = [
            0x1F300...0x1F32C, 0x1F330...0x1F344, 0x1F400...0x1F43F, 0x1F490...0x1F490, 0x1F4AE...0x1F4AE, 0x1F577...0x1F578,
            0x1F980...0x1F9AE, 0x1FAB0...0x1FABF, 0x1F940...0x1F940, 0x2600...0x2604, 0x2614...0x2614, 0x2618...0x2618,
            0x26A1...0x26A1, 0x26C4...0x26C8, 0x2744...0x2744,
        ]
        if nature.contains(where: { $0.contains(v) }) { return "Animals & Nature" }
        let people: [ClosedRange<UInt32>] = [
            0x1F645...0x1F64F, 0x1F466...0x1F487, 0x1F90C...0x1F90F, 0x1F918...0x1F91F, 0x1F926...0x1F926, 0x1F930...0x1F93E,
            0x1F9B0...0x1F9B9, 0x1F9CD...0x1F9DF, 0x1FAC3...0x1FAC5, 0x1FAF0...0x1FAF8,
        ]
        if !words.isDisjoint(with: peopleWords) || people.contains(where: { $0.contains(v) }) { return "People" }
        if words.contains("FACE") && !words.contains("CLOCK") || words.contains("HEART") { return "Smileys" }
        let symbolRanges: [ClosedRange<UInt32>] = [
            0x1F170...0x1F251, 0x1F500...0x1F53D, 0x1F7E0...0x1F7EB, 0x2190...0x21FF, 0x2934...0x2935, 0x2B05...0x2B55, 0x25A0...0x25FF,
            0x2648...0x2653, 0x267B...0x267F, 0x2695...0x269C, 0x26A0...0x26A0, 0x26AA...0x26AB, 0x26CE...0x26CE, 0x26D4...0x26D4,
            0x2705...0x2705, 0x2714...0x2716, 0x271D...0x271D, 0x2721...0x2721, 0x2733...0x2734, 0x2747...0x2747, 0x274C...0x274E,
            0x2753...0x2757, 0x2795...0x27BF, 0x262E...0x262F, 0x2638...0x2640, 0x2642...0x2642, 0x3030...0x3299, 0x1F6AB...0x1F6AB,
            0x1F6AD...0x1F6AD, 0x1F6AF...0x1F6B1, 0x1F6B3...0x1F6B3, 0x1F6B7...0x1F6B8, 0x1F6BA...0x1F6C5, 0x1F4AF...0x1F4AF,
            0x1F4A2...0x1F4A2, 0x1F4A4...0x1F4A4, 0x1F4AC...0x1F4AD, 0x1F6D0...0x1F6D0, 0x1F549...0x1F549, 0x1F54E...0x1F54E,
        ]
        if symbolRanges.contains(where: { $0.contains(v) }) { return "Symbols" }
        return "Objects"
    }
}
