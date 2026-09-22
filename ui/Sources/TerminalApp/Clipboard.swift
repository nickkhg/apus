import CWaylandClient
import Glibc

// Copying and pasting, as a Wayland app does it.
//
// The app that copies keeps the text and offers it to the compositor
// (wl_data_source). The app that pastes is told what is on offer
// (wl_data_offer) and asks for one of the types on a pipe. The compositor
// carries the offer between the two, and the text itself goes down the pipe.
//
// The compositor of Apus also keeps the clipboard of the Mac the same as
// this one, so a copy here is a copy there. See docs/clipboard.md.

/// The clipboard, from the side of the terminal.
final class Clipboard {
    /// The type that the text is offered as. The compositor offers the
    /// older names for the same thing as well.
    static let textType = "text/plain;charset=utf-8"
    /// The most that is taken from a paste. A person pastes a command, not
    /// a file, and a pipe that never ends must not fill the window.
    static let limit = 4 << 20
    /// How long either side of a transfer waits for the other.
    static let pasteTimeoutMilliseconds: Int32 = 1000

    private var manager: OpaquePointer?
    private var device: OpaquePointer?
    /// What this terminal last copied, while it still holds the clipboard.
    private var copied = ""
    private var source: OpaquePointer?
    /// What another app has on the clipboard, when it has text on it.
    private var offer: OpaquePointer?
    private var offerHasText = false
    /// The serial of the last key or button. set_selection needs one.
    var lastSerial: UInt32 = 0

    /// True once the compositor has a clipboard to talk about.
    var isReady: Bool { device != nil }

    // MARK: - Setting up

    func bind(registry: OpaquePointer?, name: UInt32) {
        manager = OpaquePointer(wl_registry_bind(
            registry, name, wl_data_device_manager_interface_ptr(), 3))
    }

    func start(seat: OpaquePointer?, data: UnsafeMutableRawPointer?) {
        guard let manager, let seat, device == nil else { return }
        device = wl_data_device_manager_get_data_device(manager, seat)
        wl_data_device_add_listener(device, Clipboard.deviceListener, data)
    }

    // MARK: - Copying

    /// Puts `text` on the clipboard of the system.
    func copy(_ text: String, data: UnsafeMutableRawPointer?) {
        guard let manager, let device, !text.isEmpty else { return }
        copied = text
        if let source { wl_data_source_destroy(source) }
        source = wl_data_device_manager_create_data_source(manager)
        wl_data_source_add_listener(source, Clipboard.sourceListener, data)
        // The same text under every name that a program might ask for.
        for type in [Clipboard.textType, "text/plain", "UTF8_STRING", "STRING", "TEXT"] {
            wl_data_source_offer(source, type)
        }
        wl_data_device_set_selection(device, source, lastSerial)
    }

    /// Writes what was copied into the pipe that the compositor gave us.
    ///
    /// This runs inside the dispatch of a Wayland event, so it must end. A
    /// pipe holds 64 kB and a selection is usually far less, but the far end
    /// could stop reading, and the terminal must not stop drawing with it.
    /// So the wait for room has a limit, and a selection that cannot be
    /// handed over is given up rather than waited on.
    fileprivate func write(to fd: Int32) {
        let bytes = Array(copied.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                sent += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { break }
            var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&waiting, 1, Clipboard.pasteTimeoutMilliseconds) > 0 else { break }
        }
        close(fd)
    }

    fileprivate func gaveUpTheClipboard(_ source: OpaquePointer?) {
        guard source == self.source else { return }
        wl_data_source_destroy(source)
        self.source = nil
        copied = ""
    }

    // MARK: - Pasting

    fileprivate func offered(_ offer: OpaquePointer?) {
        // A new offer replaces the old one, whether or not it becomes the
        // selection: the compositor destroys the one it replaces.
        if let old = self.offer, old != offer { wl_data_offer_destroy(old) }
        self.offer = offer
        offerHasText = false
    }

    fileprivate func offerHasType(_ type: String) {
        if type == Clipboard.textType || type == "text/plain" { offerHasText = true }
    }

    fileprivate func selectionChanged(to offer: OpaquePointer?) {
        if offer == nil, let old = self.offer {
            wl_data_offer_destroy(old)
            self.offer = nil
            offerHasText = false
        }
    }

    /// The text on the clipboard, or nothing when there is none.
    ///
    /// The app that holds the clipboard writes it down a pipe, which takes a
    /// turn of its event loop. The terminal waits here rather than taking
    /// the paste apart across frames: a person who pressed paste is waiting
    /// anyway, and the wait has an end.
    func paste(display: OpaquePointer?) -> String? {
        guard let offer, offerHasText else { return nil }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        let (reading, writing) = (ends[0], ends[1])
        wl_data_offer_receive(offer, Clipboard.textType, writing)
        close(writing)
        // The request has to reach the compositor before anything comes back.
        wl_display_flush(display)
        defer { close(reading) }

        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while bytes.count < Clipboard.limit {
            var waiting = pollfd(fd: reading, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Clipboard.pasteTimeoutMilliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }        // nothing came: give up
            let count = chunk.withUnsafeMutableBytes { read(reading, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            break                                  // the end of the pipe
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - The listeners of libwayland

    /// The app itself, from the pointer that a listener gets.
    private static func app(_ data: UnsafeMutableRawPointer?) -> App {
        Unmanaged<App>.fromOpaque(data!).takeUnretainedValue()
    }

    nonisolated(unsafe) static let offerListener = permanent(wl_data_offer_listener(
        offer: { data, _, type in
            app(data).clipboard.offerHasType(String(cString: type!))
        },
        source_actions: { _, _, _ in },
        action: { _, _, _ in }
    ))

    nonisolated(unsafe) static let deviceListener = permanent(wl_data_device_listener(
        data_offer: { data, _, offer in
            let app = app(data)
            app.clipboard.offered(offer)
            wl_data_offer_add_listener(offer, Clipboard.offerListener, data)
        },
        enter: { _, _, _, _, _, _, _ in },
        leave: { _, _ in },
        motion: { _, _, _, _, _ in },
        drop: { _, _ in },
        selection: { data, _, offer in
            app(data).clipboard.selectionChanged(to: offer)
        }
    ))

    nonisolated(unsafe) static let sourceListener = permanent(wl_data_source_listener(
        target: { _, _, _ in },
        send: { data, _, _, fd in
            // Whatever type was asked for, the answer is the same text.
            app(data).clipboard.write(to: fd)
        },
        cancelled: { data, source in
            // Another app has taken the clipboard.
            app(data).clipboard.gaveUpTheClipboard(source)
        },
        dnd_drop_performed: { _, _ in },
        dnd_finished: { _, _ in },
        action: { _, _, _ in }
    ))
}
