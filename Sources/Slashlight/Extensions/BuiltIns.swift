import SlashlightKit

enum BuiltIns {
    @MainActor
    static func all() -> [Extension] {
        [AppsExtension(), FilesExtension(), CommandsExtension(), ClipboardExtension(), SnippetsExtension(),
         WindowManagementExtension(), WindowSwitcherExtension(), TerminalExtension()]
    }
}
