import Glibc

// The few things that Settings does to the machine directly: read a file,
// write one in a single step, and run a program of the system and hear what
// it said. Nothing on this system uses Foundation, so this is the C library.

enum Files {
    /// The text of a file, or nil when it cannot be read.
    static func read(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Glibc.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The first line of a file, without its end: what a file of the
    /// kernel holds.
    static func line(_ path: String) -> String? {
        read(path).map { String($0.prefix { $0 != "\n" }) }
    }

    /// Writes a file in one step: the text goes to a file beside it, which
    /// then takes its name. A reader sees the old file or the new one, and
    /// never half of one.
    static func write(_ path: String, _ text: String, mode: mode_t = 0o644) -> String? {
        let temporary = "\(path).settings-\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        guard fd >= 0 else { return failure("\(path) cannot be written") }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes {
                Glibc.write(fd, $0.baseAddress! + written, $0.count - written)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                let problem = failure("\(path) cannot be written")
                close(fd)
                unlink(temporary)
                return problem
            }
            written += count
        }
        fsync(fd)
        close(fd)
        guard rename(temporary, path) == 0 else {
            let problem = failure("\(path) cannot be replaced")
            unlink(temporary)
            return problem
        }
        return nil
    }

    /// A link, made in one step in the same way as `write`.
    static func link(_ path: String, to target: String) -> String? {
        let temporary = "\(path).settings-\(getpid())"
        unlink(temporary)
        guard symlink(target, temporary) == 0 else { return failure("\(path) cannot be linked") }
        guard rename(temporary, path) == 0 else {
            let problem = failure("\(path) cannot be replaced")
            unlink(temporary)
            return problem
        }
        return nil
    }

    /// Where a link points, or nil for a file that is not a link.
    static func target(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func exists(_ path: String) -> Bool {
        access(path, F_OK) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Makes a directory and the ones above it.
    static func makeDirectories(_ path: String) -> String? {
        var built = ""
        for part in path.split(separator: "/") {
            built += "/\(part)"
            if mkdir(built, 0o755) != 0, errno != EEXIST {
                return failure("\(built) cannot be made")
            }
        }
        return nil
    }

    static func remove(_ path: String) -> String? {
        unlink(path) == 0 || errno == ENOENT ? nil : failure("\(path) cannot be removed")
    }

    /// The names in a directory, in order. A directory that is not there
    /// is empty.
    static func names(in directory: String) -> [String] {
        guard let handle = opendir(directory) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let record = readdir(handle) {
            var entry = record.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// What went wrong, in the words of the C library.
    static func failure(_ what: String) -> String {
        "\(what): \(String(cString: strerror(errno)))"
    }
}

/// A program of the system, run to its end.
enum Command {
    struct Result {
        let status: Int32
        /// What it wrote, on either stream.
        let output: String

        var succeeded: Bool { status == 0 }

        /// The last line that it wrote, which is where a program of the
        /// system says why it failed.
        var reason: String {
            output.split(separator: "\n").last.map(String.init) ?? "status \(status)"
        }
    }

    /// Runs `arguments` and waits for it. `input` goes to its standard
    /// input. The program gets the environment of this one, and the signals
    /// back at their defaults, as the compositor gives an app (see
    /// AppCatalog.resetSignals).
    static func run(_ arguments: [String], input: String? = nil) -> Result {
        var output: [Int32] = [0, 0], feed: [Int32] = [0, 0]
        guard pipe(&output) == 0, pipe(&feed) == 0 else {
            return Result(status: -1, output: Files.failure("no pipe for \(arguments[0])"))
        }
        // No other program that this one starts gets these pipes. The child
        // gets its three ends through dup2, which keeps them open.
        for fd in output + feed { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, feed[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, output[1], 2)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let words = arguments.map { strdup($0) } + [nil]
        defer { for word in words { free(word) } }
        var child: pid_t = 0
        let started = posix_spawnp(&child, arguments[0], &actions, &attributes, words, environ)
        close(output[1])
        close(feed[0])
        guard started == 0 else {
            close(output[0])
            close(feed[1])
            return Result(status: -1, output: "\(arguments[0]) cannot be started: "
                + String(cString: strerror(started)))
        }

        if let input {
            var bytes = Array(input.utf8)
            _ = bytes.withUnsafeMutableBytes { Glibc.write(feed[1], $0.baseAddress, $0.count) }
            // What is typed as a password does not stay in memory.
            for index in bytes.indices { bytes[index] = 0 }
        }
        close(feed[1])

        var text: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Glibc.read(output[0], &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            text += buffer[0..<count]
        }
        close(output[0])

        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        // WEXITSTATUS, which Swift does not import.
        let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return Result(status: code, output: String(decoding: text, as: UTF8.self))
    }
}
