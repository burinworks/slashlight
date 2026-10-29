import AppKit
import SwiftUI
import SlashlightKit

/// A built-in screen that shows a live AppKit view (a terminal, a text editor) in place of the result list.
/// It is attached to an ordinary `ListView`, so it rides the normal screen stack (push, pop, ⌫).
/// Host-only: external extensions cannot create these.
@MainActor
final class EmbeddedScreen {
    let view: NSView
    /// The view that should receive typing (e.g. the text view inside a scroll view).
    let focus: NSView
    let height: CGFloat
    /// Return true when the key was handled; anything else is delivered to `focus`.
    let handleKey: (NSEvent, PaletteModel) -> Bool
    let hints: () -> [PaletteModel.Hint]

    init(view: NSView, focus: NSView? = nil, height: CGFloat = 420,
         hints: @escaping () -> [PaletteModel.Hint] = { [] },
         handleKey: @escaping (NSEvent, PaletteModel) -> Bool) {
        self.view = view
        self.focus = focus ?? view
        self.height = height
        self.hints = hints
        self.handleKey = handleKey
    }

    private static let table = NSMapTable<ListView, EmbeddedScreen>.weakToStrongObjects()

    /// Makes `list` show this screen's view instead of its results.
    func attach(to list: ListView) { Self.table.setObject(self, forKey: list) }

    static func of(_ list: ListView?) -> EmbeddedScreen? { list.flatMap { table.object(forKey: $0) } }
}

/// Hosts an existing NSView inside SwiftUI without recreating it, so a terminal keeps its state between visits.
struct EmbeddedHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        place(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { place(in: container) }
    }

    private func place(in container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Multi-line text editor screen (snippets). ⌘↵ saves, Esc goes back without saving.
enum TextEditorScreen {
    @MainActor
    static func make(title: String, icon: Icon, text: String, placeholder: String,
                     save: @escaping (String) -> Void) -> ListView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textView = scroll.documentView as! NSTextView
        textView.string = text
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 12)

        let list = ListView(title: title, icon: icon, placeholder: placeholder) { _ in [] }
        let screen = EmbeddedScreen(
            view: scroll, focus: textView, height: 300,
            hints: { [PaletteModel.Hint(keys: "⌘↵", label: "Save"), PaletteModel.Hint(keys: "esc", label: "Cancel"),
                      PaletteModel.Hint(keys: "↵", label: "New line")] }
        ) { event, model in
            let mods = Shortcut.Modifiers(event.modifierFlags)
            switch (KeyCodes.key(for: event), mods) {
            case ("return", [.command]), ("enter", [.command]):
                save(textView.string)
                model.pop()
                return true
            case ("escape", _):
                model.pop()
                return true
            default:
                return false
            }
        }
        screen.attach(to: list)
        return list
    }
}
