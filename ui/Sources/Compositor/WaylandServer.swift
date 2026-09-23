import Glibc
import Render
import Wayland

// The Wayland side of the compositor: the objects apps talk to.
//
// Supported so far:
//   wl_compositor  surfaces (and regions, which are ignored)
//   wl_shm         shared-memory buffers (the Wayland module implements it)
//   xdg_wm_base    toplevel windows (no popups yet)
//   wl_seat        the keyboard and the pointer. The shell keeps the
//                  pointer while it is over the chrome of the shell.
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
    /// How many pixels of the buffer make one point
    /// (wl_surface.set_buffer_scale). An app that draws for a screen with
    /// small pixels sets 2 and commits a buffer of twice the size.
    var bufferScale = 1
    fileprivate(set) var toplevel: Toplevel?

    fileprivate enum PendingBuffer {
        case unchanged
        case attached(Resource<WlBuffer>?)
    }
    fileprivate var pendingBuffer = PendingBuffer.unchanged
    fileprivate var pendingFrameCallbacks: [Resource<WlCallback>] = []
    /// What the app said changed since its last commit: wl_surface.damage
    /// in points, and wl_surface.damage_buffer in the pixels of the buffer.
    /// The commit copies only this part of the buffer.
    fileprivate var pendingDamage: [Rect] = []
    fileprivate var pendingBufferDamage: [Rect] = []
    private var frameCallbacks: [Resource<WlCallback>] = []

    /// Makes the pending state current (wl_surface.commit).
    fileprivate func applyPendingState() {
        // Damage in points becomes damage in pixels of the buffer. An app
        // that draws at twice the scale damages twice the pixels.
        let damage = pendingBufferDamage + pendingDamage.map {
            Rect(x: $0.x * bufferScale, y: $0.y * bufferScale,
                 width: $0.width * bufferScale, height: $0.height * bufferScale)
        }
        pendingDamage.removeAll()
        pendingBufferDamage.removeAll()
        if case .attached(let buffer) = pendingBuffer {
            pendingBuffer = .unchanged
            // A buffer destroyed before the commit counts as no buffer.
            if let buffer, !buffer.isDestroyed {
                copyContent(of: buffer, damage: damage)
            } else {
                content = nil   // no buffer hides the surface
            }
        }
        frameCallbacks += pendingFrameCallbacks
        pendingFrameCallbacks.removeAll()
    }

    /// Copies the buffer's pixels, then gives the buffer back to the app.
    ///
    /// A buffer of the same size and kind as the last one goes into the same
    /// Bitmap, and only the part that the app damaged is copied. The Bitmap
    /// then says which part changed (Bitmap.markChanged), so the screen
    /// draws only that part again, and the GPU uploads only those rows. A
    /// new size makes a new Bitmap, which is new everywhere.
    ///
    /// A commit of a new buffer with no damage at all is taken as damage
    /// everywhere. The protocol says that nothing changed then, and a
    /// compositor may keep the old picture. A copy of the whole buffer is
    /// never wrong, and an app that forgot its damage still shows.
    private func copyContent(of buffer: Resource<WlBuffer>, damage: [Rect]) {
        guard let shm = buffer.data as? ShmBuffer else {
            return buffer.postError(code: DisplayErrorCode.invalidObject, "only wl_shm buffers are supported")
        }
        let whole = Rect(x: 0, y: 0, width: shm.width, height: shm.height)
        if let content, content.width == shm.width, content.height == shm.height,
           content.isOpaque == !shm.hasAlpha {
            var parts = Region()
            for rect in damage { parts.add(Surface.intersection(rect, whole)) }
            if damage.isEmpty { parts = Region(whole) }
            let rects = parts.rects
            let intact = content.pixels.withUnsafeMutableBufferPointer { pixels in
                shm.copyPixels(rects.map { ($0.x, $0.y, $0.width, $0.height) }, into: pixels)
            }
            guard intact else {
                return buffer.postError(code: WlShm.ErrorCode.invalidFd.rawValue, "the shm pool became smaller")
            }
            buffer.sendRelease()
            content.markChanged(rects)
            return
        }
        guard let pixels = shm.copyPixels() else {
            return buffer.postError(code: WlShm.ErrorCode.invalidFd.rawValue, "the shm pool became smaller")
        }
        buffer.sendRelease()
        content = Bitmap(width: shm.width, height: shm.height, isOpaque: !shm.hasAlpha, pixels: pixels)
    }

    /// The part of `a` inside `b`. Damage of Int32.max, which apps send for
    /// "all of it", ends at the edge of the buffer.
    private static func intersection(_ a: Rect, _ b: Rect) -> Rect {
        guard a.width > 0, a.height > 0 else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
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
    /// The smallest size that the app accepts (xdg_toplevel.set_min_size).
    /// A layout reads it as the app's answer to a proposal, because the
    /// compositor cannot ask another process for a size.
    var minSize: (width: Double, height: Double)?
    /// The size that the last configure asked for. The compositor sends a
    /// new one only when the size or the states change.
    var configuredSize: (width: Int, height: Int)?
    /// The states that the last configure gave.
    var configuredStates: WindowStates?
    fileprivate var configured = false

    init(xdgSurface: Resource<XdgSurface>, resource: Resource<XdgToplevel>, surface: Surface) {
        (self.xdgSurface, self.resource, self.surface) = (xdgSurface, resource, surface)
    }
}

/// The states of a window that change while it is open. It is always
/// maximized as well, because a layout gives it its frame.
struct WindowStates: Equatable {
    /// It has the keys.
    var activated = false
    /// A person is changing its size now.
    var resizing = false
}

final class WaylandServer {
    let display: Display
    /// What one app copied and another pastes, and the same text on the Mac.
    let clipboard: Clipboard
    private let shm: Shm
    var socketName: String { display.socketName }

    /// The size that a window gets when it first appears. The compositor
    /// runs the layout and answers with the frame that the new window got.
    var sizeForNewWindow: (Surface) -> Rect = { _ in Rect(x: 0, y: 0, width: 0, height: 0) }
    /// A toplevel's surface got new content (or was mapped for the first time).
    var surfaceCommitted: (Surface) -> Void = { _ in }
    /// A surface went away.
    var surfaceDestroyed: (Surface) -> Void = { _ in }
    /// An app asked to move its window (xdg_toplevel.move), with the serial
    /// of the press that holds the pointer now. The server checked the
    /// serial; the compositor decides what a move means.
    var moveRequested: (Surface) -> Void = { _ in }
    /// An app asked to change the size of its window from these edges
    /// (xdg_toplevel.resize), with the serial of the press that holds the
    /// pointer now.
    var resizeRequested: (Surface, UInt32) -> Void = { _, _ in }
    /// The keymap that apps get in wl_keyboard.keymap. The compositor sets
    /// it before the first app connects.
    var keymap = ""

    /// The wl_keyboard objects of the apps.
    private var keyboards: [Resource<WlKeyboard>] = []
    /// The wl_pointer objects of the apps.
    private var pointers: [Resource<WlPointer>] = []
    /// The surface that the pointer is over, when it belongs to an app.
    private weak var pointerFocus: Surface?
    /// The last press that an app got, and the serials it carried: one for
    /// each wl_pointer of the app. A move or a resize names one of them,
    /// which is how an app proves that a person is holding the button.
    private weak var pressedSurface: Surface?
    private var pressSerials: [UInt32] = []
    /// What the screen is now: its size in pixels, how many pixels there
    /// are to a point, and how large the picture is in millimetres. An app
    /// reads this from wl_output, and it needs the scale to draw sharply.
    struct ScreenInfo {
        var width = 0
        var height = 0
        var refreshRate = 0
        var scale = 1
        var widthInMillimetres = 0
        var heightInMillimetres = 0
    }

    /// The screen, as the apps are told about it.
    private(set) var screenInfo = ScreenInfo()
    /// The wl_output objects that apps hold. They are told again when the
    /// screen changes.
    private var outputs: [Resource<WlOutput>] = []

    /// The surface that gets the keys, if there is one.
    private weak var focus: Surface?
    /// The modifiers that the apps heard last.
    private var modifiers = Input.Modifiers()

    init(loop: EventLoop) throws(Display.Failure) {
        display = try Display(loop: loop)
        shm = Shm(display: display)
        clipboard = Clipboard(display: display, loop: loop)
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
        display.addGlobal(WlOutput.self, version: 4) { [unowned self] output in
            outputs.append(output)
            send(screenInfo, to: output)
            output.onDestroy { [unowned self] in
                outputs.removeAll { $0 === output }
            }
        }
        display.addGlobal(WlSeat.self, version: 7) { [unowned self] seat in
            // The seat has a keyboard and a pointer. The shell keeps the
            // pointer while it is over its own chrome; the compositor gives
            // it here only while it is over the window of an app.
            seat.sendCapabilities(capabilities: WlSeat.Capability.keyboard.rawValue
                | WlSeat.Capability.pointer.rawValue)
            seat.sendName(name: "seat0")
            seat.onRequest = { [unowned self, unowned seat] request in
                handle(request, of: seat)
            }
        }
    }

    /// Sends queued events to clients. Call before waiting for new events.
    func flush() { display.flushClients() }

    // MARK: - wl_output

    /// The screen changed. Every app that holds a wl_output is told.
    func screenChanged(to info: ScreenInfo) {
        screenInfo = info
        for output in outputs { send(info, to: output) }
    }

    /// Tells one app what the screen is. wl_output sends a set of events and
    /// then `done`, so that an app sees one complete description.
    private func send(_ info: ScreenInfo, to output: Resource<WlOutput>) {
        output.sendGeometry(x: 0, y: 0,
                            physicalWidth: Int32(info.widthInMillimetres),
                            physicalHeight: Int32(info.heightInMillimetres),
                            subpixel: Int32(WlOutput.Subpixel.unknown.rawValue),
                            make: "Apus", model: "screen",
                            transform: Int32(WlOutput.Transform.normal.rawValue))
        output.sendMode(flags: WlOutput.Mode.current.rawValue,
                        width: Int32(info.width), height: Int32(info.height),
                        refresh: Int32(info.refreshRate * 1000))
        if output.version >= 2 {
            output.sendScale(factor: Int32(info.scale))
        }
        if output.version >= 4 {
            output.sendName(name: "apus-0")
            output.sendDescription(description: "Apus screen")
        }
        if output.version >= 2 {
            output.sendDone()
        }
    }

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
            let pointer = seat.create(id)
            pointers.append(pointer)
            pointer.onDestroy { [unowned self, unowned pointer] in
                pointers.removeAll { $0 === pointer }
            }
            // A pointer that an app asks for while it is already under the
            // pointer hears about that at once.
            if let surface = pointerFocus, surface.resource?.client === pointer.client {
                pointerEnter(surface, with: pointer, at: pointerAt)
            }
        case .getTouch(let id):
            _ = seat.create(id)
        case .release:
            break
        }
    }

    // MARK: - wl_pointer

    /// Where the pointer is inside the surface it is over, in points.
    private var pointerAt: (x: Double, y: Double) = (0, 0)

    /// Gives the pointer to a surface of an app, or takes it away when the
    /// shell wants it. `point` is inside the surface.
    func setPointerFocus(_ surface: Surface?, at point: (x: Double, y: Double)) {
        pointerAt = point
        guard surface !== pointerFocus else { return }
        if let old = pointerFocus?.resource, !old.isDestroyed {
            for pointer in pointers(of: old.client) {
                pointer.sendLeave(serial: display.nextSerial(), surface: old)
                pointer.sendFrame()
            }
        }
        pointerFocus = surface
        guard let surface, surface.resource != nil else { return }
        for pointer in pointers(of: surface.resource?.client) {
            pointerEnter(surface, with: pointer, at: point)
        }
    }

    private func pointerEnter(_ surface: Surface, with pointer: Resource<WlPointer>,
                              at point: (x: Double, y: Double)) {
        guard let resource = surface.resource else { return }
        pointer.sendEnter(serial: display.nextSerial(), surface: resource,
                          surfaceX: point.x, surfaceY: point.y)
        pointer.sendFrame()
    }

    /// The pointer moved inside the surface that has it.
    func sendPointer(motion point: (x: Double, y: Double), time: UInt32) {
        pointerAt = point
        guard let resource = pointerFocus?.resource, !resource.isDestroyed else { return }
        for pointer in pointers(of: resource.client) {
            pointer.sendMotion(time: time, surfaceX: point.x, surfaceY: point.y)
            pointer.sendFrame()
        }
    }

    /// A button of the pointer, for the surface that has it.
    func sendPointer(button code: UInt32, pressed: Bool, time: UInt32) {
        guard let resource = pointerFocus?.resource, !resource.isDestroyed else { return }
        let state = pressed ? WlPointer.ButtonState.pressed : .released
        if pressed {
            pressedSurface = pointerFocus
            pressSerials.removeAll()
        }
        for pointer in pointers(of: resource.client) {
            let serial = display.nextSerial()
            if pressed { pressSerials.append(serial) }
            pointer.sendButton(serial: serial, time: time,
                               button: code, state: state.rawValue)
            pointer.sendFrame()
        }
    }

    /// Forgets the last press. The compositor calls this when every button
    /// is up, so that a serial of an old press cannot start a move.
    func pressEnded() {
        pressedSurface = nil
        pressSerials.removeAll()
    }

    /// Whether this serial is the serial of the press that the surface got.
    private func isPress(_ serial: UInt32, on surface: Surface) -> Bool {
        pressedSurface === surface && pressSerials.contains(serial)
    }

    /// A wheel or a touchpad, for the surface that has the pointer.
    ///
    /// The numbers are wl_pointer's: on the vertical axis, down is positive,
    /// and one click of a usual wheel is 15. `axis_source` says which device
    /// they came from, so that an app can tell one click of a wheel from a
    /// finger that moved a little.
    func sendPointer(scrollDX dx: Double, dy: Double, fromWheel: Bool, time: UInt32) {
        guard let resource = pointerFocus?.resource, !resource.isDestroyed else { return }
        let source = fromWheel ? WlPointer.AxisSource.wheel : .finger
        for pointer in pointers(of: resource.client) {
            // axis_source came with version 5. An older app gets the axis
            // events alone, which say the same thing less exactly.
            if pointer.version >= 5 { pointer.sendAxisSource(axisSource: source.rawValue) }
            if dy != 0 {
                pointer.sendAxis(time: time,
                                 axis: WlPointer.Axis.verticalScroll.rawValue, value: dy)
            }
            if dx != 0 {
                pointer.sendAxis(time: time,
                                 axis: WlPointer.Axis.horizontalScroll.rawValue, value: dx)
            }
            pointer.sendFrame()
        }
    }

    /// The wl_pointer objects of one client.
    private func pointers(of client: Client?) -> [Resource<WlPointer>] {
        pointers.filter { $0.client === client && !$0.isDestroyed }
    }

    /// Gives the keys to a surface, or to none. The compositor calls this
    /// when the window in front changes.
    func setKeyboardFocus(_ surface: Surface?) {
        guard focus !== surface else { return }
        // The clipboard goes with the keyboard: the protocol offers what
        // was copied to the app that a person is typing into.
        clipboard.focusChanged(to: surface?.resource?.client)
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
        let name = "/apus-keymap-\(getpid())"
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
        case .setBufferScale(let scale):
            // The app says how many pixels of its buffer make one point.
            surface.bufferScale = max(1, Int(scale))
        case .damage(let x, let y, let width, let height):
            surface.pendingDamage.append(Rect(x: Int(x), y: Int(y),
                                              width: Int(width), height: Int(height)))
        case .damageBuffer(let x, let y, let width, let height):
            surface.pendingBufferDamage.append(Rect(x: Int(x), y: Int(y),
                                                    width: Int(width), height: Int(height)))
        case .destroy, .setOpaqueRegion, .setInputRegion, .setBufferTransform, .offset:
            break
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
            let area = sizeForNewWindow(surface)
            configure(surface, width: area.width, height: area.height,
                      states: WindowStates(activated: true))
            toplevel.configured = true
            return
        }
        if surface.content != nil { surface.isMapped = true }
        surfaceCommitted(surface)
    }

    /// Asks a window for a size. The layout owns the size, so this is the
    /// proposal of the negotiation: the app answers by committing a buffer,
    /// which may be a different size.
    func configure(_ surface: Surface, width: Int, height: Int, states: WindowStates) {
        guard let toplevel = surface.toplevel else { return }
        toplevel.configuredSize = (width, height)
        toplevel.configuredStates = states
        var values: [XdgToplevel.State] = [.maximized]
        if states.activated { values.append(.activated) }
        if states.resizing { values.append(.resizing) }
        toplevel.resource?.sendConfigure(
            width: Int32(width), height: Int32(height),
            states: WaylandServer.states(values))
        toplevel.xdgSurface?.sendConfigure(serial: display.nextSerial())
    }

    /// Window states, as the array of 32-bit values that xdg_toplevel wants.
    private static func states(_ values: [XdgToplevel.State]) -> [UInt8] {
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
            resource.onRequest = { [unowned self, unowned toplevel, unowned resource] request in
                switch request {
                case .setTitle(let title): toplevel.title = title
                case .setAppId(let appID): toplevel.appID = appID
                case .setMinSize(let width, let height):
                    toplevel.minSize = width > 0 || height > 0
                        ? (Double(width), Double(height))
                        : nil
                case .move(_, let serial):
                    // A move needs the button that is down now. An app that
                    // names an old press, or a press on another window, gets
                    // nothing: the protocol lets the compositor ignore it.
                    guard isPress(serial, on: toplevel.surface) else {
                        log("WINDOW-MOVE-IGNORED \"\(toplevel.title)\" serial \(serial)")
                        return
                    }
                    moveRequested(toplevel.surface)
                case .resize(_, let serial, let edges):
                    guard let edge = XdgToplevel.ResizeEdge(rawValue: edges) else {
                        return resource.postError(
                            code: XdgToplevel.ErrorCode.invalidResizeEdge.rawValue,
                            "\(edges) is not an edge")
                    }
                    guard edge != .none, isPress(serial, on: toplevel.surface) else {
                        log("WINDOW-RESIZE-IGNORED \"\(toplevel.title)\" serial \(serial)")
                        return
                    }
                    resizeRequested(toplevel.surface, edges)
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
