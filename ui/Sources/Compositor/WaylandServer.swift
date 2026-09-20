import Glibc
import Render
import Wayland

// The Wayland side of the compositor: the objects apps talk to.
//
// Supported so far:
//   wl_compositor  surfaces (and regions, which are ignored)
//   wl_shm         shared-memory buffers (the Wayland module implements it)
//   xdg_wm_base    toplevel windows (no popups yet)
//   wl_seat        the keyboard. The pointer stays with the shell.
//
// The Swift object for a protocol object is the `data` of its resource, so it
// lives as long as the resource. Back references to resources are weak.

/// A surface: a rectangle of pixels that an app draws into.
final class Surface {
    /// The object of the app. The compositor needs it to send the keyboard
    /// to the surface.
    fileprivate(set) weak var resource: Resource<WlSurface>?
    /// What the app last committed.
    private(set) var content: Bitmap?
    /// Set once the app committed a buffer after its first configure.
    var isMapped = false
    fileprivate(set) var toplevel: Toplevel?

    fileprivate enum PendingBuffer {
        case unchanged
        case attached(Resource<WlBuffer>?)
    }
    fileprivate var pendingBuffer = PendingBuffer.unchanged
    fileprivate var pendingFrameCallbacks: [Resource<WlCallback>] = []
    private var frameCallbacks: [Resource<WlCallback>] = []

    /// Makes the pending state current (wl_surface.commit).
    fileprivate func applyPendingState() {
        if case .attached(let buffer) = pendingBuffer {
            pendingBuffer = .unchanged
            // A buffer destroyed before the commit counts as no buffer.
            if let buffer, !buffer.isDestroyed {
                copyContent(of: buffer)
            } else {
                content = nil   // no buffer hides the surface
            }
        }
        frameCallbacks += pendingFrameCallbacks
        pendingFrameCallbacks.removeAll()
    }

    /// Copies the buffer's pixels, then gives the buffer back to the app.
    private func copyContent(of buffer: Resource<WlBuffer>) {
        guard let shm = buffer.data as? ShmBuffer else {
            return buffer.postError(code: DisplayErrorCode.invalidObject, "only wl_shm buffers are supported")
        }
        guard let pixels = shm.copyPixels() else {
            return buffer.postError(code: WlShm.ErrorCode.invalidFd.rawValue, "the shm pool became smaller")
        }
        buffer.sendRelease()
        content = Bitmap(width: shm.width, height: shm.height, isOpaque: !shm.hasAlpha, pixels: pixels)
    }

    /// Tells the app a frame with its content was shown: time to draw the next.
    func sendFrameDone(time: UInt32) {
        let callbacks = frameCallbacks
        frameCallbacks.removeAll()
        for callback in callbacks {
            callback.sendDone(callbackData: time)
            callback.destroy()
        }
    }
}

/// An xdg_surface with the toplevel role: an app window.
final class Toplevel {
    weak var xdgSurface: Resource<XdgSurface>?
    weak var resource: Resource<XdgToplevel>?
    unowned let surface: Surface
    var title = ""
    var appID = ""
    fileprivate var configured = false

    init(xdgSurface: Resource<XdgSurface>, resource: Resource<XdgToplevel>, surface: Surface) {
        (self.xdgSurface, self.resource, self.surface) = (xdgSurface, resource, surface)
    }
}

final class WaylandServer {
    let display: Display
    private let shm: Shm
    var socketName: String { display.socketName }

    /// The space that a window gets: the app area of the screen. The first
    /// configure asks the app for that size.
    var windowArea: () -> Rect = { Rect(x: 0, y: 0, width: 0, height: 0) }
    /// A toplevel's surface got new content (or was mapped for the first time).
    var surfaceCommitted: (Surface) -> Void = { _ in }
    /// A surface went away.
    var surfaceDestroyed: (Surface) -> Void = { _ in }
    /// The keymap that apps get in wl_keyboard.keymap. The compositor sets
    /// it before the first app connects.
    var keymap = ""

    /// The wl_keyboard objects of the apps.
    private var keyboards: [Resource<WlKeyboard>] = []
    /// The surface that gets the keys, if there is one.
    private weak var focus: Surface?
    /// The modifiers that the apps heard last.
    private var modifiers = Input.Modifiers()

    init(loop: EventLoop) throws(Display.Failure) {
        display = try Display(loop: loop)
        shm = Shm(display: display)
        display.addGlobal(WlCompositor.self, version: 6) { [unowned self] compositor in
            compositor.onRequest = { [unowned self, unowned compositor] request in
                handle(request, of: compositor)
            }
        }
        display.addGlobal(XdgWmBase.self, version: 6) { [unowned self] wmBase in
            wmBase.onRequest = { [unowned self, unowned wmBase] request in
                handle(request, of: wmBase)
            }
        }
        display.addGlobal(WlSeat.self, version: 7) { [unowned self] seat in
            // The seat has a keyboard only. The shell answers the pointer,
            // and an app gets no pointer events yet.
            seat.sendCapabilities(capabilities: WlSeat.Capability.keyboard.rawValue)
            seat.sendName(name: "seat0")
            seat.onRequest = { [unowned self, unowned seat] request in
                handle(request, of: seat)
            }
        }
    }

    /// Sends queued events to clients. Call before waiting for new events.
    func flush() { display.flushClients() }

    // MARK: - wl_seat and wl_keyboard

    private func handle(_ request: WlSeat.Request, of seat: Resource<WlSeat>) {
        switch request {
        case .getKeyboard(let id):
            let keyboard = seat.create(id)
            send(keymap: keyboard)
            keyboard.sendRepeatInfo(rate: 25, delay: 600)
            keyboards.append(keyboard)
            keyboard.onDestroy { [unowned self, unowned keyboard] in
                keyboards.removeAll { $0 === keyboard }
            }
            // The window of this app may have the focus already.
            if let surface = focus?.resource, surface.client === keyboard.client {
                enter(surface, with: keyboard)
            }
        case .getPointer(let id):
            // Accepted and silent: the seat says it has a keyboard only, so
            // an app that asks for a pointer gets no events.
            _ = seat.create(id)
        case .getTouch(let id):
            _ = seat.create(id)
        case .release:
            break
        }
    }

    /// Gives the keys to a surface, or to none. The compositor calls this
    /// when the window in front changes.
    func setKeyboardFocus(_ surface: Surface?) {
        guard focus !== surface else { return }
        if let old = focus?.resource, !old.isDestroyed {
            for keyboard in keyboards(of: old.client) {
                keyboard.sendLeave(serial: display.nextSerial(), surface: old)
            }
        }
        focus = surface
        guard let new = surface?.resource, !new.isDestroyed else { return }
        for keyboard in keyboards(of: new.client) { enter(new, with: keyboard) }
    }

    /// Sends a key to the window with the focus.
    func send(key: Input.Key) {
        guard let surface = focus?.resource, !surface.isDestroyed else {
            modifiers = key.modifiers
            return
        }
        let time = monotonicMilliseconds()
        let state = key.pressed ? WlKeyboard.KeyState.pressed : .released
        for keyboard in keyboards(of: surface.client) {
            if key.modifiers != modifiers { send(key.modifiers, to: keyboard) }
            keyboard.sendKey(serial: display.nextSerial(), time: time,
                             key: key.code, state: state.rawValue)
        }
        modifiers = key.modifiers
    }

    private func enter(_ surface: Resource<WlSurface>, with keyboard: Resource<WlKeyboard>) {
        // No key is down: a click gave the window the focus, not a key.
        keyboard.sendEnter(serial: display.nextSerial(), surface: surface, keys: [])
        send(modifiers, to: keyboard)
    }

    private func send(_ modifiers: Input.Modifiers, to keyboard: Resource<WlKeyboard>) {
        keyboard.sendModifiers(serial: display.nextSerial(),
                               modsDepressed: modifiers.depressed,
                               modsLatched: modifiers.latched,
                               modsLocked: modifiers.locked,
                               group: modifiers.group)
    }

    private func keyboards(of client: Client?) -> [Resource<WlKeyboard>] {
        guard let client else { return [] }
        return keyboards.filter { $0.client === client && !$0.isDestroyed }
    }

    /// Writes the keymap into memory that the app can map, and sends the
    /// file descriptor of it.
    private func send(keymap keyboard: Resource<WlKeyboard>) {
        var bytes = Array(keymap.utf8)
        bytes.append(0)                 // the app reads it as a C string
        let name = "/mydistro-keymap-\(getpid())"
        let fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            log("compositor: no memory for the keymap: \(String(cString: strerror(errno)))")
            return
        }
        shm_unlink(name)
        defer { close(fd) }
        guard ftruncate(fd, off_t(bytes.count)) == 0,
              bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
            log("compositor: can't write the keymap")
            return
        }
        keyboard.sendKeymap(format: WlKeyboard.KeymapFormat.xkbV1.rawValue,
                            fd: fd, size: UInt32(bytes.count))
    }

    // MARK: - wl_compositor and wl_surface

    private func handle(_ request: WlCompositor.Request, of compositor: Resource<WlCompositor>) {
        switch request {
        case .createSurface(let id):
            let resource = compositor.create(id)
            let surface = Surface()
            surface.resource = resource
            resource.data = surface
            resource.onRequest = { [unowned self, unowned resource, unowned surface] request in
                handle(request, of: resource, surface: surface)
            }
            resource.onDestroy { [unowned self, unowned surface] in surfaceDestroyed(surface) }
        case .createRegion(let id):
            // Regions only optimise drawing and input: accepted and ignored.
            _ = compositor.create(id)
        case .release:
            break
        }
    }

    private func handle(_ request: WlSurface.Request, of resource: Resource<WlSurface>, surface: Surface) {
        switch request {
        case .attach(let buffer, _, _):
            surface.pendingBuffer = .attached(buffer)
        case .frame(let id):
            surface.pendingFrameCallbacks.append(resource.create(id))
        case .commit:
            commit(surface)
        case .getRelease(let id):
            _ = resource.create(id)   // wl_surface 7; we advertise 6
        case .destroy, .damage, .damageBuffer, .setOpaqueRegion, .setInputRegion,
             .setBufferTransform, .setBufferScale, .offset:
            break   // every frame is drawn in full, at scale 1, for now
        }
    }

    private func commit(_ surface: Surface) {
        surface.applyPendingState()
        guard let toplevel = surface.toplevel else { return }
        if !toplevel.configured {
            // The first commit asks for a configure. The app gets the size of
            // the app area, and the states of a window that fills its space.
            // An app that keeps another size still opens, in the middle of
            // the area.
            let area = windowArea()
            toplevel.resource?.sendConfigure(
                width: Int32(area.width), height: Int32(area.height),
                states: WaylandServer.states(.maximized, .activated))
            toplevel.xdgSurface?.sendConfigure(serial: display.nextSerial())
            toplevel.configured = true
            return
        }
        if surface.content != nil { surface.isMapped = true }
        surfaceCommitted(surface)
    }

    /// Window states, as the array of 32-bit values that xdg_toplevel wants.
    private static func states(_ values: XdgToplevel.State...) -> [UInt8] {
        var bytes: [UInt8] = []
        for value in values {
            withUnsafeBytes(of: value.rawValue.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    // MARK: - xdg_wm_base, xdg_surface, xdg_toplevel

    private func handle(_ request: XdgWmBase.Request, of wmBase: Resource<XdgWmBase>) {
        switch request {
        case .createPositioner(let id):
            // Positioners place popups, which aren't supported yet.
            _ = wmBase.create(id)
        case .getXdgSurface(let id, let surfaceResource):
            let resource = wmBase.create(id)
            guard let surface = surfaceResource.data as? Surface else { return }
            resource.onRequest = { [unowned self, unowned resource, weak surface] request in
                guard let surface else { return }
                handle(request, of: resource, surface: surface)
            }
        case .destroy, .pong:
            break
        }
    }

    private func handle(_ request: XdgSurface.Request, of xdgSurface: Resource<XdgSurface>, surface: Surface) {
        switch request {
        case .getToplevel(let id):
            let resource = xdgSurface.create(id)
            let toplevel = Toplevel(xdgSurface: xdgSurface, resource: resource, surface: surface)
            surface.toplevel = toplevel
            resource.data = toplevel
            resource.onRequest = { [unowned toplevel] request in
                switch request {
                case .setTitle(let title): toplevel.title = title
                case .setAppId(let appID): toplevel.appID = appID
                default: break
                }
            }
            resource.onDestroy { [unowned self, weak surface] in
                guard let surface else { return }
                surface.toplevel = nil
                surface.isMapped = false
                surfaceDestroyed(surface)
            }
        case .getPopup(let id, _, _):
            _ = xdgSurface.create(id)
            xdgSurface.postError(code: DisplayErrorCode.implementation, "popups are not supported yet")
        case .destroy, .setWindowGeometry, .ackConfigure:
            break
        }
    }
}
