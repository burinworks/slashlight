import AppKit
import Darwin
import Foundation
import Testing
@testable import Slashlight

/// Each test runs a real program under the sandbox the host would build and checks that what a malicious
/// extension tries first fails, and that what its permissions grant still works.
@Suite("Extension sandbox", .serialized)
struct SandboxTests {
    /// A folder in the home folder, like ~/Documents, that the extension wasn't given.
    private let homeFolder: URL
    private let secret: URL

    init() throws {
        homeFolder = ExtensionPermissions.home.appendingPathComponent(".slashlight-sandbox-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: homeFolder, withIntermediateDirectories: true)
        secret = homeFolder.appendingPathComponent("secret.txt")
        try "top secret".write(to: secret, atomically: true, encoding: .utf8)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: homeFolder) }

    private func run(_ permissions: ExtensionPermissions = ExtensionPermissions(), _ path: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let folders = Sandbox.folders(extensionID: "sandbox-test")
        let sandbox = Sandbox(permissions: permissions, dataFolder: folders.data, tempFolder: folders.temp)
        let p = try ExtensionProcess(executable: URL(fileURLWithPath: path), arguments: args,
                                     directory: URL(fileURLWithPath: "/"), extensionID: "sandbox-test",
                                     sandbox: sandbox, pipeStdin: false)
        let out = p.stdout?.readDataToEndOfFile() ?? Data()
        return (p.waitUntilExit(), String(decoding: out, as: UTF8.self))
    }

    private func sh(_ permissions: ExtensionPermissions = ExtensionPermissions(), _ script: String) throws -> (status: Int32, output: String) {
        var p = permissions
        p.subprocesses = true
        return try run(p, "/bin/sh", ["-c", script])
    }

    // MARK: Files

    @Test func cantReadTheHomeFolder() throws {
        defer { cleanUp() }
        let r = try run(.init(), "/bin/cat", [secret.path])
        #expect(r.status != 0)
        #expect(!r.output.contains("top secret"))
        #expect(try run(.init(), "/bin/ls", [NSHomeDirectory()]).status != 0)
    }

    @Test func readsOnlyWhatItWasGiven() throws {
        defer { cleanUp() }
        var p = ExtensionPermissions()
        p.read = [homeFolder]
        #expect(try run(p, "/bin/cat", [secret.path]).output == "top secret")
        let w = try sh(p, "echo changed > '\(secret.path)'")
        #expect(w.status != 0)
        #expect(try String(contentsOf: secret, encoding: .utf8) == "top secret")
    }

    @Test func writesWhereItWasGiven() throws {
        defer { cleanUp() }
        var p = ExtensionPermissions()
        p.write = [homeFolder]
        let target = homeFolder.appendingPathComponent("new.txt")
        #expect(try sh(p, "echo ok > '\(target.path)'").status == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "ok\n")
    }

    @Test func cantChangeProgramsOutsideHome() throws {
        // /usr/local and /opt/homebrew belong to the user, so only the sandbox stops an extension replacing `git`.
        let r = try sh(.init(), "echo x > /usr/local/.slashlight-sandbox-test || echo x > /opt/homebrew/.slashlight-sandbox-test; echo $?")
        #expect(!FileManager.default.fileExists(atPath: "/usr/local/.slashlight-sandbox-test"))
        #expect(!FileManager.default.fileExists(atPath: "/opt/homebrew/.slashlight-sandbox-test"))
        _ = r
    }

    @Test func neverReachesSecretsEvenInsideAGrantedFolder() throws {
        defer { cleanUp() }
        // Granting ~/.config must not grant ~/.config/gh: the never-allowed rule has to come later and win.
        var p = ExtensionPermissions()
        p.read = [ExtensionPermissions.home.appendingPathComponent(".config")]
        let profile = Sandbox(permissions: p, dataFolder: homeFolder, tempFolder: homeFolder).profile
        let never = try #require(profile.range(of: ".config/gh"))
        let grant = try #require(profile.range(of: "(allow file-read-data (subpath"))
        #expect(grant.lowerBound < never.lowerBound, "the never-allowed rule must come after granted folders")
    }

    @Test func hasItsOwnDataAndTempFolders() throws {
        let r = try sh(.init(), "echo ok > \"$TMPDIR/t\" && cat \"$TMPDIR/t\" && echo ok > \"$SLASHLIGHT_DATA_DIR/d\" && cat \"$SLASHLIGHT_DATA_DIR/d\"")
        #expect(r.output == "ok\nok\n", "\(r.output)")
        // Slashlight's own temp folder is someone else's.
        let ours = NSTemporaryDirectory() + "slashlight-sandbox-\(UUID().uuidString).txt"
        try "ours".write(toFile: ours, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: ours) }
        #expect(try run(.init(), "/bin/cat", [ours]).status != 0)
    }

    @Test func cantReadSlashlightData() throws {
        let settings = Paths.support.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settings.path) else { return }
        #expect(try run(.init(), "/bin/cat", [settings.path]).status != 0)
    }

    // MARK: Network

    /// A listening socket on 127.0.0.1, so the test needs no internet.
    private func listener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                guard bind(fd, sa, len) == 0, listen(fd, 4) == 0, getsockname(fd, sa, &len) == 0 else {
                    throw ExtensionPermissions.Invalid("couldn't listen")
                }
            }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    @Test func noNetworkUnlessGranted() throws {
        let (fd, port) = try listener()
        defer { close(fd) }
        let check = "/usr/bin/nc -z -G 2 127.0.0.1 \(port)"
        #expect(try sh(.init(), check).status != 0)
        var p = ExtensionPermissions()
        p.network = .any
        #expect(try sh(p, check).status == 0)
    }

    // MARK: Programs and services

    @Test func startsNoProgramsUnlessGranted() throws {
        // "; true" so sh has to fork: a lone last command is exec()d in place.
        let denied = try run(.init(), "/bin/sh", ["-c", "/bin/echo child; true"])
        #expect(!denied.output.contains("child\n"))
        #expect(try sh(.init(), "/bin/echo child").output == "child\n")
    }

    @Test func cantReadTheClipboard() throws {
        // The font pasteboard, so the test leaves what you copied alone.
        let board = NSPasteboard(name: .font)
        board.clearContents()
        board.setString("clipboard-secret", forType: .string)
        defer { board.clearContents() }
        let r = try sh(.init(), "/usr/bin/pbpaste -pboard font")
        #expect(!r.output.contains("clipboard-secret"))
    }

    @Test func cantOpenAppsUnlessGranted() throws {
        // An app opened this way would run outside the sandbox.
        let r = try sh(.init(), "/usr/bin/open -g -j /System/Applications/Calculator.app")
        #expect(r.status != 0)
        if r.status == 0 { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").forEach { $0.terminate() } }
    }

    @Test func profileBlocksKeychainAppleEventsAndLaunchd() {
        let profile = Sandbox(permissions: .init(), dataFolder: homeFolder, tempFolder: homeFolder).profile
        for rule in ["com.apple.SecurityServer", "com.apple.pasteboard.1", "(deny appleevent-send)", "(deny job-creation)", "(deny lsopen)"] {
            #expect(profile.contains(rule), "missing \(rule)")
        }
        cleanUp()
    }

    @Test func privacyFoldersRunUnderSlashlightsResponsibility() throws {
        var p = ExtensionPermissions()
        #expect(!Sandbox(permissions: p, dataFolder: homeFolder, tempFolder: homeFolder).needsSlashlightsFolderAccess)
        p.write = [try ExtensionPermissions.folder("~/Documents/repos/project")]
        #expect(Sandbox(permissions: p, dataFolder: homeFolder, tempFolder: homeFolder).needsSlashlightsFolderAccess)
        p.write = [try ExtensionPermissions.folder("~/DocumentsArchive")]
        #expect(!Sandbox(permissions: p, dataFolder: homeFolder, tempFolder: homeFolder).needsSlashlightsFolderAccess)
        cleanUp()
    }

    /// Runs under our responsibility (granted ~/Documents), so only the profile stands between it and whatever
    /// Accessibility and Screen Recording access the test runner has. Skipped where python3 isn't installed.
    @Test func cantUseSlashlightsAccessibilityOrScreen() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        else { return }
        defer { cleanUp() }
        var p = ExtensionPermissions()
        p.read = [ExtensionPermissions.home.appendingPathComponent("Documents")]
        p.subprocesses = true
        let probe = """
        import ctypes, ctypes.util, os, sys
        AS = ctypes.cdll.LoadLibrary(ctypes.util.find_library("ApplicationServices"))
        CG = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
        CF = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
        AS.AXUIElementCreateApplication.restype = ctypes.c_void_p
        AS.AXUIElementCreateApplication.argtypes = [ctypes.c_int]
        AS.AXUIElementCopyAttributeValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        CF.CFStringCreateWithCString.restype = ctypes.c_void_p
        CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        out = ctypes.c_void_p()
        err = AS.AXUIElementCopyAttributeValue(AS.AXUIElementCreateApplication(int(sys.argv[1])),
                                               CF.CFStringCreateWithCString(None, b"AXRole", 0x08000100), ctypes.byref(out))
        CG.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
        CG.CGDisplayCreateImage.restype = ctypes.c_void_p
        CG.CGMainDisplayID.restype = ctypes.c_uint32
        print("ax", err == 0, "windows", bool(CG.CGWindowListCopyWindowInfo(1, 0)),
              "image", bool(CG.CGDisplayCreateImage(CG.CGMainDisplayID())))
        """
        let folders = Sandbox.folders(extensionID: "sandbox-test")
        let sandbox = Sandbox(permissions: p, dataFolder: folders.data, tempFolder: folders.temp)
        #expect(sandbox.needsSlashlightsFolderAccess)
        let proc = try ExtensionProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-c", probe, "\(finder)"],
                                        directory: URL(fileURLWithPath: "/"), extensionID: "sandbox-test",
                                        sandbox: sandbox, pipeStdin: false)
        let out = String(decoding: proc.stdout?.readDataToEndOfFile() ?? Data(), as: UTF8.self)
        _ = proc.waitUntilExit()
        #expect(out.contains("ax False windows False image False"), "\(out)")
        // Without the sandbox the same probe reaches Finder's windows whenever the test runner may.
        if ProcessInfo.processInfo.environment["SLASHLIGHT_PROBE_CONTROL"] != nil {
            let plain = Process()
            plain.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            plain.arguments = ["-I", "-c", probe, "\(finder)"]
            let pipe = Pipe()
            plain.standardOutput = pipe
            try plain.run()
            plain.waitUntilExit()
            print("PROBE control:", String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    // MARK: Manifests and headers

    @Test func foldersThatCantBeGranted() throws {
        for bad in ["~", "~/", "~/.ssh", "~/.ssh/keys", "~/Library", "~/Library/Keychains", "~/Doc*", "/etc", "~/Documents/../.ssh", "Documents"] {
            #expect(throws: ExtensionPermissions.Invalid.self, "\(bad) should be rejected") { try ExtensionPermissions.folder(bad) }
        }
        #expect(try ExtensionPermissions.folder("~/Documents").path == NSHomeDirectory() + "/Documents")
        cleanUp()
    }

    @Test func scriptHeaders() throws {
        let source = """
        #!/bin/bash
        # @raycast.title Gist
        # @slashlight.network api.github.com
        # @slashlight.files.read ~/Documents ~/Desktop
        # @slashlight.open true
        """
        let p = try ExtensionPermissions(scriptHeaders: ExtensionPermissions.scriptHeaders(source))
        #expect(p.network == .hosts(["api.github.com"]))
        #expect(p.read.map(\.lastPathComponent) == ["Documents", "Desktop"])
        #expect(p.open && p.subprocesses && !p.defaultSearch)
        let bare = try ExtensionPermissions(scriptHeaders: [:])
        #expect(bare.network == .none && bare.read.isEmpty && bare.subprocesses && !bare.open)
        #expect(throws: ExtensionPermissions.Invalid.self) {
            try ExtensionPermissions(scriptHeaders: ["files.read": "~/.ssh"])
        }
        cleanUp()
    }

    @MainActor @Test func manifestsMustAgreeWithTheirPermissions() throws {
        func manifest(_ json: String) throws -> ExternalExtension.FileManifest {
            try JSONDecoder().decode(ExternalExtension.FileManifest.self, from: Data(json.utf8))
        }
        let dir = URL(fileURLWithPath: "/tmp")
        let searchy = try manifest(#"{"id":"x","title":"X","triggers":["default"],"exec":["./x"]}"#)
        #expect(throws: (any Error).self) { try ExternalExtension(file: searchy, directory: dir) }
        let allowed = try manifest(#"{"id":"x","title":"X","triggers":["default"],"exec":["./x"],"permissions":{"defaultSearch":true,"network":"any"}}"#)
        let ext = try ExternalExtension(file: allowed, directory: dir)
        #expect(ext.granted.network == .any && ext.granted.defaultSearch)
        let clash = try manifest(#"{"id":"clipboard","title":"X","triggers":[],"exec":["./x"]}"#)
        #expect(throws: (any Error).self) { try ExternalExtension(file: clash, directory: dir, reservedIDs: ["clipboard"]) }
        let sneaky = try manifest(#"{"id":"../settings","title":"X","triggers":[],"exec":["./x"]}"#)
        #expect(throws: (any Error).self) { try ExternalExtension(file: sneaky, directory: dir) }
        let ssh = try manifest(#"{"id":"x","title":"X","triggers":[],"exec":["./x"],"permissions":{"files":{"read":["~/.ssh"]}}}"#)
        #expect(throws: (any Error).self) { try ExternalExtension(file: ssh, directory: dir) }
        cleanUp()
    }
}
