import DRMKit
import Glibc
import Wayland

/// Writes the pixels that are on screen to a file, when something asks over
/// a Unix socket. APUS_SCREENSHOT_SOCKET turns it on; without that
/// variable the compositor has no such socket.
///
/// The tests need this because Virtualization, unlike QEMU, cannot make a
/// picture of the screen of a guest. The compositor already has the pixels:
/// it holds the buffer that it gave to the display.
///
/// A client sends one line and reads one line back. The line is a file
/// name, and the answer is `ok <width> <height>` or `error <reason>`; the
/// file is then a binary PPM (P6). The line `size` gives the same answer
/// and writes nothing, which is how a client learns the size of the screen.
final class Screenshot {
    private let fd: Int32
    private var watch: EventLoop.Watch?

    /// The screen that makes the picture and says how big it is.
    private let screen: any Screen

    init?(path: String, loop: EventLoop, screen: any Screen) {
        self.screen = screen
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }

        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= limit else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8.enumerated().forEach { raw[$0.offset] = $0.element }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            log("screenshot: cannot listen on \(path) (errno \(errno))")
            close(fd)
            return nil
        }
        watch = loop.watch(fd: fd) { [unowned self] in accept() }
        log("screenshot: listening on \(path)")
    }

    deinit {
        watch?.cancel()
        close(fd)
    }

    private func accept() {
        let client = Glibc.accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        var text = Array(buffer[0..<count])
        while let last = text.last, last == 0x0A || last == 0x0D || last == 0x20 {
            text.removeLast()
        }
        let request = String(decoding: text, as: UTF8.self)
        guard !request.isEmpty else { return }

        let size = "ok \(screen.width) \(screen.height)\n"
        var answer = size
        if request != "size" {
            do { try screen.writePicture(to: request) } catch { answer = "error \(error)\n" }
        }
        _ = answer.withCString { Glibc.write(client, $0, strlen($0)) }
    }

}
