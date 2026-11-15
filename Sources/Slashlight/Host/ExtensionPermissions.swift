import Foundation

/// What an extension or script command says it needs (`permissions` in manifest.json, `@slashlight.*` header lines
/// in a script). Anything not listed here is blocked by the sandbox. See docs/extension-permissions.md.
struct ExtensionPermissions: Equatable {
    enum Network: Equatable {
        case none
        case any
        /// Until the filtering proxy ships, a host list lets the extension connect anywhere (rollout step 4).
        case hosts([String])
    }

    var network: Network = .none
    /// Absolute, validated folders.
    var read: [URL] = []
    var write: [URL] = []
    var defaultSearch = false
    var background = false
    var subprocesses = false
    /// Open apps, files and websites through Launch Services (`open`). An opened app runs outside the sandbox.
    var open = false

    struct Invalid: LocalizedError, Equatable {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Folders no permission can reach. Checked when a manifest is read, and denied again in the sandbox profile.
    static let neverAllowed = [
        "Library", ".ssh", ".gnupg", ".aws", ".azure", ".config/gh", ".config/gcloud", ".docker", ".kube",
        ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".password-store", ".zsh_history", ".bash_history",
        ".local/share/keyrings",
    ]

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL }

    /// `~/Documents` → absolute URL, or why the folder can't be granted.
    static func folder(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.contains("*"), !text.contains("?") else { throw Invalid("\(raw): wildcards aren't allowed; name the folder") }
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Invalid("\(raw): use a path starting with ~/") }
        guard !expanded.split(separator: "/").contains("..") else { throw Invalid("\(raw): \"..\" isn't allowed") }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let home = home.path
        guard url.path.hasPrefix(home + "/") else {
            throw Invalid(url.path == home ? "\(raw): the whole home folder can't be granted" : "\(raw): only folders in your home folder can be granted")
        }
        let relative = String(url.path.dropFirst(home.count + 1))
        if let blocked = neverAllowed.first(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
            throw Invalid("\(raw): ~/\(blocked) is never shared with extensions")
        }
        return url
    }

    // MARK: manifest.json

    struct FileBlock: Codable, Equatable {
        struct Files: Codable, Equatable {
            var read: [String]?
            var write: [String]?
        }

        enum NetworkValue: Codable, Equatable {
            case any
            case hosts([String])

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) {
                    guard s == "any" else { throw Invalid("network: use \"any\" or a list of hosts") }
                    self = .any
                } else {
                    self = .hosts(try c.decode([String].self))
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .any: try c.encode("any")
                case .hosts(let h): try c.encode(h)
                }
            }
        }

        var network: NetworkValue?
        var files: Files?
        var defaultSearch: Bool?
        var background: Bool?
        var subprocesses: Bool?
        var open: Bool?
    }

    init() {}

    init(_ block: FileBlock?) throws {
        guard let block else { return }
        switch block.network {
        case nil: network = .none
        case .any: network = .any
        case .hosts(let hosts):
            let cleaned = try hosts.map(Self.host)
            network = cleaned.isEmpty ? .none : .hosts(cleaned)
        }
        write = try (block.files?.write ?? []).map(Self.folder)
        read = try (block.files?.read ?? []).map(Self.folder)
        defaultSearch = block.defaultSearch ?? false
        background = block.background ?? false
        subprocesses = block.subprocesses ?? false
        open = block.open ?? false
    }

    /// `api.example.com` or `*.example.com`.
    static func host(_ raw: String) throws -> String {
        let h = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let bare = h.hasPrefix("*.") ? String(h.dropFirst(2)) : h
        let ok = !bare.isEmpty && bare.contains(".") && !bare.contains("*")
            && bare.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard ok else { throw Invalid("network: \(raw) isn't a host name") }
        return h
    }

    // MARK: Script headers

    /// Raycast script commands have no manifest. `# @slashlight.network api.github.com`,
    /// `# @slashlight.files.read ~/Documents`, `# @slashlight.files.write ~/Notes`, `# @slashlight.open true`.
    /// A script always gets `subprocesses`, since a shell script runs other programs.
    init(scriptHeaders meta: [String: String]) throws {
        func list(_ key: String) -> [String] {
            (meta[key] ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        }
        let net = list("network")
        if net == ["any"] { network = .any } else if !net.isEmpty { network = .hosts(try net.map(Self.host)) }
        write = try list("files.write").map(Self.folder)
        read = try list("files.read").map(Self.folder)
        open = meta["open"] == "true"
        subprocesses = true
    }

    /// `# @slashlight.network any` → ["network": "any"]
    static func scriptHeaders(_ source: String) -> [String: String] {
        var meta: [String: String] = [:]
        for raw in source.split(whereSeparator: \.isNewline).prefix(120) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("--") { line.removeFirst(2) } else if line.hasPrefix("#") { line.removeFirst() } else { continue }
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("@slashlight.") else { continue }
            let rest = line.dropFirst("@slashlight.".count)
            guard let space = rest.firstIndex(where: \.isWhitespace) else { continue }
            let key = String(rest[..<space])
            let value = rest[space...].trimmingCharacters(in: .whitespaces)
            meta[key] = meta[key].map { $0 + " " + value } ?? value
        }
        return meta
    }

    /// One line per permission, riskiest first, in the words the permission screen will use.
    var summary: [String] {
        var lines: [String] = []
        switch network {
        case .any: lines.append("Connect to any website or server")
        case .hosts(let h): lines.append("Connect to " + h.joined(separator: ", "))
        case .none: break
        }
        if defaultSearch { lines.append("See everything you type in the search bar") }
        if subprocesses { lines.append("Run other programs on your Mac") }
        if open { lines.append("Open apps, files and websites") }
        let tilde = { (u: URL) in u.path.replacingOccurrences(of: Self.home.path, with: "~") }
        if !write.isEmpty { lines.append("Change files in " + write.map(tilde).joined(separator: ", ")) }
        if !read.isEmpty { lines.append("Read files in " + read.map(tilde).joined(separator: ", ")) }
        if background { lines.append("Keep running when Slashlight is closed") }
        return lines
    }
}
