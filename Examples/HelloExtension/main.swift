import SpotlightSDK

/// A complete out-of-process extension: type `/hello` or `/hello Alex` in My Spotlight.
final class HelloExtension: Extension {
    override var manifest: Manifest {
        Manifest(id: "hello", title: "Hello", subtitle: "Example out-of-process extension", icon: .symbol("hand.wave"))
    }

    override var triggers: [Trigger] { [.commands, .command("hello")] }

    override func search(_ query: Query) async throws -> [Section] {
        let name = query.text.replacingOccurrences(of: "hello", with: "").trimmingCharacters(in: .whitespaces)
        guard query.mode == .scoped || "hello".hasPrefix(query.text.prefix(5).lowercased()) else { return [] }
        let greeting = "Hello, \(name.isEmpty ? "world" : name)!"
        return [Section("Hello", [
            Item(id: "greet", title: greeting, subtitle: "Shows a toast · ⌘↵ pastes it",
                 icon: .symbol("hand.wave"), accessories: [.pill("Example")],
                 primary: Action("Say Hello") { .hud(greeting) },
                 secondary: Action("Paste Greeting") { .paste(greeting) },
                 more: [Action("Copy Greeting", shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                     self?.context.copy(greeting)
                     return .hud("Copied")
                 }]),
        ])]
    }
}

ExtensionRunner.run { HelloExtension() }
