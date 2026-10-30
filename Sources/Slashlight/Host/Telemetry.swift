import AppKit
import Foundation

/// One day of anonymous statistics, as described in docs/telemetry.md. Counts only: no titles, queries or paths.
struct TelemetryReport: Codable, Equatable {
    struct App: Codable, Equatable { var version: String; var build: Int; var channel: String }
    struct System: Codable, Equatable { var macos: String; var arch: String; var region: String?; var language: String? }
    struct SettingsInfo: Codable, Equatable {
        var hotkey: String
        var appearance: String
        var disabled: [String]
        var externalExtensions: Int
    }
    struct Usage: Codable, Equatable {
        var opens: Int
        var actions: Int
        var byExtension: [String: Int]
        var inputs: [String: Int]
        var firstResult: Int
        var ranked: Int
        var latencyP50: Int?
        var queryLengthP50: Int?
    }

    static let schema = 1

    var schema = TelemetryReport.schema
    var install: String
    /// Local calendar day, `yyyy-MM-dd`.
    var day: String
    var app: App
    var system: System
    var settings: SettingsInfo
    var usage: Usage

    /// Everything about the Mac and the app that is not usage.
    struct Environment {
        var app: App
        var system: System
        var settings: SettingsInfo
        /// Ids of the built-in extensions; anything else is reported as "external".
        var builtIns: Set<String>
    }

    /// The report for `day`, or nil when nothing happened that day.
    static func make(day: Date, events: [UsageEvent], install: String, environment env: Environment,
                     calendar: Calendar = .current) -> TelemetryReport? {
        let mine = events.filter { calendar.isDate($0.time, inSameDayAs: day) }
        guard !mine.isEmpty else { return nil }
        let runs = mine.filter { $0.kind == .run }

        var byExtension: [String: Int] = [:]
        for e in runs {
            guard let ext = e.ext else { continue }
            byExtension[env.builtIns.contains(ext) ? ext : "external", default: 0] += 1
        }
        var inputs: [String: Int] = [:]
        for e in runs { if let i = e.input { inputs[i.rawValue, default: 0] += 1 } }
        let ranked = runs.compactMap(\.rank)

        return TelemetryReport(
            install: install, day: dayString(day, calendar: calendar), app: env.app, system: env.system, settings: env.settings,
            usage: Usage(opens: mine.filter { $0.kind == .open }.count, actions: runs.count, byExtension: byExtension,
                         inputs: inputs, firstResult: ranked.filter { $0 == 0 }.count, ranked: ranked.count,
                         latencyP50: median(runs.compactMap(\.latency).filter { $0 < 60_000 }),
                         queryLengthP50: median(runs.compactMap(\.queryLength))))
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func median(_ values: [Int]) -> Int? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }
}

/// Sends one report per finished day when the user agreed to share statistics and the build has a collector URL.
@MainActor
final class Telemetry {
    static let shared = Telemetry()

    /// Set at build time from `TELEMETRY_URL` (scripts/build-app.sh). Development builds have none and never send.
    let endpoint: URL? = (Bundle.main.object(forInfoDictionaryKey: "SLTelemetryURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }

    /// How many finished days back a report is still sent.
    static let catchUpDays = 7

    private struct State: Codable {
        var install: String
        var sent: [String] = []
    }

    private let file = Paths.support.appendingPathComponent("telemetry.json")
    private var timer: Timer?
    private var sending = false

    var isSharing: Bool { Host.shared.settings.shareStatistics == true }

    /// The public dashboard: the collector's origin.
    var dashboard: URL? {
        guard let endpoint, var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        c.path = "/"
        return c.url
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await Telemetry.shared.sendPending() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await sendPending()
        }
    }

    /// Called when the user changes the setting. Turning sharing off forgets the install ID.
    func sharingChanged(_ on: Bool) {
        if on { Task { await sendPending() } } else { try? FileManager.default.removeItem(at: file) }
    }

    func resetID() {
        save(State(install: UUID().uuidString))
    }

    /// The report the app would send for today so far, pretty-printed (Settings → "Show what's sent").
    func preview() -> String {
        let install = loadState()?.install ?? "(created when the first report is sent)"
        let report = TelemetryReport.make(day: Date(), events: UsageStore.shared.events, install: install, environment: environment())
        guard let report else { return "Nothing recorded today yet, so there is nothing to send." }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func sendPending() async {
        guard isSharing, let endpoint, !sending else { return }
        sending = true
        defer { sending = false }
        var state = loadState() ?? State(install: UUID().uuidString)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let env = environment()
        for offset in (1...Self.catchUpDays).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = TelemetryReport.dayString(day)
            guard !state.sent.contains(key),
                  let report = TelemetryReport.make(day: day, events: UsageStore.shared.events, install: state.install, environment: env)
            else { continue }
            guard await post(report, to: endpoint) else { break }
            state.sent.append(key)
        }
        state.sent = Array(state.sent.suffix(Self.catchUpDays * 2))
        save(state)
    }

    private func post(_ report: TelemetryReport, to url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(report)
        // Ephemeral: no cookies, no cache, nothing that could identify the install beyond the report itself.
        let session = URLSession(configuration: .ephemeral)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        // 4xx means the server rejected this report for good (bad schema, duplicate); don't retry it forever.
        return (200..<500).contains(http.statusCode) && http.statusCode != 429
    }

    private func environment() -> TelemetryReport.Environment {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let settings = Host.shared.settings
        let builtIns = Set(BuiltIns.ids)
        return .init(
            app: .init(version: version, build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                       channel: version.contains("-") ? "beta" : "stable"),
            system: .init(macos: "\(os.majorVersion).\(os.minorVersion)", arch: Self.arch,
                          region: Locale.current.region?.identifier, language: Locale.current.language.languageCode?.identifier),
            settings: .init(hotkey: settings.hotkey, appearance: settings.appearance,
                            disabled: settings.disabledExtensions.filter { builtIns.contains($0) }.sorted(),
                            externalExtensions: Host.shared.allExtensions.filter { !builtIns.contains($0.manifest.id) }.count),
            builtIns: builtIns)
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func loadState() -> State? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    private func save(_ state: State) {
        try? JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
}
