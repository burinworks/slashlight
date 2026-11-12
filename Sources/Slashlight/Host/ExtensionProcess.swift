import Darwin
import Foundation

/// Starts third-party code (external extensions, Raycast script commands) so that it cannot use what
/// the user granted Slashlight.
///
/// - **Own responsible process.** macOS charges a child's privacy access (Accessibility, Screen Recording,
///   Automation…) to the app that started it, so a plain `Process` would inherit Slashlight's grants.
///   `responsibility_spawnattrs_setdisclaim` makes the child responsible for itself: it has to ask macOS for each
///   permission in its own name. The exception is an extension granted ~/Documents, ~/Desktop or ~/Downloads, which
///   macOS only lets a responsible app into (`Sandbox.needsSlashlightsFolderAccess`); its sandbox profile blocks
///   Accessibility, the window server and screen capture instead.
/// - **Clean environment.** Only the variables in `environment(extensionID:)`; tokens in the user's shell
///   environment (`GITHUB_TOKEN`, `OPENAI_API_KEY`…) are not passed on.
/// - **Sandbox.** With a `Sandbox`, the program runs under `sandbox-exec` with a profile built from its
///   permissions, and gets its own `TMPDIR` and `SLASHLIGHT_DATA_DIR`.
final class ExtensionProcess: @unchecked Sendable {
    let pid: pid_t
    /// Nil when the caller passed its own descriptor for that stream.
    let stdin: FileHandle?
    let stdout: FileHandle?

    private let lock = NSLock()
    private var exitStatus: Int32?
    private var exitWaiters: [(Int32) -> Void] = []
    private var source: DispatchSourceProcess?

    struct LaunchError: LocalizedError {
        let errorDescription: String?
    }

    /// Variables an extension gets. `PATH` includes Homebrew, since apps launched from Finder get a minimal one.
    static func environment(extensionID: String, sandbox: Sandbox? = nil) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
            "SLASHLIGHT_EXTENSION_ID": extensionID,
        ]
        for key in ["USER", "LOGNAME", "SHELL", "LC_ALL", "LC_CTYPE"] { env[key] = parent[key] }
        if let sandbox {
            env["TMPDIR"] = sandbox.tempFolder.path + "/"
            env["SLASHLIGHT_DATA_DIR"] = sandbox.dataFolder.path
        }
        return env
    }

    /// - Parameters:
    ///   - pipeStdin: give the child a pipe on stdin (`stdin` handle); otherwise /dev/null.
    ///   - stdout: a descriptor to write to, or nil for a pipe (`stdout` handle).
    ///   - stderr: a descriptor for errors; nil means the same as stdout.
    ///   - sandbox: the rules to run under; nil only for Slashlight's own helpers and tests.
    init(executable: URL, arguments: [String], directory: URL, extensionID: String, sandbox: Sandbox?,
         pipeStdin: Bool, stdout outFD: Int32? = nil, stderr errFD: Int32? = nil) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        var inPipe: Pipe?
        if pipeStdin {
            let pipe = Pipe()
            inPipe = pipe
            posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForReading.fileDescriptor, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        var outPipe: Pipe?
        let out: Int32
        if let outFD { out = outFD } else {
            let pipe = Pipe()
            outPipe = pipe
            out = pipe.fileHandleForWriting.fileDescriptor
        }
        posix_spawn_file_actions_adddup2(&actions, out, 1)
        posix_spawn_file_actions_adddup2(&actions, errFD ?? out, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        // New process group, so terminate() also reaches anything the extension started.
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        // Close every other descriptor Slashlight has open (the settings file, other extensions' pipes).
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        // Default handlers and no blocked signals: ignored signals (SIGPIPE, SIGTERM in some hosts) survive exec,
        // and an extension that ignores SIGTERM could not be stopped.
        flags |= Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attrs, &all)
        posix_spawnattr_setsigmask(&attrs, &none)
        posix_spawnattr_setflags(&attrs, flags)
        posix_spawnattr_setpgroup(&attrs, 0)
        guard sandbox?.needsSlashlightsFolderAccess == true || Self.disclaim(&attrs) else {
            throw LaunchError(errorDescription: "This macOS can't start extensions separately from Slashlight's permissions")
        }

        var environment = Self.environment(extensionID: extensionID, sandbox: sandbox)
        // Shells trust PWD instead of walking up the tree, which the sandbox doesn't let them read.
        environment["PWD"] = directory.path
        let env = environment.map { "\($0.key)=\($0.value)" }
        var program = executable
        var argv = [executable.path] + arguments
        if let sandbox {
            sandbox.prepare()
            program = Sandbox.executable
            argv = [program.path, "-p", sandbox.profile, "--"] + argv
        }
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, program.path, &actions, &attrs, &cArgs, &cEnv)
        guard rc == 0 else {
            throw LaunchError(errorDescription: "Couldn't start \(executable.lastPathComponent): \(String(cString: strerror(rc)))")
        }
        pid = child
        // The child holds its own copies now; keep only our ends.
        try? inPipe?.fileHandleForReading.close()
        try? outPipe?.fileHandleForWriting.close()
        stdin = inPipe?.fileHandleForWriting
        stdout = outPipe?.fileHandleForReading

        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.reap() }
        self.source = source
        source.resume()
    }

    var isRunning: Bool { lock.withLock { exitStatus == nil } }

    /// Called once, on a background queue, with the exit status (128 + signal when killed).
    func onExit(_ handler: @escaping (Int32) -> Void) {
        lock.lock()
        if let status = exitStatus {
            lock.unlock()
            handler(status)
        } else {
            exitWaiters.append(handler)
            lock.unlock()
        }
    }

    func waitUntilExit() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        onExit { status = $0; done.signal() }
        done.wait()
        return status
    }

    func terminate() {
        guard isRunning else { return }
        kill(-pid, SIGTERM)
    }

    /// ⌃C for the whole process group.
    func interrupt() {
        guard isRunning else { return }
        kill(-pid, SIGINT)
    }

    private func reap() {
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return }
        let signal = raw & 0x7F
        let status = signal == 0 ? (raw >> 8) & 0xFF : 128 + signal
        lock.lock()
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        source?.cancel()
        waiters.forEach { $0(status) }
    }

    // MARK: Responsibility

    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t

    /// Private libSystem calls, looked up at run time. Terminal, iTerm2 and LLDB use the same ones.
    private static let symbols = dlopen(nil, RTLD_NOW)

    private static func disclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>) -> Bool {
        guard let sym = dlsym(symbols, "responsibility_spawnattrs_setdisclaim") else { return false }
        return unsafeBitCast(sym, to: Disclaim.self)(attrs, 1) == 0
    }

    /// The process macOS charges `pid`'s privacy access to. Used by tests.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let sym = dlsym(symbols, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFor.self)(pid)
    }
}
