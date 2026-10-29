import SlashlightSDK

/// A complete out-of-process extension: type `/hello` or `/hello Alex` in Slashlight.
final class HelloExtension: Extension {
    override var manifest: Manifest {
        Manifest(id: "hello", title: "Hello", subtitle: "Example out-of-process extension", icon: .symbol("hand.wave"))
    }

    override var triggers: [Trigger] { [.commands, .command("hello")] }

    override func search(_ query: Query) async throws -> [Section] {
        let name = query.text.replacingOccurrences(of: "hello", with: "").trimmingCharacters(in: .whitespaces)
        guard query.mode == .scoped || "hello".hasPrefix(query.text.prefix(5).lowercased()) else { return [] }
        let greeting = "Hello, \(name.isEmpty ? "world" : name)!"
        let demos = [
            Item(id: "count", title: "Count to 5", subtitle: "Sub-screen with streaming output",
                 icon: .symbol("timer"), primary: Action("Count") { .push(Self.counter()) }),
            Item(id: "waves", title: "Pick a Wave", subtitle: "Grid sub-screen with Tab filters",
                 icon: .symbol("square.grid.3x3"), primary: Action("Open") { .push(Self.waves()) }),
        ]
        // `/hello count` narrows to the demo screens; any other name is a greeting.
        let matching = demos.filter { !name.isEmpty && $0.title.localizedCaseInsensitiveContains(name) }
        if !matching.isEmpty { return [Section("Hello", matching)] }
        return [Section("Hello", [
            Item(id: "greet", title: greeting, subtitle: "Shows a toast · ⌘↵ pastes it",
                 icon: .symbol("hand.wave"), accessories: [.pill("Example")],
                 primary: Action("Say Hello") { .hud(greeting) },
                 secondary: Action("Paste Greeting") { .paste(greeting) },
                 more: [Action("Copy Greeting", shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                     self?.context.copy(greeting)
                     return .hud("Copied")
                 }]),
        ] + demos)]
    }

    /// A screen whose detail area gets one line per second, like a running command.
    private static func counter() -> ListView {
        let detail = DetailModel(text: "", isRunning: true)
        Task { @MainActor in
            for n in 1...5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                detail.text += "\(n)\n"
            }
            detail.isRunning = false
        }
        return ListView(title: "Count to 5", icon: .symbol("timer"), placeholder: "Counting…", detail: detail) { _ in
            [Section("Counter", [
                Item(id: "back", title: "Back", icon: .symbol("chevron.left"), primary: Action("Back") { .pop }),
            ])]
        }
    }

    private static let emoji: [(String, String)] = [
        ("👋", "Hands"), ("🤚", "Hands"), ("🖐️", "Hands"), ("✋", "Hands"), ("🖖", "Hands"), ("🫱", "Hands"),
        ("🌊", "Water"), ("🏄", "Water"), ("🐬", "Water"), ("🐳", "Water"), ("⛵", "Water"), ("🐚", "Water"),
    ]

    private static func waves() -> ListView {
        ListView(title: "Pick a Wave", icon: .symbol("square.grid.3x3"), placeholder: "Filter waves…",
                 layout: .grid(columns: 3), filters: ["All", "Hands", "Water"]) { query in
            let picked = emoji.enumerated().filter { query.filter == nil || query.filter == "All" || $0.element.1 == query.filter }
            return [Section(query.filter ?? "All", picked.map { i, e in
                Item(id: "wave-\(i)", title: e.0, subtitle: e.1, icon: .text(e.0),
                     primary: Action("Choose") { .pop },
                     secondary: Action("Paste") { .paste(e.0) })
            })]
        }
    }
}

ExtensionRunner.run { HelloExtension() }
