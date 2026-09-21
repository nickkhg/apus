import Darwin
import Foundation

/// What the guest writes, on its way to standard output.
///
/// The console of the guest goes straight to standard output, which the
/// expect tests read. This puts a pipe in front of it: every byte still
/// reaches standard output, in order and at once, and a reader also splits
/// the stream into lines for anything that wants to watch them.
///
/// The window reads the frame times of the compositor this way. Nothing
/// else in the tool sees the console, and nothing the reader does can hold
/// the guest up: the bytes go out before the line is looked at.
enum GuestConsole {
    private static let tap = Pipe()

    /// The end the guest writes to.
    static var guestOutput: FileHandle { tap.fileHandleForWriting }

    /// Called for each line the guest writes, on the reader's thread.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var watchers: [(String) -> Void] = []

    static func watch(_ watcher: @escaping (String) -> Void) {
        lock.withLock { watchers.append(watcher) }
    }

    static func start() {
        let thread = Thread { copy() }
        thread.stackSize = 1 << 19
        thread.start()
    }

    private static func copy() {
        let reader = tap.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8192)
        var line: [UInt8] = []

        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(reader, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }

            // Out first. A watcher that is slow must not slow the guest.
            forward(buffer, count)

            for index in 0..<count {
                let byte = buffer[index]
                if byte == 0x0A || byte == 0x0D {
                    if !line.isEmpty {
                        deliver(String(decoding: line, as: UTF8.self))
                        line.removeAll(keepingCapacity: true)
                    }
                } else if line.count < 1024 {
                    line.append(byte)
                }
            }
        }
    }

    private static func forward(_ buffer: [UInt8], _ count: Int) {
        var written = 0
        while written < count {
            let sent = buffer.withUnsafeBytes { raw in
                write(STDOUT_FILENO, raw.baseAddress!.advanced(by: written), count - written)
            }
            if sent <= 0 {
                if errno == EINTR { continue }
                return
            }
            written += sent
        }
    }

    private static func deliver(_ line: String) {
        let current = lock.withLock { watchers }
        for watcher in current { watcher(line) }
    }
}
