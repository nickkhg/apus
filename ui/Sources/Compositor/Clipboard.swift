import Glibc
import Wayland

// The clipboard of the system: wl_data_device_manager.
//
// One app copies, another pastes, and neither knows about the other. In
// Wayland the copying app keeps the data and offers a list of types for it
// (wl_data_source). The compositor holds the offer, tells the app that has
// the keyboard about it (wl_data_device.selection), and when that app asks
// for a type it passes a pipe from the one to the other. The data itself
// never goes through the compositor.
//
//     copy:    app ── wl_data_source ──▶ compositor
//     paste:   app ◀── wl_data_offer ─── compositor
//              app ◀════ a pipe ════════ the app that copied
//
// The compositor does read a copy of the text, though, for the one thing
// that Wayland does not do: the clipboard of the Mac. HostClipboard.swift
// carries the text both ways, and text that came from the Mac is held here
// and written into the pipe by the compositor itself. See docs/clipboard.md.

/// The clipboard, and the wl_data_device_manager that apps talk to.
final class Clipboard {
    /// The types that hold plain text. An app names the first one; the
    /// others are what older programs call the same thing, and a program
    /// that asks for one of them gets the same bytes.
    static let textTypes = ["text/plain;charset=utf-8", "text/plain",
                            "UTF8_STRING", "STRING", "TEXT"]
    /// The most that is carried, either way. A clipboard is for text that a
    /// person selected, and a pipe that never ends must not fill memory.
    static let limit = 4 << 20

    /// Who holds the clipboard now.
    private enum Owner {
        case none
        /// An app holds it. An app that wants the data is put straight
        /// through to this source, so every type works and not only text.
        case app(source: Resource<WlDataSource>, types: [String])
        /// The compositor holds it, with text that came from the Mac.
        case host(text: String)
    }

    /// Called when an app puts text on the clipboard, so that the clipboard
    /// of the Mac can follow. It is not called for text that came from the
    /// Mac, which would send it straight back.
    var textChanged: (String) -> Void = { _ in }

    /// The text on the clipboard, as far as the compositor has read it.
    private(set) var text = ""

    private let display: Display
    private let loop: EventLoop
    private var owner = Owner.none
    private var devices: [Resource<WlDataDevice>] = []
    /// The client whose window has the keyboard. Only it is told about the
    /// clipboard, as the protocol says.
    private weak var focused: Client?

    init(display: Display, loop: EventLoop) {
        self.display = display
        self.loop = loop
        display.addGlobal(WlDataDeviceManager.self, version: 3) { [unowned self] manager in
            manager.onRequest = { [unowned self, unowned manager] request in
                handle(request, of: manager)
            }
        }
    }

    // MARK: - What the apps ask

    private func handle(_ request: WlDataDeviceManager.Request,
                        of manager: Resource<WlDataDeviceManager>) {
        switch request {
        case .createDataSource(let id):
            let source = manager.create(id)
            let types = TypeList()
            source.data = types
            source.onRequest = { [unowned source] request in
                switch request {
                case .offer(let mimeType):
                    // A source can name a type twice; the list is what it
                    // offers, in the order that it offered them.
                    if !types.list.contains(mimeType) { types.list.append(mimeType) }
                case .destroy, .setActions:
                    break
                }
                _ = source
            }
            source.onDestroy { [unowned self] in
                if case .app(let held, _) = owner, held === source { setSelection(nil) }
            }
        case .getDataDevice(let id, _):
            let device = manager.create(id)
            devices.append(device)
            device.onRequest = { [unowned self, unowned device] request in
                switch request {
                case .setSelection(let source, _):
                    setSelection(source)
                case .startDrag(let source, _, _, _):
                    // Dragging between windows is not a thing that Apus does
                    // yet. The app is told at once, so that it does not wait.
                    source?.sendCancelled()
                case .release:
                    break
                }
                _ = device
            }
            device.onDestroy { [unowned self] in
                devices.removeAll { $0 === device }
            }
            // A window that already has the keyboard hears what is on the
            // clipboard as soon as it asks for a data device.
            if device.client === focused { send(to: device) }
        case .release:
            break
        }
    }

    private func handle(_ request: WlDataOffer.Request, of offer: Resource<WlDataOffer>) {
        switch request {
        case .receive(let mimeType, let fd):
            deliver(mimeType: mimeType, to: fd)
        case .accept, .destroy, .finish, .setActions:
            break
        }
    }

    // MARK: - Taking and giving the clipboard

    /// An app has copied something, or has given the clipboard up.
    private func setSelection(_ source: Resource<WlDataSource>?) {
        if case .app(let old, _) = owner, old !== source, !old.isDestroyed {
            old.sendCancelled()
        }
        guard let source, !source.isDestroyed else {
            owner = .none
            text = ""
            advertise()
            return
        }
        let types = (source.data as? TypeList)?.list ?? []
        owner = .app(source: source, types: types)
        advertise()
        // The compositor reads a copy of the text for the Mac. Only text:
        // anything else stays in the app that holds it, and only an app of
        // this machine can paste it.
        guard let type = Clipboard.textTypes.first(where: types.contains) else {
            text = ""
            return
        }
        read(type, from: source)
    }

    /// The clipboard of the Mac has something new on it.
    func setHostText(_ text: String) {
        guard text != self.text else { return }
        if case .app(let old, _) = owner, !old.isDestroyed { old.sendCancelled() }
        owner = .host(text: text)
        self.text = text
        advertise()
    }

    /// The window in front changed. The protocol gives the clipboard to the
    /// app that has the keyboard, so the new one is told what is on it.
    func focusChanged(to client: Client?) {
        guard client !== focused else { return }
        focused = client
        advertise()
    }

    /// The types that an app would be offered now.
    private var offeredTypes: [String] {
        switch owner {
        case .none: []
        case .app(_, let types): types
        case .host: Clipboard.textTypes
        }
    }

    /// Tells the app that has the keyboard what is on the clipboard.
    private func advertise() {
        for device in devices where device.client === focused && !device.isDestroyed {
            send(to: device)
        }
    }

    private func send(to device: Resource<WlDataDevice>) {
        guard let client = device.client, !device.isDestroyed else { return }
        let types = offeredTypes
        guard !types.isEmpty else {
            device.sendSelection(id: nil)
            return
        }
        // The offer is an object that the compositor makes for the app: the
        // app did not ask for it, so its ID comes from the server's range.
        let offer = client.createServerObject(WlDataOffer.self, version: device.version)
        offer.onRequest = { [unowned self, unowned offer] request in handle(request, of: offer) }
        device.sendDataOffer(id: offer)
        for type in types { offer.sendOffer(mimeType: type) }
        device.sendSelection(id: offer)
    }

    /// An app is pasting: give it the data on the pipe that it opened.
    private func deliver(mimeType: String, to fd: Int32) {
        switch owner {
        case .none:
            close(fd)
        case .app(let source, _):
            // Straight through. The app that copied writes into the pipe of
            // the app that is pasting, and the compositor reads nothing.
            guard !source.isDestroyed else {
                close(fd)
                return
            }
            source.sendSend(mimeType: mimeType, fd: fd)
            close(fd)          // the event took a copy of it
            display.flushClients()
        case .host(let text):
            write(text, to: fd)
        }
    }

    /// Reads a copy of what an app copied, for the clipboard of the Mac.
    private func read(_ type: String, from source: Resource<WlDataSource>) {
        // pipe2 is a GNU extension, which Swift does not see, so the flags
        // go on afterwards. Both ends are close-on-exec: an app that the
        // dock starts must not find them open.
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            log("clipboard: no pipe: \(String(cString: strerror(errno)))")
            return
        }
        let (reading, writing) = (ends[0], ends[1])
        for end in [reading, writing] { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(reading, F_SETFL, fcntl(reading, F_GETFL, 0) | O_NONBLOCK)
        source.sendSend(mimeType: type, fd: writing)
        close(writing)         // the app has it now; the read end sees the end
        display.flushClients()
        Pipe(reading: reading, loop: loop) { [unowned self, unowned source] bytes in
            // The app can have given the clipboard up while this was read.
            guard case .app(let held, _) = owner, held === source else { return }
            let copied = String(decoding: bytes, as: UTF8.self)
            text = copied
            textChanged(copied)
        }
    }

    /// Writes the text of the Mac into the pipe that an app opened.
    private func write(_ text: String, to fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        Pipe(writing: Array(text.utf8), to: fd, loop: loop)
    }
}

/// The types that one wl_data_source has offered. A resource keeps one
/// object for the compositor, and this is the source's.
private final class TypeList {
    var list: [String] = []
}

/// One end of a pipe that the event loop reads or writes.
///
/// A pipe holds 64 kB and then waits for the other side. The compositor has
/// frames to draw, so it never waits: the loop says when there is room or
/// something to read, and the pipe closes itself and says so when it is done.
///
/// The watch of the loop holds the pipe, and the loop holds the watch, so a
/// pipe that is still working stays alive without anything else keeping it.
/// Cancelling the watch in `done` is what lets it go, and the loop holds the
/// watch for as long as the callback runs, so the pipe is never freed while
/// one of its own methods is on the stack.
private final class Pipe {
    private enum Direction { case reading, writing }

    private let fd: Int32
    private let direction: Direction
    private var watch: EventLoop.Watch?
    private var bytes: [UInt8]
    private var sent = 0
    private var finished: (([UInt8]) -> Void)?

    /// Reads to the end of the pipe, then calls `done` with what came.
    @discardableResult
    init(reading fd: Int32, loop: EventLoop, _ done: @escaping ([UInt8]) -> Void) {
        (self.fd, direction, bytes, finished) = (fd, .reading, [], done)
        watch = loop.watch(fd: fd) { [self] _ in step() }
    }

    /// Writes all of `bytes`, then closes the pipe.
    @discardableResult
    init(writing bytes: [UInt8], to fd: Int32, loop: EventLoop) {
        (self.fd, direction, self.bytes) = (fd, .writing, bytes)
        finished = { _ in }
        let watch = loop.watch(fd: fd) { [self] _ in step() }
        watch.setWantsWritable(true)
        self.watch = watch
        // The pipe usually has room at once, so the first try is here and
        // not one turn of the loop later.
        step()
    }

    private func step() {
        switch direction {
        case .reading: readStep()
        case .writing: writeStep()
        }
    }

    private func readStep() {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while bytes.count < Clipboard.limit {
            let count = chunk.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.append(contentsOf: chunk[0..<count])
                continue
            }
            // Nothing more for now: wait to be called again. Zero bytes is
            // the end of the pipe, and an error ends it too.
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            break
        }
        done()
    }

    private func writeStep() {
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes {
                Glibc.write(fd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                sent += count
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            break            // the app closed its end: nothing more to say
        }
        done()
    }

    private func done() {
        guard let finished else { return }
        self.finished = nil
        watch?.cancel()
        watch = nil
        close(fd)
        finished(bytes)
    }

}
