import CLinux
import Glibc
import Wayland

// The clipboard of the machine that runs the VM.
//
// Wayland has no answer for this: a clipboard is between the apps of one
// display server, and the Mac is not one of them. So the compositor opens a
// socket to the VM itself and the two sides send each other text.
//
//     the guest                          the Mac
//     Clipboard.swift ── AF_VSOCK ──▶ apus-vm ──▶ NSPasteboard
//                     ◀──────────────         ◀──
//
// AF_VSOCK is the socket family of a virtual machine: no network, no
// addresses to configure, and the host is always CID 2. apus-vm listens on
// `port` with a VZVirtioSocketListener (vm/Sources/apus-vm/Clipboard.swift).
//
// A message is four bytes of length, most significant first, and then that
// many bytes of UTF-8. Nothing else goes over the socket, in either
// direction, so a message is always the whole of a clipboard.
//
// The socket is not there on real hardware, and it is not there while
// apus-vm is starting. Neither is a fault: the compositor tries again every
// few seconds, and the clipboard of the system works either way.

final class HostClipboard {
    /// The port that apus-vm listens on. It is of the range that is free for
    /// anything (over 1023), and nothing else in Apus uses it.
    static let port: UInt32 = 1024
    /// How long to wait before trying the socket again.
    private static let retrySeconds = 5
    /// The most that is carried, as in `Clipboard.limit`.
    private static let limit = 4 << 20

    /// Called with text that arrived from the Mac.
    var received: (String) -> Void = { _ in }

    private let loop: EventLoop
    private var fd: Int32 = -1
    private var watch: EventLoop.Watch?
    /// Looks at the socket every few seconds and opens it when it can.
    ///
    /// It is made once and then left alone. A timer of the loop owns a
    /// timerfd that cancelling does not close, so a timer made afresh for
    /// each try would leak one file descriptor every few seconds, and a
    /// compositor that runs out of them stops being able to do anything.
    private var retry: EventLoop.Watch?
    /// What has come in and is not yet a whole message.
    private var incoming: [UInt8] = []
    /// What is waiting to go out, when the socket was full.
    private var outgoing: [UInt8] = []
    private var sent = 0
    /// The last text that came from the Mac. It is not sent back: the two
    /// sides would then answer each other for ever.
    private var fromHost: String?

    init(loop: EventLoop) {
        self.loop = loop
        connect()
        retry = try? loop.onTimer(milliseconds: HostClipboard.retrySeconds * 1000) {
            [unowned self] in
            if fd < 0 { connect() }
        }
    }

    deinit {
        retry?.cancel()
        stop()
    }

    /// Puts text on the clipboard of the Mac.
    func send(_ text: String) {
        // Text that the Mac just sent is already on its clipboard.
        guard text != fromHost else { return }
        guard fd >= 0 else { return }
        let bytes = Array(text.utf8)
        guard bytes.count <= HostClipboard.limit else {
            log("clipboard: \(bytes.count) bytes is too much for the host")
            return
        }
        var message = [UInt8]()
        message.reserveCapacity(bytes.count + 4)
        for shift in stride(from: 24, through: 0, by: -8) {
            message.append(UInt8((UInt32(bytes.count) >> UInt32(shift)) & 0xFF))
        }
        message += bytes
        outgoing += message
        flush()
    }

    // MARK: - The socket

    private func connect() {
        guard fd < 0 else { return }
        let socket = Glibc.socket(apus_af_vsock,
                                  Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard socket >= 0 else { return }
        var address = apus_sockaddr_vm()
        address.svm_family = UInt16(apus_af_vsock)
        address.svm_cid = apus_vsock_host_cid
        address.svm_port = HostClipboard.port
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(socket, $0, socklen_t(MemoryLayout<apus_sockaddr_vm>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            // No VM, or apus-vm is not listening yet. Neither is a fault.
            debug("clipboard: no host on vsock port \(HostClipboard.port) "
                + "(\(String(cString: strerror(errno)))); trying again")
            return
        }
        let flags = fcntl(socket, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK) }
        fd = socket
        watch = loop.watch(fd: socket) { [unowned self] events in
            if events.readable { receiveStep() }
            if events.writable { flush() }
            if events.hangup { restart() }
        }
        log("CLIPBOARD-HOST connected on vsock port \(HostClipboard.port)")
    }

    /// The socket went away. The timer opens it again when the host is back.
    private func restart() {
        stop()
    }

    private func stop() {
        watch?.cancel()
        watch = nil
        if fd >= 0 { close(fd) }
        fd = -1
        incoming = []
        outgoing = []
        sent = 0
    }

    private func flush() {
        while sent < outgoing.count {
            let count = outgoing[sent...].withUnsafeBytes {
                Glibc.write(fd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                sent += count
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR {
                watch?.setWantsWritable(true)
                return
            }
            return restart()
        }
        outgoing = []
        sent = 0
        watch?.setWantsWritable(false)
    }

    private func receiveStep() {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = chunk.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                incoming.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            return restart()       // zero is the far end closing
        }
        takeMessages()
    }

    /// Takes every whole message out of what has arrived.
    private func takeMessages() {
        while incoming.count >= 4 {
            var length = 0
            for index in 0..<4 { length = length << 8 | Int(incoming[index]) }
            guard length <= HostClipboard.limit else {
                log("clipboard: the host sent \(length) bytes; closing the socket")
                return restart()
            }
            guard incoming.count >= 4 + length else { return }
            let text = String(decoding: incoming[4..<(4 + length)], as: UTF8.self)
            incoming.removeFirst(4 + length)
            fromHost = text
            received(text)
        }
    }
}
