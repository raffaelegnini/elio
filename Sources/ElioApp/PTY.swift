import Darwin
import Foundation

/// A real terminal: the user's login shell on a pseudo-terminal, as in Terminal or PHPStorm.
/// Output arrives as raw bytes (escape sequences included) for xterm.js to render.
final class PTY: @unchecked Sendable {
    let id: String
    let cwd: String
    private(set) var pid: pid_t = 0
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "elio.pty")

    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(id: String = UUID().uuidString, cwd: String) {
        self.id = id
        self.cwd = cwd
    }

    /// Starts `command` (default: the login shell) in `cwd`.
    func start(cols: Int, rows: Int, command: [String]? = nil) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let argv = command ?? [shell, "-l"]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Elio"
        if env["LANG"] == nil { env["LANG"] = "it_IT.UTF-8" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")

        // Everything the child needs is prepared before fork: after it, only exec.
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cDir = strdup(cwd)
        let cPath = strdup(argv[0])
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cDir); free(cPath)
        }
        var size = winsize(ws_row: UInt16(max(rows, 2)), ws_col: UInt16(max(cols, 2)), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if child == 0 {
            _ = chdir(cDir)
            execve(cPath, cArgs, cEnv)
            _exit(127)
        }
        pid = child
        master = fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer[0..<n])
                DispatchQueue.main.async { self.onData?(data) }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.resume()
        reader = source

        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { self?.closed(code: code) }
        }
        exit.resume()
        exitSource = exit
    }

    func write(_ data: Data) {
        guard master >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(master, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(max(rows, 2)), ws_col: UInt16(max(cols, 2)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Ends the shell (and what runs in it).
    func kill() {
        guard pid > 0 else { return }
        Darwin.kill(-pid, SIGHUP)
        Darwin.kill(pid, SIGHUP)
    }

    private func closed(code: Int32) {
        reader?.cancel()
        reader = nil
        exitSource?.cancel()
        exitSource = nil
        if master >= 0 { close(master); master = -1 }
        pid = 0
        onExit?(code)
    }

    deinit { if pid > 0 { Darwin.kill(pid, SIGHUP) } }
}
