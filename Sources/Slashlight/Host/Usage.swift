import Foundation

/// One thing the user did in Slashlight. Stored one JSON object per line in `usage/events.jsonl`, on this Mac only.
struct UsageEvent: Codable, Equatable {
    enum Kind: String, Codable {
        /// The panel appeared.
        case open
        /// An action ran.
        case run
    }

    enum Input: String, Codable {
        /// ↵ / ⌘↵ on the selected row.
        case key
        case click
        /// ⌘1…⌘9.
        case number
        /// An action's own shortcut, or ⌘K.
        case shortcut
        /// Releasing the held modifier in the window switcher.
        case hold
    }

    var time: Date
    var kind: Kind
    /// Extension id; for `open`, the extension the panel opened on (nil = the home screen).
    var ext: String?
    /// Item title, kept only where it is meaningful and not private (an app name, not a clipboard entry).
    var item: String?
    var action: String?
    /// Position of the row in the results, 0 = first.
    var rank: Int?
    var queryLength: Int?
    /// Milliseconds from the panel opening to the action.
    var latency: Int?
    var input: Input?

    enum CodingKeys: String, CodingKey {
        case time = "t", kind = "k", ext = "e", item = "i", action = "a", rank = "r", queryLength = "q", latency = "d", input = "m"
    }
}

/// Records usage events and keeps them in memory for the Usage Insights extension.
@MainActor
final class UsageStore {
    static let shared = UsageStore(directory: Paths.support.appendingPathComponent("usage", isDirectory: true))

    /// Events older than this are dropped when the log is loaded.
    static let retention: TimeInterval = 365 * 86_400
    /// Items from these extensions are recorded without their title: the title is the user's data or meaningless.
    static let anonymousItems: Set<String> = ["clipboard", "calculator", "web-search", "files"]

    private(set) var events: [UsageEvent] = []
    var isEnabled: Bool { !readOnly && !Host.shared.settings.disabledExtensions.contains("insights") }

    /// Debug runs (`--snapshot`) never write to the real log; `--sample-usage` shows made-up data instead.
    private let readOnly = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--sample-usage")

    private let file: URL
    private var openedAt: Date?

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("events.jsonl")
        if CommandLine.arguments.contains("--sample-usage") { events = Self.sample() } else { load() }
    }

    /// Five weeks of plausible activity, for screenshots and trying the dashboard.
    nonisolated static func sample(now: Date = Date()) -> [UsageEvent] {
        var rng = SystemRandomNumberGenerator()
        let picks: [(ext: String, item: String?, weight: Int)] = [
            ("apps", "Safari", 14), ("apps", "Visual Studio Code", 12), ("apps", "Slack", 9), ("apps", "Figma", 5),
            ("window-switcher", "Safari — GitHub", 8), ("terminal", "Run  npm run dev", 6), ("clipboard", nil, 6),
            ("calculator", nil, 4), ("window-management", "Left Half", 5), ("snippets", "Email signature", 3),
            ("emoji", "🙌", 2), ("system", "Lock Screen", 2), ("files", nil, 3),
        ]
        let bag = picks.flatMap { p in Array(repeating: p, count: p.weight) }
        let hours = [8, 9, 9, 10, 10, 10, 11, 11, 13, 14, 14, 15, 15, 16, 17, 18, 21, 22]
        var out: [UsageEvent] = []
        let today = Calendar.current.startOfDay(for: now)
        for day in (0..<35).reversed() {
            guard let date = Calendar.current.date(byAdding: .day, value: -day, to: today) else { continue }
            let weekend = Calendar.current.isDateInWeekend(date)
            for _ in 0..<(weekend ? Int.random(in: 0...6, using: &rng) : Int.random(in: 10...28, using: &rng)) {
                let p = bag.randomElement(using: &rng)!
                var c = Calendar.current.dateComponents([.year, .month, .day], from: date)
                c.hour = hours.randomElement(using: &rng)
                c.minute = Int.random(in: 0...59, using: &rng)
                guard let t = Calendar.current.date(from: c), t <= now else { continue }
                out.append(UsageEvent(time: t.addingTimeInterval(-2), kind: .open))
                out.append(UsageEvent(time: t, kind: .run, ext: p.ext, item: p.item, action: "Open",
                                      rank: Int.random(in: 0...9, using: &rng) < 8 ? 0 : 1, queryLength: Int.random(in: 1...6, using: &rng),
                                      latency: Int.random(in: 600...2400, using: &rng),
                                      input: Int.random(in: 0...9, using: &rng) < 9 ? .key : .click))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    func panelOpened(extensionID: String?) {
        openedAt = Date()
        append(UsageEvent(time: Date(), kind: .open, ext: extensionID))
    }

    func actionRan(extensionID: String?, item: String?, action: String, rank: Int?, queryLength: Int, input: UsageEvent.Input) {
        let latency = openedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        let keepTitle = extensionID.map { !Self.anonymousItems.contains($0) } ?? false
        append(UsageEvent(time: Date(), kind: .run, ext: extensionID, item: keepTitle ? item : nil, action: action,
                          rank: rank, queryLength: queryLength, latency: latency, input: input))
    }

    func clear() {
        events.removeAll()
        guard !readOnly else { return }
        try? FileManager.default.removeItem(at: file)
    }

    private func append(_ event: UsageEvent) {
        guard isEnabled else { return }
        events.append(event)
        guard var line = try? Self.encoder.encode(event) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let all = data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(UsageEvent.self, from: Data($0)) }
        events = all.filter { $0.time >= cutoff }
        if events.count < all.count {
            // Rewrite without the expired events.
            let lines = events.compactMap { try? Self.encoder.encode($0) }
            try? Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: file, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// Numbers and insights for one period, computed from raw events.
struct UsageReport {
    enum Period: String, CaseIterable {
        case week = "7 Days", month = "30 Days", all = "All Time"

        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    struct Count: Identifiable, Equatable {
        var id: String { key + (detail ?? "") }
        let key: String
        var detail: String?
        let count: Int
    }

    struct Day: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let count: Int
    }

    let period: Period
    let opens: Int
    let actions: Int
    let activeDays: Int
    /// Consecutive days with any activity, ending today (or yesterday, if today has none yet).
    let streak: Int
    let byExtension: [Count]
    let topItems: [Count]
    let daily: [Day]
    /// Actions per hour of the day, 0…23.
    let hourly: [Int]
    /// Share of actions run on the first result.
    let firstResultShare: Double?
    /// Share of actions run from the keyboard.
    let keyboardShare: Double?
    /// Median milliseconds from opening the panel to running an action.
    let medianLatency: Int?
    let unused: [String]

    /// `extensions` maps every enabled extension id to its title; the ones never used show up in `unused`.
    init(events: [UsageEvent], period: Period, extensions: [String: String], now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        let today = calendar.startOfDay(for: now)
        let start = period.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }
        let inPeriod = events.filter { start == nil || $0.time >= start! }
        let runs = inPeriod.filter { $0.kind == .run }

        opens = inPeriod.filter { $0.kind == .open }.count
        actions = runs.count

        let days = Set(inPeriod.map { calendar.startOfDay(for: $0.time) })
        activeDays = days.count
        let allDays = Set(events.map { calendar.startOfDay(for: $0.time) })
        var cursor = allDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var run = 0
        while allDays.contains(cursor) {
            run += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        streak = run

        let title = { (id: String) in extensions[id] ?? id }
        byExtension = Dictionary(grouping: runs.compactMap(\.ext), by: { $0 })
            .map { Count(key: title($0.key), count: $0.value.count) }
            .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
        topItems = Dictionary(grouping: runs.filter { $0.item != nil }, by: { "\($0.ext ?? "")\u{1F}\($0.item!)" })
            .map { Count(key: $0.value[0].item!, detail: title($0.value[0].ext ?? ""), count: $0.value.count) }
            .sorted { ($0.count, $1.key) > ($1.count, $0.key) }
            .prefix(8).map { $0 }

        let chartDays = period.days ?? max(1, min(90, (calendar.dateComponents([.day], from: events.map(\.time).min() ?? now, to: now).day ?? 0) + 1))
        let perDay = Dictionary(grouping: runs, by: { calendar.startOfDay(for: $0.time) }).mapValues(\.count)
        daily = (0..<chartDays).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0, count: perDay[$0] ?? 0) }
        }

        var hours = [Int](repeating: 0, count: 24)
        for e in runs { hours[calendar.component(.hour, from: e.time)] += 1 }
        hourly = hours

        let ranked = runs.compactMap(\.rank)
        firstResultShare = ranked.isEmpty ? nil : Double(ranked.filter { $0 == 0 }.count) / Double(ranked.count)
        let inputs = runs.compactMap(\.input)
        keyboardShare = inputs.isEmpty ? nil : Double(inputs.filter { $0 != .click }.count) / Double(inputs.count)
        let latencies = runs.compactMap(\.latency).filter { $0 < 60_000 }.sorted()
        medianLatency = latencies.isEmpty ? nil : latencies[latencies.count / 2]

        let used = Set(runs.compactMap(\.ext))
        unused = extensions.filter { !used.contains($0.key) }.map(\.value).sorted()
    }

    /// Short, plain-language observations, most interesting first.
    var insights: [String] {
        var out: [String] = []
        guard actions > 0 else { return ["Nothing recorded yet. Use Slashlight for a day and come back."] }
        if let top = topItems.first, top.count >= 3 {
            out.append("Your most-used item is \(top.key): \(top.count) times.")
        }
        if let peak = hourly.indices.max(by: { hourly[$0] < hourly[$1] }), hourly[peak] > 0 {
            out.append("You're busiest between \(Self.hour(peak)) and \(Self.hour((peak + 1) % 24)).")
        }
        if streak >= 2 { out.append("\(streak)-day streak. Keep it going!") }
        if let share = firstResultShare {
            out.append(share >= 0.7
                ? "\(Int(share * 100))% of the time the first result was the one you wanted."
                : "Only \(Int(share * 100))% of picks were the first result. Typing a little more usually brings it to the top.")
        }
        if let share = keyboardShare, share < 0.8 {
            out.append("\(Int((1 - share) * 100))% of picks were mouse clicks. ↵ runs the selection and ⌘1…⌘9 run any of the first nine.")
        }
        if let idea = unused.first { out.append("Haven't tried \(idea) yet? Type / to find it.") }
        return out
    }

    static func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}
