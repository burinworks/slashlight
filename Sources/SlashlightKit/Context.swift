import AppKit

/// Services the host gives every extension.
@MainActor
public protocol ExtensionContext: AnyObject {
    /// Per-extension key-value storage. `.ephemeral` is lost on quit (clipboard history),
    /// `.persistent` survives restarts (snippets).
    func storage(_ kind: StorageKind) -> KeyValueStorage

    /// `~/Library/Application Support/Slashlight/<extension id>/`, created on demand.
    var supportDirectory: URL { get }

    /// The app that was in front before the panel opened — the target for window and paste actions.
    var frontmostApplication: NSRunningApplication? { get }

    func copy(_ text: String)
    func showHUD(_ message: String)
    /// Re-run the current search (call it when your data changed while the panel is open).
    func refresh()
    /// Show the panel with this extension's root screen.
    func present(extensionID: String)
    func close()
}

public enum StorageKind {
    case ephemeral
    case persistent
}

@MainActor
public protocol KeyValueStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

extension KeyValueStorage {
    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public func set<T: Encodable>(_ value: T, forKey key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// In-memory storage.
@MainActor
public final class MemoryStorage: KeyValueStorage {
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { values[key] }
    public func set(_ data: Data?, forKey key: String) { values[key] = data }
}

/// One JSON file per key inside a directory.
@MainActor
public final class FileStorage: KeyValueStorage {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    public func data(forKey key: String) -> Data? { try? Data(contentsOf: url(key)) }

    public func set(_ data: Data?, forKey key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data { try? data.write(to: url(key), options: .atomic) } else { try? FileManager.default.removeItem(at: url(key)) }
    }
}
