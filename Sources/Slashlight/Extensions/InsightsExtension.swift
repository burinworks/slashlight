import AppKit
import Charts
import SwiftUI
import SlashlightKit

/// Usage Insights: what you use Slashlight for, as a dashboard. The data never leaves this Mac.
/// Turning the extension off in Settings also stops recording.
final class InsightsExtension: Extension {
    override var manifest: Manifest {
        Manifest(id: "insights", title: "Usage Insights", subtitle: "What you use most, when, and how fast",
                 icon: .symbol("chart.bar.xaxis"))
    }

    override var triggers: [Trigger] { [.commands, .command("insights")] }

    override func search(_ query: Query) async throws -> [SlashlightKit.Section] {
        // `/stats` and `/usage` find the dashboard too.
        guard query.mode == .command, ["stats", "usage", "analytics"].contains(where: { $0.hasPrefix(query.text.lowercased()) && query.text.count >= 2 })
        else { return [] }
        return [SlashlightKit.Section("Usage Insights", [
            Item(id: "open", title: "Usage Insights", subtitle: manifest.subtitle, icon: manifest.icon,
                 primary: Action("Open") { [unowned self] in self.rootView().map { .push($0) } ?? .stay }),
        ])]
    }

    override func rootView() -> ListView? {
        let model = InsightsModel(extensions: { Self.extensionTitles() })
        let host = NSHostingView(rootView: InsightsDashboard(model: model))
        let list = ListView(title: manifest.title, icon: manifest.icon, placeholder: "") { _ in [] }
        let screen = EmbeddedScreen(view: host, height: 460, hints: {
            [PaletteModel.Hint(keys: "tab", label: model.period.rawValue),
             PaletteModel.Hint(keys: "↑↓", label: "Scroll"),
             PaletteModel.Hint(keys: "⌘⌫", label: "Back"),
             PaletteModel.Hint(keys: "⌘⇧⌫", label: model.confirmClear ? "Press again to clear" : "Clear data")]
        }) { event, palette in
            let mods = Shortcut.Modifiers(event.modifierFlags)
            switch (KeyCodes.key(for: event), mods) {
            case ("tab", []): model.cyclePeriod(1)
            case ("tab", [.shift]): model.cyclePeriod(-1)
            case ("down", _), ("n", [.control]): model.scroll(1)
            case ("up", _), ("p", [.control]): model.scroll(-1)
            case ("delete", [.command]), ("[", [.command]): palette.pop()
            case ("delete", [.command, .shift]): model.clear()
            case ("escape", _): palette.host.hide()
            default: return false
            }
            palette.objectWillChange.send() // refresh the footer hints
            return true
        }
        screen.attach(to: list)
        return list
    }

    @MainActor
    private static func extensionTitles() -> [String: String] {
        // Everything you can open, plus the calculator (answers only). Not this extension: its rootView builds the dashboard.
        Dictionary(Host.shared.extensions.filter { $0.manifest.id != "insights" && ($0.rootView() != nil || $0.manifest.id == "calculator") }
            .map { ($0.manifest.id, $0.manifest.title) }, uniquingKeysWith: { a, _ in a })
    }
}

@MainActor
final class InsightsModel: ObservableObject {
    @Published var period: UsageReport.Period = .week { didSet { reload() } }
    @Published private(set) var report: UsageReport
    @Published var confirmClear = false
    @Published var scrollTarget: Int = 0

    static let sections = 4
    private let extensions: () -> [String: String]

    init(extensions: @escaping () -> [String: String]) {
        self.extensions = extensions
        report = UsageReport(events: UsageStore.shared.events, period: .week, extensions: extensions())
    }

    func reload() {
        report = UsageReport(events: UsageStore.shared.events, period: period, extensions: extensions())
    }

    func cyclePeriod(_ delta: Int) {
        let all = UsageReport.Period.allCases
        period = all[(all.firstIndex(of: period)! + delta + all.count) % all.count]
        confirmClear = false
    }

    func scroll(_ delta: Int) {
        scrollTarget = max(0, min(Self.sections - 1, scrollTarget + delta))
    }

    func clear() {
        if confirmClear {
            UsageStore.shared.clear()
            confirmClear = false
            reload()
        } else {
            confirmClear = true
        }
    }
}

struct InsightsDashboard: View {
    @ObservedObject var model: InsightsModel
    private var r: UsageReport { model.report }
    private let accent = Color(nsColor: NSColor(hex: 0x6E6AE8))

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header.id(0)
                    tiles
                    activity.id(1)
                    HStack(alignment: .top, spacing: 16) {
                        topExtensions
                        topItems
                    }
                    .id(2)
                    insights.id(3)
                    Text("Stored only on this Mac, in ~/Library/Application Support/Slashlight/usage. Turn Usage Insights off in Settings → Extensions to stop recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(14)
            }
            .onChange(of: model.scrollTarget) { _, target in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(range).font(.system(size: 18, weight: .semibold))
                Text("\(r.activeDays) active day\(r.activeDays == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(UsageReport.Period.allCases, id: \.self) { p in
                    Text(p.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(p == model.period ? Theme.panel : .clear))
                        .foregroundStyle(p == model.period ? Theme.text : Theme.secondary)
                        .onTapGesture { model.period = p }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.tile))
        }
    }

    private var range: String {
        guard let first = r.daily.first?.date, let last = r.daily.last?.date else { return model.period.rawValue }
        return first.formatted(.dateTime.month(.abbreviated).day()) + " – " + last.formatted(.dateTime.month(.abbreviated).day())
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            tile("Actions", "\(r.actions)", "bolt.fill")
            tile("Panel opens", "\(r.opens)", "rectangle.and.text.magnifyingglass")
            tile("Time saved", r.minutesSaved < 60 ? "\(Int(r.minutesSaved.rounded())) min" : String(format: "%.1f h", r.minutesSaved / 60), "hourglass")
            tile("Streak", "\(r.streak) day\(r.streak == 1 ? "" : "s")", "flame.fill")
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private var activity: some View {
        HStack(alignment: .top, spacing: 16) {
            card("Actions per day") {
                Chart(r.daily) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Actions", day.count))
                        .foregroundStyle(accent.gradient)
                        .cornerRadius(3)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 120)
            }
            card("Time of day") {
                Chart(Array(r.hourly.enumerated()), id: \.offset) { hour, count in
                    BarMark(x: .value("Hour", hour), y: .value("Actions", count))
                        .foregroundStyle(accent.opacity(0.75).gradient)
                        .cornerRadius(2)
                }
                .chartXScale(domain: 0...23)
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { v in
                    AxisValueLabel { Text(UsageReport.hour(v.as(Int.self) ?? 0)) }
                } }
                .chartYAxis(.hidden)
                .frame(height: 120)
            }
            .frame(width: 230)
        }
    }

    private var topExtensions: some View {
        card("Top extensions") {
            if r.byExtension.isEmpty { empty } else {
                let top = Array(r.byExtension.prefix(6))
                let maxCount = Double(top.first?.count ?? 1)
                VStack(spacing: 7) {
                    ForEach(top) { c in
                        HStack(spacing: 8) {
                            Text(c.key).font(.system(size: 12)).frame(width: 110, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3).fill(accent.gradient)
                                    .frame(width: max(4, g.size.width * Double(c.count) / maxCount))
                            }
                            .frame(height: 10)
                            Text("\(c.count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.secondary).frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var topItems: some View {
        card("Most used") {
            if r.topItems.isEmpty { empty } else {
                VStack(spacing: 6) {
                    ForEach(Array(r.topItems.prefix(6).enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.secondary).frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.key).font(.system(size: 12)).lineLimit(1)
                                if let d = c.detail { Text(d).font(.system(size: 10)).foregroundStyle(Theme.secondary) }
                            }
                            Spacer()
                            Text("\(c.count)×").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
    }

    private var insights: some View {
        card("Insights") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(r.insights, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(accent)
                        Text(line).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 14) {
                    if let s = r.firstResultShare { metric("First-result picks", "\(Int(s * 100))%") }
                    if let s = r.keyboardShare { metric("From the keyboard", "\(Int(s * 100))%") }
                    if let l = r.medianLatency { metric("Open → action", String(format: "%.1f s", Double(l) / 1000)) }
                    metric("Active days", "\(r.activeDays)")
                }
                .padding(.top, 4)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.secondary)
        }
    }

    private var empty: some View {
        Text("No data for this period yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}
