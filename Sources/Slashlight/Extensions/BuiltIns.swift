import SlashlightKit

enum BuiltIns {
    /// Default-search results appear in this order: the calculator answer first, the web search fallback last.
    @MainActor
    static func all() -> [Extension] {
        [CalculatorExtension(), AppsExtension(), FilesExtension(), SystemCommandsExtension(), CommandsExtension(), ScriptCommandsExtension(),
         ClipboardExtension(), SnippetsExtension(), EmojiExtension(), WindowManagementExtension(), WindowSwitcherExtension(),
         TerminalExtension(), WebSearchExtension()]
    }
}
