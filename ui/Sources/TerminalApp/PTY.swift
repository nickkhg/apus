import CPTY
import Glibc

/// A pseudo terminal with a program in it.
///
/// The terminal keeps the first end (the "master"): what it writes there is
/// what the program reads from its keyboard, and what it reads there is what
/// the program prints. The program gets the other end as its terminal.
final class PTY {
    /// The end that the terminal reads and writes.
    let fd: Int32
    /// The process of the program.
    private(set) var child: pid_t = -1

    /// Opens a terminal and starts `command` in it. `arguments` does not
    /// include the name of the program.
    init?(command: String, arguments: [String] = [], columns: Int, rows: Int) {
        var name = [CChar](repeating: 0, count: 128)
        fd = mydistro_pty_open(&name, Int32(name.count))
        guard fd >= 0 else {
            report("can't open a pseudo terminal: \(String(cString: strerror(errno)))")
            return nil
        }
        setSize(columns: columns, rows: rows, width: 0, height: 0)

        // The program starts in a session of its own. It opens the other end
        // of the terminal as its input, and that end becomes its controlling
        // terminal, because the process is the leader of the new session.
        //
        // posix_spawn reads the name of that end after this call, so the
        // name gets memory of its own: a Swift array gives a pointer for one
        // call only.
        guard let otherEnd = strdup(String(cString: name)) else {
            close(fd)
            return nil
        }
        defer { free(otherEnd) }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, otherEnd, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, fd)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(PTY.spawnSetSID))

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(command)]
        argv += arguments.map { strdup($0) }
        argv.append(nil)
        var envp = PTY.environment().map { strdup($0) }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let result = posix_spawn(&child, command, &actions, &attributes, argv, envp)
        guard result == 0 else {
            report("can't start \(command): \(String(cString: strerror(result)))")
            close(fd)
            return nil
        }
    }

    deinit {
        if child > 0 { kill(child, SIGHUP) }
        close(fd)
    }

    /// POSIX_SPAWN_SETSID of glibc. The C headers give it to the
    /// preprocessor only, so Swift does not see it.
    private static let spawnSetSID: Int32 = 0x80

    /// The environment of the program: ours, with TERM for this terminal.
    private static func environment() -> [String] {
        var result = ["TERM=xterm-256color"]
        var entry = environ
        while let text = entry.pointee {
            let line = String(cString: text)
            if !line.hasPrefix("TERM=") { result.append(line) }
            entry += 1
        }
        return result
    }

    /// Tells the program how large the terminal is. A program that cares
    /// (the shell, an editor) also gets SIGWINCH from the kernel.
    func setSize(columns: Int, rows: Int, width: Int, height: Int) {
        _ = mydistro_pty_set_size(fd, Int32(columns), Int32(rows), Int32(width), Int32(height))
    }

    /// What the program printed. Nil means that the program ended.
    func read() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = buffer.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
        if count > 0 { return Array(buffer[0..<count]) }
        // EAGAIN only means "nothing now".
        if count < 0, errno == EAGAIN || errno == EINTR { return [] }
        return nil
    }

    /// Sends keys to the program.
    func write(_ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes {
                Glibc.write(fd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                sent += count
            } else if !(count < 0 && errno == EINTR) {
                return
            }
        }
    }

}
