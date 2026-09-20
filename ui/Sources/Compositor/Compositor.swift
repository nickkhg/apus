import DRMKit
import Glibc
import Render
import Shell
import Toolkit
import Wayland

/// The compositor: owns the screen, input and the Wayland server, keeps the
/// window list and turns it into a display list for each frame.
public final class Compositor {
    public struct Options {
        /// Screen background, 0xRRGGBB.
        public var background: UInt32 = 0x2B2340
        public init() {}
    }

    /// A mapped toplevel and where it is on screen.
    private final class Window {
        let surface: Surface
        /// Where the layout put the window. A window with no frame waits in
        /// the rail: it stays open and keeps its state, and it is not drawn.
        var frame: Rect?
        init(surface: Surface, frame: Rect?) { (self.surface, self.frame) = (surface, frame) }
    }

    private let options: Options
    private let seat: Seat
    private let drm: DRMDevice
    private let screen: Screen
    private let input: Input
    private let server: WaylandServer
    private let loop: EventLoop

    private var windows: [Window] = []   // back to front
    private var pointer: (x: Double, y: Double)
    private var running = true
    /// What the shell shows. The clock updates it every minute.
    private var shell = ShellState()
    /// The shell's view tree: its `@State` values and the pointer.
    private let host = ViewHost()
    /// What the shell can ask the compositor to do.
    private var shellActions = ShellActions()
    /// The layout that owns the canvas. A window never floats: this is the
    /// only thing that gives a window a frame.
    private var layoutKind = WindowLayoutKind.principal
    /// The apps in /Applications. The dock shows one icon for each.
    private let apps: [AppBundle]
    /// The same apps, as the shell gets them. They do not change, so the
    /// compositor makes them once and not for each frame.
    private let appEntries: [AppEntry]

    public var socketName: String { server.socketName }
    public var screenSize: (width: Int, height: Int) { (screen.width, screen.height) }

    public init(options: Options = Options()) throws {
        self.options = options
        debug("opening seat")
        seat = try Seat()
        debug("seat \(seat.name) active; opening display")
        drm = try Compositor.openDisplayDevice(seat: seat)
        screen = try Screen(device: drm)
        debug("screen \(drm.path) \(screen.output); starting input")
        input = try Input(seat: seat)
        debug("input ready; starting Wayland server")
        loop = try EventLoop()
        server = try WaylandServer(loop: loop)
        pointer = (Double(screen.width) / 2, Double(screen.height) / 2)
        apps = AppCatalog.bundles()
        appEntries = apps.map(\.entry)
        debug("\(apps.count) apps in \(AppCatalog.directory)")
        // An app that the dock starts connects to this compositor. The
        // compositor does not wait for the child, so the kernel removes the
        // child when it ends.
        setenv("WAYLAND_DISPLAY", server.socketName, 1)
        signal(SIGCHLD, SIG_IGN)

        loop.watch(fd: seat.fd) { [unowned self] in seat.dispatch() }
        loop.watch(fd: drm.fd) { [unowned self] in drm.handleEvents() }
        loop.watch(fd: input.fd) { [unowned self] in input.dispatch() }
        try loop.onSignal(SIGINT) { [unowned self] in running = false }
        try loop.onSignal(SIGTERM) { [unowned self] in running = false }

        screen.draw = { [unowned self] canvas in SoftwareRenderer.render(displayList(), into: canvas) }
        screen.frameShown = { [unowned self] in
            let now = monotonicMilliseconds()
            for window in windows { window.surface.sendFrameDone(time: now) }
        }
        input.handler = { [unowned self] event in handle(event) }
        host.needsUpdate = { [unowned self] in screen.setNeedsFrame() }
        shellActions = ShellActions(
            openApp: { [unowned self] id in openApp(id) },
            closeFrontWindow: { [unowned self] in closeFrontWindow() }
        )
        shell.clock = Compositor.clockText()
        // The clock changes once a minute. A one-second timer keeps it right
        // without a frame between minutes.
        try loop.onTimer(milliseconds: 1000) { [unowned self] in updateClock() }
        server.keymap = input.keymapText
        server.sizeForNewWindow = { [unowned self] surface in sizeForNewWindow(surface) }
        server.surfaceCommitted = { [unowned self] surface in surfaceCommitted(surface) }
        server.surfaceDestroyed = { [unowned self] surface in
            windows.removeAll { $0.surface === surface }
            arrange()
            updateFocus()
            screen.setNeedsFrame()
        }
        screen.setNeedsFrame()
    }

    /// Runs until SIGINT/SIGTERM or Ctrl+Alt+Backspace, then gives the
    /// screen back.
    public func run() {
        while running {
            server.flush()
            loop.dispatch()
        }
        screen.release()
    }

    /// The first DRM card with a connected output, opened through the seat.
    private static func openDisplayDevice(seat: Seat) throws -> DRMDevice {
        for index in 0..<8 {
            let path = "/dev/dri/card\(index)"
            guard access(path, F_OK) == 0, let fd = try? seat.openDevice(path) else { continue }
            let device = DRMDevice(fd: fd, path: path)
            if let outputs = try? device.connectedOutputs(), !outputs.isEmpty { return device }
            seat.closeDevice(fd)
        }
        throw DRMError.noDevice
    }

    // MARK: - Drawing

    private func displayList() -> DisplayList {
        // The option is 0xRRGGBB. The renderer wants an alpha byte, and the
        // desktop is always opaque.
        var list: DisplayList = [.fill(Rect(x: 0, y: 0, width: screen.width, height: screen.height),
                                       color: options.background | 0xFF00_0000)]
        for window in windows {
            guard let frame = window.frame, let content = window.surface.content else { continue }
            // The frame is the layout's, not the app's. An app that drew a
            // larger buffer is cut to its frame; a smaller one sits in the
            // middle of it and the desktop shows around it.
            let x = frame.x + max(0, (frame.width - content.width) / 2)
            let y = frame.y + max(0, (frame.height - content.height) / 2)
            list.append(.pushClip(frame))
            list.append(.bitmap(content, x: x, y: y))
            list.append(.popClip)
        }
        // The shell goes over the windows, and the pointer over both. The
        // host keeps the state of the shell views from frame to frame.
        var state = shell
        state.apps = appEntries
        state.runningApps = Set(windows.compactMap { $0.surface.toplevel?.appID })
        state.windowTitles = windows.map { $0.surface.toplevel?.title ?? "" }
        list += host.displayList(for: RootView(state: state, actions: shellActions), in: screenRect)
        list.append(.bitmap(Cursor.bitmap, x: Int(pointer.x), y: Int(pointer.y)))
        return list
    }

    private var screenRect: Rect {
        Rect(x: 0, y: 0, width: screen.width, height: screen.height)
    }

    /// The part of the screen that windows use. The shell says where it is.
    private var windowArea: Rect {
        RootView.windowArea(screen: screenRect)
    }

    // MARK: - The layout

    /// The canvas that the layout fills, as the layout wants it.
    private var canvas: Frame {
        let area = windowArea
        return Frame(x: Double(area.x), y: Double(area.y),
                     width: Double(area.width), height: Double(area.height))
    }

    /// The windows from the front to the back. The layout puts the first one
    /// in the principal cell, so the front window is the principal.
    private var frontFirst: [Window] {
        windows.reversed()
    }

    /// One child of the layout, for a window that may not exist yet.
    private func subview(id: AnyHashable, minimum: (width: Double, height: Double)?,
                         content: Bitmap?) -> LayoutSubview {
        LayoutSubview(id: id) { proposal in
            WindowAnswer.size(minimum: minimum, content: content, to: proposal)
        }
    }

    private func subview(for window: Window) -> LayoutSubview {
        subview(id: ObjectIdentifier(window),
                minimum: window.surface.toplevel?.minSize,
                content: window.surface.content)
    }

    /// Runs the layout and gives every window its frame. A window whose size
    /// changed is asked for the new one, because the layout owns the size.
    private func arrange() {
        let ordered = frontFirst
        let frames = layoutKind.layout.frames(
            in: canvas, subviews: LayoutSubviews(ordered.map { subview(for: $0) }))
        for (window, frame) in zip(ordered, frames) {
            let rect = frame?.pixels
            window.frame = rect
            let title = window.surface.toplevel?.title ?? ""
            guard let rect else {
                log("WINDOW-IN-RAIL \"\(title)\"")
                continue
            }
            let asked = window.surface.toplevel?.configuredSize
            guard asked?.width != rect.width || asked?.height != rect.height else {
                log("WINDOW-KEPT \"\(title)\" \(rect.width)x\(rect.height)")
                continue
            }
            log("WINDOW-CONFIGURED \"\(title)\" \(rect.width)x\(rect.height)"
                + " was \(asked.map { "\($0.width)x\($0.height)" } ?? "new")")
            server.configure(window.surface, width: rect.width, height: rect.height,
                             activated: window === ordered.first)
        }
    }

    /// Where a window that is about to appear will go. The new window goes
    /// to the front, so the layout is run with it there.
    private func sizeForNewWindow(_ surface: Surface) -> Rect {
        var subviews = [subview(id: ObjectIdentifier(surface),
                                minimum: surface.toplevel?.minSize, content: nil)]
        subviews += frontFirst.map { subview(for: $0) }
        let frames = layoutKind.layout.frames(in: canvas, subviews: LayoutSubviews(subviews))
        // A window that the layout does not place still needs a size to draw
        // at, so it gets a tile.
        return (frames.first ?? nil)?.pixels
            ?? Rect(x: 0, y: 0, width: Int(WindowMetrics.tile), height: Int(WindowMetrics.tile))
    }

    /// "14:05" from the system clock, in local time.
    private static func clockText() -> String {
        var now = time_t(time(nil))
        var parts = tm()
        localtime_r(&now, &parts)
        func twoDigits(_ value: Int32) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(twoDigits(parts.tm_hour)):\(twoDigits(parts.tm_min))"
    }

    private func updateClock() {
        let text = Compositor.clockText()
        guard text != shell.clock else { return }
        shell.clock = text
        screen.setNeedsFrame()
    }

    // MARK: - Windows

    private func surfaceCommitted(_ surface: Surface) {
        if surface.isMapped, !windows.contains(where: { $0.surface === surface }),
           let content = surface.content {
            // The newest window goes to the front, and the layout then gives
            // every window a frame.
            windows.append(Window(surface: surface, frame: nil))
            arrange()
            updateFocus()
            let title = surface.toplevel?.title ?? ""
            let frame = windows.last?.frame
            let place = frame.map { "\($0.width)x\($0.height) at \($0.x),\($0.y)" } ?? "in the rail"
            log("WINDOW-MAPPED \"\(title)\" \(place) drew \(content.width)x\(content.height)")
        }
        screen.setNeedsFrame()
    }

    // MARK: - Input

    private func handle(_ event: Input.Event) {
        switch event {
        case .pointerMotion(let dx, let dy):
            movePointer(to: (pointer.x + dx, pointer.y + dy))
        case .pointerPosition(let x, let y):
            movePointer(to: (x * Double(screen.width), y * Double(screen.height)))
        case .button(let code, let pressed):
            // BTN_LEFT. The shell gets the click. An app gets nothing yet:
            // there is no input focus and no wl_seat.
            if code == 0x110 { host.pointerButton(pressed: pressed) }
        case .key(let key):
            // Ctrl+Alt+Backspace (XKB_KEY_BackSpace = 0xff08) quits. Every
            // other key goes to the window with the focus.
            if key.pressed, key.control, key.alt, key.keysym == 0xFF08 {
                running = false
            } else {
                server.send(key: key)
            }
        }
    }

    /// Starts an app, or brings its window to the front when it is open
    /// already. A dock icon does this.
    private func openApp(_ id: String) {
        if let index = windows.lastIndex(where: { $0.surface.toplevel?.appID == id }) {
            // The window goes to the front, which makes it the principal.
            // The layout must run again: the front window and the principal
            // cell are the same thing, so the keys and the large cell never
            // belong to two different windows.
            let window = windows.remove(at: index)
            windows.append(window)
            arrange()
            updateFocus()
            log("APP-RAISED \(id)")
            screen.setNeedsFrame()
            return
        }
        guard let bundle = apps.first(where: { $0.id == id }) else {
            log("compositor: no app with the id \(id)")
            return
        }
        AppCatalog.start(bundle)
    }

    /// The window in front gets the keys.
    private func updateFocus() {
        server.setKeyboardFocus(windows.last?.surface)
    }

    /// Asks the window in front to close. The app decides what it does.
    private func closeFrontWindow() {
        guard let window = windows.last else { return }
        window.surface.toplevel?.resource?.sendClose()
        server.flush()
        log("WINDOW-CLOSE-SENT \"\(window.surface.toplevel?.title ?? "")\"")
    }

    private func movePointer(to position: (x: Double, y: Double)) {
        pointer = (min(max(position.x, 0), Double(screen.width - 1)),
                   min(max(position.y, 0), Double(screen.height - 1)))
        // The shell views that watch the pointer hear it here. A view that
        // changes because of it asks for a frame itself.
        host.pointerMoved(to: pointer.x, y: pointer.y)
        screen.setNeedsFrame()
    }
}
