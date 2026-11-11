import AppKit
import CryptoKit
import Foundation
import Security

/// One thing the user copied, with every format the source app offered (plain text, rich text, HTML, images,
/// file references…). Copying it back writes all of them, so Google Docs, Pages or Figma keep their formatting.
struct ClipEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case text, link, image, files }

    var id = UUID()
    var date: Date
    var source: String?
    var kind: Kind
    /// Plain text; for files, their paths one per line. Used for titles and search.
    var text: String
    /// The pasteboard items, each as type → data.
    var items: [[String: Data]]
    /// Same content copied again moves the old entry to the top instead of adding a new one.
    var fingerprint: String
    /// Width and height in pixels, for images.
    var pixels: [Int]?

    var byteCount: Int { items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    var fileURLs: [URL] {
        kind == .files ? text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } : []
    }

    /// The first image representation (PNG, TIFF, JPEG…).
    var imageData: Data? {
        for item in items {
            for type in ClipboardCapture.imageTypes { if let d = item[type] { return d } }
        }
        return nil
    }
}

/// Reads and writes the system pasteboard as `ClipEntry` values.
enum ClipboardCapture {
    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"]
    /// The formats worth keeping when a copy is too large to keep in full.
    private static let essentialTypes: Set<String> = Set(imageTypes + [
        "public.utf8-plain-text", "public.rtf", "public.html", "public.file-url", "public.url",
    ])
    /// Larger copies keep only the essential formats; a copy still over the limit is not recorded.
    static let maxBytes = 50 * 1024 * 1024

    /// Password managers mark secrets with these (nspasteboard.org); such copies are never recorded.
    static func isSecret(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        return types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    static func capture(_ pb: NSPasteboard, source: String?, now: Date = Date()) -> ClipEntry? {
        guard !isSecret(pb), let pbItems = pb.pasteboardItems, !pbItems.isEmpty else { return nil }
        var items: [[String: Data]] = pbItems.map { item in
            var out: [String: Data] = [:]
            // Promised files exist only while the source app can still provide them.
            for type in item.types where !type.rawValue.contains("promise") {
                if let data = item.data(forType: type) { out[type.rawValue] = data }
            }
            return out
        }
        if total(items) > maxBytes { items = items.map { $0.filter { essentialTypes.contains($0.key) } } }
        guard total(items) <= maxBytes, items.contains(where: { !$0.isEmpty }) else { return nil }

        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        // Some apps put only rich text on the clipboard; read its plain text for the title and search.
        let raw = pb.string(forType: .string) ?? plainText(pb) ?? ""
        let string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = ClipEntry(date: now, source: source, kind: .text, text: "", items: items, fingerprint: "")
        if !files.isEmpty {
            entry.kind = .files
            entry.text = files.map(\.path).joined(separator: "\n")
            entry.fingerprint = "files:" + entry.text
        } else if !string.isEmpty {
            entry.kind = isLink(raw) ? .link : .text
            entry.text = raw
            entry.fingerprint = "text:" + hash(Data(raw.utf8))
        } else if let data = entry.imageData, let rep = NSBitmapImageRep(data: data) {
            entry.kind = .image
            entry.text = "Image"
            entry.pixels = [rep.pixelsWide, rep.pixelsHigh]
            entry.fingerprint = "image:" + hash(data)
        } else {
            return nil
        }
        return entry
    }

    /// Puts every saved format back on the pasteboard.
    static func restore(_ entry: ClipEntry, to pb: NSPasteboard) {
        pb.clearContents()
        let items: [NSPasteboardItem] = entry.items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pb.writeObjects(items)
    }

    private static func plainText(_ pb: NSPasteboard) -> String? {
        for (type, kind) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf), (.html, .html)] {
            if let data = pb.data(forType: type),
               let s = try? NSAttributedString(data: data, options: [.documentType: kind], documentAttributes: nil) {
                return s.string
            }
        }
        return nil
    }

    static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(" ") && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }

    private static func total(_ items: [[String: Data]]) -> Int { items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Clipboard history on disk: one AES-GCM encrypted file per entry. The key lives in the login Keychain,
/// so the files are unreadable on their own (a backup, another account, a stolen disk image).
final class ClipboardVault: @unchecked Sendable {
    let directory: URL
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "dev.slashlight.clipboard-vault")

    init(directory: URL, key: SymmetricKey) {
        self.directory = directory
        self.key = key
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".clip") }

    func save(_ entry: ClipEntry) {
        queue.async { [self] in
            guard let plain = try? PropertyListEncoder.binary.encode(entry),
                  let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
            try? sealed.write(to: url(entry.id), options: [.atomic])
        }
    }

    func delete(_ ids: [UUID]) {
        queue.async { [self] in ids.forEach { try? FileManager.default.removeItem(at: url($0)) } }
    }

    func deleteAll() {
        queue.async { [self] in
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "clip" { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Every entry that decrypts, newest first. Files from another key (a reset Keychain) are skipped.
    func loadAll() -> [ClipEntry] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "clip" }.compactMap { f -> ClipEntry? in
                guard let data = try? Data(contentsOf: f), let box = try? AES.GCM.SealedBox(combined: data),
                      let plain = try? AES.GCM.open(box, using: key) else { return nil }
                return try? PropertyListDecoder().decode(ClipEntry.self, from: plain)
            }
            .sorted { $0.date > $1.date }
        }
    }

    /// Waits for pending writes (tests).
    func flush() { queue.sync {} }

    // MARK: Keychain

    /// Development builds (another app ID, or a bare binary) keep their own key, so they never ask for the release app's.
    private static let service = Bundle.main.bundleIdentifier == "dev.slashlight.app" ? "dev.slashlight.clipboard" : "dev.slashlight.clipboard.dev"
    /// The history folder that matches `service`: files encrypted with the other key would be unreadable.
    static let folder = Bundle.main.bundleIdentifier == "dev.slashlight.app" ? "history" : "history-dev"

    /// The history key, created on first use.
    static func keychainKey() -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "history-key", kSecReturnData as String: true]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "history-key", kSecAttrLabel as String: "Slashlight clipboard history",
                                  kSecValueData as String: data]
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }
}
