import Darwin
import Foundation

/// The terminal that the tool runs in.
///
/// The guest console needs every key, and it draws its own echo, so the
/// terminal goes into raw mode while the machine runs. The keys do not go
/// straight to the guest: a thread copies them, so that one combination can
/// stop the machine. That combination is Ctrl-A X, as it was in QEMU.
enum Terminal {
    private static let pipe = Pipe()

    // The thread that copies the keys and the paths that stop the tool both
    // put the terminal back, so a lock guards the saved settings.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var saved = termios()
    nonisolated(unsafe) private static var isRaw = false

    /// Traces the copying of the keys, with MYDISTRO_VM_TRACE=1.
    private static let trace = ProcessInfo.processInfo.environment["MYDISTRO_VM_TRACE"] == "1"

    private static func note(_ message: String) {
        guard trace else { return }
        FileHandle.standardError.write(Data("[vm] \(message)\n".utf8))
    }

    /// The end of the pipe that the guest console reads.
    static var guestInput: FileHandle { pipe.fileHandleForReading }

    /// A handler that the escape combination calls.
    nonisolated(unsafe) static var onQuit: () -> Void = { exit(0) }

    private static let escape: UInt8 = 0x01   // Ctrl-A
    private static let quit: UInt8 = 0x78     // x

    static func start() {
        makeRaw()
        let thread = Thread { forward() }
        thread.stackSize = 1 << 19
        thread.start()
    }

    /// Copies stdin to the guest, and watches for Ctrl-A X.
    ///
    /// Ctrl-A Ctrl-A sends one Ctrl-A to the guest, so that programs that
    /// use Ctrl-A (readline moves to the start of the line) still get it.
    ///
    /// `poll` waits for a key. Reading stdin directly is not sufficient:
    /// stdin can be in non-blocking mode (expect gives the tool a pseudo
    /// terminal in that mode), and a plain `read` then answers EAGAIN
    /// immediately. Treating that as the end of the input stopped every key
    /// after the first line.
    private static func forward() {
        let writer = pipe.fileHandleForWriting
        var buffer = [UInt8](repeating: 0, count: 1024)
        var afterEscape = false
        var waiting = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)

        while true {
            let ready = poll(&waiting, 1, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                note("poll failed, errno \(errno)")
                return
            }
            if ready == 0 { continue }
            if waiting.revents & Int16(POLLIN) == 0 {
                if waiting.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    note("stdin closed")
                    return
                }
                continue
            }

            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                note("read failed, errno \(errno)")
                return
            }
            if count == 0 { note("stdin gave no more keys"); return }

            var pass = [UInt8]()
            pass.reserveCapacity(count)
            for byte in buffer[0..<count] {
                if afterEscape {
                    afterEscape = false
                    switch byte {
                    case quit:
                        restore()
                        onQuit()
                        return
                    case escape:
                        pass.append(escape)
                    default:
                        pass.append(escape)
                        pass.append(byte)
                    }
                } else if byte == escape {
                    afterEscape = true
                } else {
                    pass.append(byte)
                }
            }
            if !pass.isEmpty {
                do { try writer.write(contentsOf: pass) } catch {
                    note("cannot pass the keys: \(error)")
                    return
                }
            }
        }
    }

    private static func makeRaw() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        lock.withLock {
            tcgetattr(STDIN_FILENO, &saved)
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            isRaw = true
        }
    }

    /// Puts the terminal back as it was. Safe to call more than one time,
    /// and from any thread.
    static func restore() {
        lock.withLock {
            guard isRaw else { return }
            isRaw = false
            tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        }
    }
}
