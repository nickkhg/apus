import AppKit
import Foundation
import Virtualization

// The clipboard of the Mac and the clipboard of the guest, kept the same.
//
// A clipboard is between the apps of one display server, and the Mac is not
// one of the guest's apps. So the two talk over a socket of the virtual
// machine — AF_VSOCK, which needs no network and no addresses — and send
// each other the text as it changes.
//
//     the guest                             the Mac
//     apus-compositor ── AF_VSOCK ──▶ this ──▶ NSPasteboard
//                     ◀──────────────      ◀──
//
// The guest connects, because it is the side that knows when it is ready.
// This listens on `port` and holds the one connection.
//
// A message is four bytes of length, most significant first, and then that
// many bytes of UTF-8. See ui/Sources/Compositor/HostClipboard.swift.

/// Carries the clipboard between the Mac and the guest.
@MainActor
final class Clipboard: NSObject, VZVirtioSocketListenerDelegate {
    /// The port that the compositor of the guest connects to.
    static let port: UInt32 = 1024
    /// How often the pasteboard of the Mac is looked at. AppKit has no
    /// notification for a change, so it is read; `changeCount` makes that
    /// cheap, because nothing else is touched when it has not changed.
    private static let pollSeconds = 0.4
    /// The most that is carried, as in the compositor.
    private static let limit = 4 << 20

    /// The socket that the guest opened, while it is open.
    private var connection: VZVirtioSocketConnection?
    private var reader: DispatchSourceRead?
    /// Waits for room in the socket when a message did not fit at once.
    private var writer: DispatchSourceWrite?
    /// What is waiting to go to the guest.
    private var outgoing = Data()
    /// What has come in and is not yet a whole message.
    private var incoming = Data()
    /// The state of the pasteboard as it was last looked at.
    private var pasteboardCount = NSPasteboard.general.changeCount
    /// The last text that went either way. Neither side is told what it
    /// just said, or the two would answer each other for ever.
    private var lastText: String?
    private var timer: DispatchSourceTimer?

    /// Listens for the guest, and watches the pasteboard of the Mac.
    func attach(to machine: VZVirtualMachine) {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
            log("no vsock device: the clipboard is not shared with the guest")
            return
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        device.setSocketListener(listener, forPort: Clipboard.port)
        startWatchingThePasteboard()
        log("sharing the clipboard with the guest on vsock port \(Clipboard.port)")
    }

    // MARK: - The guest

    /// The framework calls this on a queue of its own, and neither the
    /// connection nor this object can cross a thread on its own. The two go
    /// to the main queue together, where everything else here runs.
    nonisolated func listener(_ listener: VZVirtioSocketListener,
                              shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                              from socketDevice: VZVirtioSocketDevice) -> Bool {
        nonisolated(unsafe) let opened = connection
        nonisolated(unsafe) let clipboard = self
        DispatchQueue.main.async {
            MainActor.assumeIsolated { clipboard.accept(opened) }
        }
        return true
    }

    private func accept(_ connection: VZVirtioSocketConnection) {
        close()
        let fd = connection.fileDescriptor
        // Everything here runs on the main queue, which is also the queue
        // that draws the window of the guest and delivers its keys and its
        // pointer. So nothing here may wait: a read or a write that blocked
        // would stop the whole machine being drawn or answering, which looks
        // exactly like a guest that has hung.
        //
        // The framework does not say whether the socket it gives back can
        // wait, so it is told here that it cannot.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            log("cannot set the clipboard socket to not wait; not sharing the clipboard")
            connection.close()
            return
        }
        self.connection = connection
        incoming = Data()
        outgoing = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readStep(fd) }
        }
        source.resume()
        reader = source
        log("the guest connected to the clipboard")
        // The guest starts with whatever is on the pasteboard of the Mac.
        pasteboardCount = -1
        checkThePasteboard()
    }

    private func close() {
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        outgoing = Data()
        connection?.close()
        connection = nil
    }

    private func readStep(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                incoming.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            // Zero is the guest closing, and an error ends it too.
            close()
            return
        }
        takeMessages()
    }

    /// Takes every whole message out of what has arrived.
    private func takeMessages() {
        while incoming.count >= 4 {
            var length = 0
            for index in 0..<4 { length = length << 8 | Int(incoming[incoming.startIndex + index]) }
            guard length <= Clipboard.limit else {
                log("the guest sent \(length) bytes of clipboard; closing the socket")
                return close()
            }
            guard incoming.count >= 4 + length else { return }
            let start = incoming.startIndex + 4
            let text = String(decoding: incoming[start..<(start + length)], as: UTF8.self)
            incoming.removeFirst(4 + length)
            put(text)
        }
    }

    // MARK: - The Mac

    private func startWatchingThePasteboard() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Clipboard.pollSeconds,
                       repeating: Clipboard.pollSeconds)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkThePasteboard() }
        }
        timer.resume()
        self.timer = timer
    }

    private func checkThePasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardCount else { return }
        pasteboardCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text != lastText else { return }
        lastText = text
        send(text)
    }

    /// Puts text that came from the guest on the pasteboard of the Mac.
    private func put(_ text: String) {
        guard text != lastText else { return }
        lastText = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Writing moved the count on; that change is ours, not a new one.
        pasteboardCount = pasteboard.changeCount
    }

    /// Sends text to the guest.
    private func send(_ text: String) {
        guard let connection else { return }
        let bytes = Array(text.utf8)
        guard bytes.count <= Clipboard.limit else {
            log("\(bytes.count) bytes is too much clipboard for the guest")
            return
        }
        var message = Data()
        for shift in stride(from: 24, through: 0, by: -8) {
            message.append(UInt8((UInt32(bytes.count) >> UInt32(shift)) & 0xFF))
        }
        message.append(contentsOf: bytes)
        outgoing.append(message)
        flush()
    }

    /// Writes what is waiting, as far as the socket will take it now.
    ///
    /// The socket takes tens of kilobytes at a time and a clipboard is
    /// usually a line or two, so this almost always finishes at once. What
    /// does not fit waits for the socket to have room, and the main queue
    /// goes back to drawing the guest in the meantime.
    private func flush() {
        guard let connection, !outgoing.isEmpty else { return }
        let fd = connection.fileDescriptor
        var sent = 0
        var isFull = false
        outgoing.withUnsafeBytes { buffer in
            while sent < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if count > 0 {
                    sent += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                isFull = count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
                break
            }
        }
        outgoing.removeFirst(sent)
        guard !outgoing.isEmpty else {
            writer?.cancel()
            writer = nil
            return
        }
        // Something is left. Either the socket is full, and a write source
        // says when it has room again, or the guest has gone and there is
        // nothing to wait for.
        guard isFull else {
            log("the guest stopped reading the clipboard; closing the socket")
            return close()
        }
        guard writer == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        source.resume()
        writer = source
    }
}
