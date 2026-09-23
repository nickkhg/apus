import Glibc
import Power

/// The supplies of this machine, as the kernel names them in
/// /sys/class/power_supply. Nothing on this system uses Foundation, so this
/// is the C library.
final class Supplies: PowerSource {
    static let folder = "/sys/class/power_supply"

    /// What runs the machine does not change while it runs, so the program
    /// is asked once.
    lazy var machine: MachineKind = MachineKind.from(detectVirt: output(of: "systemd-detect-virt"))

    func supplies() -> [(name: String, uevent: String)] {
        guard let folder = opendir(Supplies.folder) else { return [] }
        defer { closedir(folder) }
        var result: [(name: String, uevent: String)] = []
        while let item = readdir(folder) {
            let name = withUnsafeBytes(of: item.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard !name.hasPrefix("."), let text = read("\(Supplies.folder)/\(name)/uevent") else {
                continue
            }
            result.append((name, text))
        }
        return result
    }

    /// The text of a file of the kernel, or nil.
    private func read(_ path: String) -> String? {
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

    /// What a program prints, or nothing when it cannot run. The program
    /// gets the signals back at their defaults, as the compositor gives an
    /// app (see AppCatalog.resetSignals).
    private func output(of program: String) -> String {
        var pipes: [Int32] = [0, 0]
        guard pipe(&pipes) == 0 else { return "" }
        for fd in pipes { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipes[1], 1)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let words = [strdup(program), nil]
        defer { for word in words { free(word) } }
        var child: pid_t = 0
        let started = posix_spawnp(&child, program, &actions, &attributes, words, environ)
        close(pipes[1])
        defer { close(pipes[0]) }
        guard started == 0 else { return "" }
        var text: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Glibc.read(pipes[0], &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            text += buffer[0..<count]
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        return String(decoding: text, as: UTF8.self)
    }
}
