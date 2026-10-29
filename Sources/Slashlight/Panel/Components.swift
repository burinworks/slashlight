import AppKit
import SwiftUI
import SlashlightKit

struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Theme.keycapFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Theme.keycapBorder, lineWidth: 0.75))
    }
}

struct Pill: View {
    let text: String
    let tint: Tint

    var body: some View {
        let c = Theme.pill(tint)
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(c.fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(c.bg, in: Capsule())
            .overlay(Capsule().stroke(c.fg.opacity(0.15), lineWidth: 0.5))
    }
}

struct IconView: View {
    let icon: Icon
    var size: CGFloat = 32

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.45, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        case .file(let path):
            Image(nsImage: IconCache.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        case .text(let t):
            Text(t)
                .font(.system(size: size * 0.5))
                .frame(width: size, height: size)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        }
    }
}

struct AccessoryView: View {
    let accessory: Accessory

    var body: some View {
        switch accessory {
        case .pill(let t, let tint): Pill(text: t, tint: tint)
        case .text(let t): Text(t).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
        case .keycap(let s): Keycap(label: s.display)
        }
    }
}

struct ResultRow: View {
    let row: PaletteModel.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconView(icon: row.item.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.item.title)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let sub = row.item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            ForEach(Array(row.item.accessories.enumerated()), id: \.offset) { _, a in AccessoryView(accessory: a) }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: row.item.subtitle?.isEmpty == false ? 50 : 44)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct GridTile: View {
    let row: PaletteModel.Row
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.tile)
                switch row.item.icon {
                case .image(let img):
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(4)
                default:
                    IconView(icon: row.item.icon, size: 56)
                }
            }
            .frame(height: 118)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            Text(row.item.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            if let sub = row.item.subtitle {
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .padding(6)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// NSTextField wrapper: reliable first-responder control in a non-activating panel.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCreate: (NSTextField) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        onCreate(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 18),
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
