import SlashlightKit

enum BuiltIns {
    /// Manifest ids of every built-in, for telemetry: anything else is reported as "external".
    static let ids = ["calculator", "apps", "files", "system", "commands", "script-commands", "clipboard", "snippets", "emoji",
                      "window-management", "window-switcher", "terminal", "insights", "web-search"]

    /// Default-search results appear in this order: the calculator answer first, the web search fallback last.
    @MainActor
    static func all() -> [Extension] {
        [CalculatorExtension(), AppsExtension(), FilesExtension(), SystemCommandsExtension(), CommandsExtension(), ScriptCommandsExtension(),
         ClipboardExtension(), SnippetsExtension(), EmojiExtension(), WindowManagementExtension(), WindowSwitcherExtension(),
         TerminalExtension(), InsightsExtension(), WebSearchExtension()]
    }
}
