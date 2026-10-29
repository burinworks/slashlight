import AppKit
import SwiftUI
import SlashlightKit

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @ObservedObject var terminals = TerminalManager.shared
    let onCreateField: (NSTextField) -> Void
    let onHeight: (CGFloat) -> Void

    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Rectangle().fill(Theme.divider).frame(height: 1)
            if let embedded = model.embedded {
                EmbeddedHost(view: embedded.view)
                    .padding(embedded.focus is NSTextView ? 0 : 8)
                    .frame(height: embedded.height)
                    .background(embedded.focus is NSTextView ? Color.clear : Theme.detail)
            } else {
                if let detail = model.currentView?.detail {
                    DetailPane(detail: detail)
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
                results
                if !terminals.sessions.isEmpty {
                    TerminalTabs(manager: terminals, current: nil) { model.showTerminal($0) }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            footer
        }
        .frame(width: Theme.width)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Search row

    private var searchRow: some View {
        HStack(spacing: 10) {
            if let view = model.currentView {
                HStack(spacing: 6) {
                    IconView(icon: view.icon, size: 20)
                    Text(view.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .padding(.leading, 2)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onTapGesture { model.pop() }
                .help("⌫ to go back")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.text)
            }
            if let embedded = model.embedded {
                if let session = terminals.sessions.first(where: { $0.embedded === embedded }) {
                    TerminalTabs(manager: terminals, current: session) { model.showTerminal($0) }
                } else {
                    Spacer()
                }
            } else {
                SearchField(text: $model.text, placeholder: model.placeholder, onCreate: onCreateField)
                    .frame(height: 26)
            }
            if model.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            extensionMenu
            Keycap(label: "esc").onTapGesture { model.host.hide() }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var extensionMenu: some View {
        Menu {
            Button("All (default search)") { model.goHome() }
            Divider()
            ForEach(Array(model.host.extensions.enumerated()), id: \.offset) { _, ext in
                if ext.rootView() != nil {
                    Button(ext.manifest.title) { model.goHome(); model.open(ext) }
                }
            }
            Divider()
            Button("Settings…") { model.openSettings() }
        } label: {
            HStack(spacing: 4) {
                Text(model.currentView == nil ? "All" : model.stack.compactMap { $0.extensionID }.last.flatMap { model.host.ext($0)?.manifest.title } ?? "All")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Extensions (⌘E shows them all)")
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if model.rows.isEmpty {
            if !model.text.isEmpty && !model.isLoading {
                Text("No results")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .padding(8)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), Theme.maxListHeight))
                .onChange(of: model.selection) { _, new in
                    if let row = model.rows[safe: new] { proxy.scrollTo(row.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.sections) { section in
                Text(section.title.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                if model.isGrid {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: model.gridColumns), spacing: 8) {
                        ForEach(section.rows) { row in
                            GridTile(row: row, selected: row.index == model.selection, compact: model.gridColumns >= 6)
                                .id(row.id)
                                .onHover { if $0 { model.hover(row.index) } }
                                .onTapGesture { model.click(row.index) }
                        }
                    }
                } else {
                    ForEach(section.rows) { row in
                        ResultRow(row: row, selected: row.index == model.selection)
                            .id(row.id)
                            .onHover { if $0 { model.hover(row.index) } }
                            .onTapGesture { model.click(row.index) }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            ForEach(model.hints) { hint in
                HStack(spacing: 6) {
                    Keycap(label: hint.keys)
                    Text(hint.label).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Theme.footer)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

struct DetailPane: View {
    @ObservedObject var detail: DetailModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(detail.text.isEmpty ? (detail.isRunning ? "Running…" : "(no output)") : detail.text)
                    .font(detail.monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 220)
            .background(Theme.detail)
            .onChange(of: detail.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}



/// Open terminals as small tabs: a dot for the state (green = task running), the title, and how long it has run.
struct TerminalTabs: View {
    @ObservedObject var manager: TerminalManager
    let current: TerminalSession?
    let select: (TerminalSession) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if current == nil {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                ForEach(Array(manager.sessions.enumerated()), id: \.element.id) { i, session in
                    TerminalTab(session: session, index: i, selected: session === current)
                        .onTapGesture { select(session) }
                }
                if current == nil {
                    Keycap(label: "⌃⇥").padding(.leading, 4)
                }
            }
        }
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(session.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: 160)
            if case .busy(_, let since) = session.state {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(TerminalSession.duration(since)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
            }
            if index < 9 { Text("⌘\(index + 1)").font(.system(size: 10)).foregroundStyle(Theme.secondary) }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(selected ? Theme.selection : Theme.tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected ? Theme.border : .clear, lineWidth: 1))
        .help(session.activity)
    }

    private var dot: Color {
        switch session.state {
        case .busy: return .green
        case .idle: return Theme.secondary
        case .exited(let code): return code == 0 ? Theme.secondary.opacity(0.4) : .red
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
