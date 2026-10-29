import AppKit
import SlashlightKit

/// The fallback at the bottom of default search: look the text up on the web.
/// ↵ searches Google, ⌘↵ DuckDuckGo.
final class WebSearchExtension: Extension {
    override var manifest: Manifest {
        Manifest(id: "web-search", title: "Search the Web", subtitle: "Google or DuckDuckGo for whatever you typed", icon: .symbol("globe"))
    }

    override var triggers: [Trigger] { [.defaultSearch] }

    /// Only a fallback; it has no screen of its own.
    override func rootView() -> ListView? { nil }

    override func search(_ query: Query) async throws -> [Section] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard query.mode == .default, !text.isEmpty else { return [] }
        let google = Action("Search Google", icon: .symbol("magnifyingglass")) { Self.open("https://www.google.com/search?q=", text) }
        let duck = Action("Search DuckDuckGo", icon: .symbol("magnifyingglass")) { Self.open("https://duckduckgo.com/?q=", text) }
        return [Section("Search the Web", [
            Item(id: "google", title: "Search Google for “\(text)”", icon: .symbol("globe"), primary: google, secondary: duck),
            Item(id: "duckduckgo", title: "Search DuckDuckGo for “\(text)”", icon: .symbol("globe"), primary: duck, secondary: google),
        ])]
    }

    private static func open(_ base: String, _ text: String) -> Outcome {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed), let url = URL(string: base + q) else { return .close }
        NSWorkspace.shared.open(url)
        return .close
    }
}
