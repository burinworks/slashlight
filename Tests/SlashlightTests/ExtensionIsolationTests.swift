import Darwin
import Foundation
import Testing
@testable import Slashlight

/// What a malicious extension would try first: borrow Slashlight's privacy grants, read tokens from the
/// environment, or read files Slashlight has open. Each test starts a real child process the way the host does.
@Suite("Extension isolation")
struct ExtensionIsolationTests {
    private let here = URL(fileURLWithPath: NSTemporaryDirectory())

    private func run(_ path: String, _ args: [String]) throws -> String {
        let p = try ExtensionProcess(executable: URL(fileURLWithPath: path), arguments: args, directory: here,
                                     extensionID: "evil", sandbox: nil, pipeStdin: false)
        let out = p.stdout?.readDataToEndOfFile() ?? Data()
        _ = p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    @Test func childIsResponsibleForItself() throws {
        // A plain child shares our responsible process, so it would use whatever the user granted Slashlight.
        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        plain.arguments = ["5"]
        try plain.run()
        defer { plain.terminate() }
        let ours = try #require(ExtensionProcess.responsiblePID(for: getpid()))
        #expect(ExtensionProcess.responsiblePID(for: plain.processIdentifier) == ours)

        // An extension is charged to itself: macOS asks the user before it can use Accessibility or Screen Recording.
        let ext = try ExtensionProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], directory: here,
                                       extensionID: "evil", sandbox: nil, pipeStdin: false)
        defer { ext.terminate() }
        #expect(ExtensionProcess.responsiblePID(for: ext.pid) == ext.pid)
        #expect(ExtensionProcess.responsiblePID(for: ext.pid) != ours)
    }

    @Test func environmentHasNoSecrets() throws {
        setenv("SLASHLIGHT_TEST_TOKEN", "ghp_should_not_leak", 1)
        defer { unsetenv("SLASHLIGHT_TEST_TOKEN") }
        let env = try run("/usr/bin/env", [])
        #expect(!env.contains("ghp_should_not_leak"))
        #expect(env.contains("SLASHLIGHT_EXTENSION_ID=evil"))
        #expect(env.contains("HOME="))
        let names = Set(env.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        let allowed: Set = ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME", "SHELL", "LC_ALL", "LC_CTYPE", "SLASHLIGHT_EXTENSION_ID", "PWD"]
        #expect(names.isSubset(of: allowed), "unexpected variables: \(names.subtracting(allowed))")
    }

    @Test func openFilesAreNotInherited() throws {
        // Open a few descriptors without close-on-exec, as a settings file or another extension's pipe might be.
        // High numbers, so they can't be confused with descriptors the child opens itself.
        let fds = (0..<4).map { i -> Int32 in
            let fd = open("/etc/hosts", O_RDONLY)
            defer { close(fd) }
            return dup2(fd, 200 + Int32(i))
        }
        defer { fds.forEach { close($0) } }
        let listed = try run("/bin/sh", ["-c", "ls /dev/fd"])
        let inherited = Set(listed.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        for fd in fds { #expect(!inherited.contains(fd), "fd \(fd) leaked into the extension") }
    }

    @Test func runsInItsOwnFolder() throws {
        let pwd = try run("/bin/pwd", ["-P"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = try #require(realpath(here.path, nil))
        defer { free(expected) }
        #expect(pwd == String(cString: expected))
    }

    @Test func terminateStopsWhatItStarted() throws {
        // The extension starts a grandchild and waits; stopping the extension must stop both.
        let p = try ExtensionProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo $!; wait"],
                                     directory: here, extensionID: "evil", sandbox: nil, pipeStdin: false)
        let line = p.stdout.flatMap { String(data: $0.availableData, encoding: .utf8) } ?? ""
        let grandchild = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        p.terminate()
        _ = p.waitUntilExit()
        usleep(200_000)
        #expect(kill(grandchild, 0) != 0, "the extension's child is still running")
    }
}
