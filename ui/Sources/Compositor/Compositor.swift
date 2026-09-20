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
        /// Screen background, 0xRRGGBB. The desktop of the design.
        public var background: UInt32 = 0x07080A
        /// How many pixels there are to the point.
        ///
        /// The whole user interface works in points, so it is the same size
        /// on every screen. A screen with small pixels takes a scale of 2,
        /// and everything is then drawn with four times as many pixels.
        ///
        /// MYDISTRO_SCALE sets it. Without it the scale comes from the size
        /// of the screen in millimetres, when the display reports one that
        /// makes sense. A virtual display often reports none, and the scale
        /// is then 1.
        public var scale: Double?
        public init() {}
    }

    /// A mapped toplevel and where it is on screen.
    private final class Window {
        /// A name for the window that stays the same while it is open. The
        /// rail and Summon use it to say which window a person chose.
        let id: String
        let surface: Surface
        /// Where the layout put the window. A window with no frame waits in
        /// the rail: it stays open and keeps its state, and it is not drawn.
        var frame: Rect?
        /// The cell that the band holds for a window with no frame. The
        /// shell draws a stand-in there.
        var reservation: Rect?
        /// The whole cell that the layout gave the window. The shell draws
        /// the head in the top of it, and `frame` is what is left.
        var cell: Rect?
        /// When the window last committed a buffer, in milliseconds.
        var changed = monotonicMilliseconds()
        init(id: String, surface: Surface, frame: Rect?) {
            (self.id, self.surface, self.frame) = (id, surface, frame)
        }
    }

    private let options: Options
    private let seat: Seat
    private let drm: DRMDevice
    private let screen: any Screen
    private let input: Input
    /// Watches for a change of the display, so that the screen can follow it.
    private let display: DisplayMonitor?
    private let server: WaylandServer
    private let loop: EventLoop

    private var windows: [Window] = []   // back to front
    private var pointer: (x: Double, y: Double)
    private var running = true
    /// How the shell draws depth. It follows the renderer, because the two
    /// modes are for different costs, and MYDISTRO_SHELL_MODE overrides it.
    /// A test that compares the two renderers pins this, so that the only
    /// difference between the two pictures is the renderer.
    private let shellMode: RenderMode

    /// What the shell shows. The clock updates it every minute.
    private var shell = ShellState()
    /// Writes the screen to a file for the tests, when
    /// MYDISTRO_SCREENSHOT_SOCKET names a socket. Otherwise nil.
    private var screenshot: Screenshot?
    /// The shell's view tree: its `@State` values and the pointer.
    private let host = ViewHost()
    /// What the shell can ask the compositor to do.
    private var shellActions = ShellActions()
    /// The messages that wait to be read.
    private var notices: [Notice] = []
    /// The layout that owns the canvas. A window never floats: this is the
    /// only thing that gives a window a frame.
    private var layoutKind = WindowLayoutKind.principal
    /// Counts the windows that have been opened, to name each one.
    private var nextWindowID = 0
    /// The apps in /Applications. The dock shows one icon for each.
    private let apps: [AppBundle]
    /// The same apps, as the shell gets them. They do not change, so the
    /// compositor makes them once and not for each frame.
    private let appEntries: [AppEntry]

    /// How many pixels there are to the point. See Options.scale.
    private var scale: Double = 1

    public var socketName: String { server.socketName }
    public var screenSize: (width: Int, height: Int) { (screen.width, screen.height) }
    /// The size of the screen in points: what the user interface works in.
    public var screenPoints: (width: Int, height: Int) {
        (screenRect.width, screenRect.height)
    }

    public init(options: Options = Options()) throws {
        self.options = options
        debug("opening seat")
        seat = try Seat()
        debug("seat \(seat.name) active; opening display")
        drm = try Compositor.openDisplayDevice(seat: seat)
        screen = try makeScreen(device: drm)
        scale = Compositor.chosenScale(options: options, screen: screen)
        shellMode = Compositor.chosenShellMode(usesGPU: screen.usesGPU)
        debug("screen \(drm.path) \(screen.output) scale \(scale); starting input")
        input = try Input(seat: seat)
        debug("input ready; starting Wayland server")
        loop = try EventLoop()
        display = DisplayMonitor()
        if display == nil { log("compositor: no display monitor; the screen keeps its size") }
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
        if let display, display.fd >= 0 {
            display.changed = { [unowned self] in screen.displayChanged() }
            loop.watch(fd: display.fd) { [unowned self] in display.dispatch() }
        }
        try loop.onSignal(SIGINT) { [unowned self] in running = false }
        try loop.onSignal(SIGTERM) { [unowned self] in running = false }

        screen.displayList = { [unowned self] in displayList() }
        screen.sizeChanged = { [unowned self] in screenSizeChanged() }
        screen.frameShown = { [unowned self] in
            let now = monotonicMilliseconds()
            for window in windows { window.surface.sendFrameDone(time: now) }
        }
        input.handler = { [unowned self] event in handle(event) }
        host.needsUpdate = { [unowned self] in screen.setNeedsFrame() }
        shellActions = ShellActions(
            openApp: { [unowned self] id in openApp(id) },
            closeFrontWindow: { [unowned self] in closeFrontWindow() },
            raiseWindow: { [unowned self] id in raiseWindow(id) },
            toggleSummon: { [unowned self] in
                shell.summonIsOpen.toggle()
                screen.setNeedsFrame()
            },
            nextLayout: { [unowned self] in
                let all = WindowLayoutKind.allCases
                let next = (all.firstIndex(of: layoutKind).map { $0 + 1 } ?? 0) % all.count
                setLayout(all[next])
            },
            setLayout: { [unowned self] kind in setLayout(kind) },
            closeWindow: { [unowned self] id in closeWindow(id) },
            makeWidget: { [unowned self] id in makeWidget(id) },
            dismissNotice: { [unowned self] id in
                notices.removeAll { $0.id == id }
                screen.setNeedsFrame()
            }
        )
        shell.clock = Compositor.clockText()
        // The clock changes once a minute. A one-second timer keeps it right
        // without a frame between minutes.
        try loop.onTimer(milliseconds: 1000) { [unowned self] in updateClock() }
        server.keymap = input.keymapText
        server.screenChanged(to: screenInfo)
        server.sizeForNewWindow = { [unowned self] surface in sizeForNewWindow(surface) }
        server.surfaceCommitted = { [unowned self] surface in surfaceCommitted(surface) }
        server.surfaceDestroyed = { [unowned self] surface in
            windows.removeAll { $0.surface === surface }
            arrange()
            updateFocus()
            screen.setNeedsFrame()
        }
        if let path = getenv("MYDISTRO_SCREENSHOT_SOCKET").map({ String(cString: $0) }) {
            screenshot = Screenshot(path: path, loop: loop, screen: screen)
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
        // desktop is always opaque. This one rectangle is in pixels, because
        // it covers the whole screen whatever the scale is.
        var list: DisplayList = [.fill(Rect(x: 0, y: 0, width: screen.width, height: screen.height),
                                       color: options.background | 0xFF00_0000)]
        for window in windows {
            guard let points = window.frame, let content = window.surface.content else { continue }
            // The frame is in points and the buffer is in pixels, because an
            // app draws at the scale of the screen. The frame is the
            // layout's, not the app's: an app that drew a larger buffer is
            // cut to its frame, and a smaller one sits in the middle of it.
            let frame = Compositor.inPixels(points, scale: scale)
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
        state.mode = shellMode
        state.layout = layoutKind
        state.windows = windowEntries
        state.standIns = standIns
        state.heads = heads
        state.notices = notices
        state.canvas = windowArea
        // The time of this frame. Everything that moves reads it, so things
        // that start together stay together.
        host.now = Double(monotonicMilliseconds()) / 1000
        list += host.displayList(for: RootView(state: state, actions: shellActions),
                                 in: screenRect, scale: scale)
        // The pointer is kept in pixels, because that is what the mouse and
        // the screen work in.
        list.append(.bitmap(Cursor.bitmap(scale: Int(scale.rounded())),
                            x: Int(pointer.x), y: Int(pointer.y)))
        return list
    }

    /// A rectangle of points, as pixels.
    private static func inPixels(_ rect: Rect, scale: Double) -> Rect {
        guard scale != 1 else { return rect }
        let left = Int((Double(rect.x) * scale).rounded())
        let top = Int((Double(rect.y) * scale).rounded())
        return Rect(x: left, y: top,
                    width: Int((Double(rect.x + rect.width) * scale).rounded()) - left,
                    height: Int((Double(rect.y + rect.height) * scale).rounded()) - top)
    }

    /// The screen in points. Every layout works in this space.
    private var screenRect: Rect {
        Rect(x: 0, y: 0,
             width: Int((Double(screen.width) / scale).rounded(.down)),
             height: Int((Double(screen.height) / scale).rounded(.down)))
    }

    /// How many pixels there are to the point.
    ///
    /// The setting wins. Without it, the size of the screen in millimetres
    /// gives the density, and a dense screen takes a scale of 2. A display
    /// that reports no size at all, as a virtual one often does, keeps 1.
    /// The mode of the shell: the renderer chooses, and
    /// MYDISTRO_SHELL_MODE overrides.
    private static func chosenShellMode(usesGPU: Bool) -> RenderMode {
        guard let text = getenv("MYDISTRO_SHELL_MODE").map({ String(cString: $0) }),
              !text.isEmpty else {
            return usesGPU ? .gpu : .cpu
        }
        guard let mode = RenderMode(rawValue: text) else {
            log("compositor: MYDISTRO_SHELL_MODE must be 'cpu' or 'gpu', not '\(text)'")
            return usesGPU ? .gpu : .cpu
        }
        return mode
    }

    private static func chosenScale(options: Options, screen: Screen) -> Double {
        if let scale = options.scale, scale > 0 { return scale }
        if let text = getenv("MYDISTRO_SCALE").map({ String(cString: $0) }),
           let scale = Double(text), scale > 0 {
            return scale
        }
        guard let millimetres = screen.widthInMillimetres, millimetres > 0 else { return 1 }
        let perInch = Double(screen.width) / (Double(millimetres) / 25.4)
        return perInch >= 180 ? 2 : 1
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
        let subviews = LayoutSubviews(ordered.map { subview(for: $0) })
        let frames = layoutKind.layout.frames(in: canvas, subviews: subviews)
        for (window, subview) in zip(ordered, subviews) {
            window.reservation = subview.reservation?.pixels
        }
        for (window, frame) in zip(ordered, frames) {
            let cell = frame?.pixels
            window.cell = cell
            // The shell keeps the head of a cell for itself, so the window
            // gets what is left of it. A tile has no head: the app draws the
            // whole tile, with its own name in it.
            let rect = cell.map {
                WindowChrome.content(of: $0, sizeClass: SizeClass.of(Proposal(
                    width: Double($0.width), height: Double($0.height))))
            }
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

    /// The screen took a new size. Every window gets a frame of the new
    /// canvas, and the pointer stays on the screen.
    /// What the apps are told about the screen.
    private var screenInfo: WaylandServer.ScreenInfo {
        WaylandServer.ScreenInfo(
            width: screen.width, height: screen.height,
            refreshRate: screen.output.mode.refreshRate,
            scale: Int(scale.rounded()),
            widthInMillimetres: screen.output.widthInMillimetres,
            heightInMillimetres: screen.output.heightInMillimetres)
    }

    private func screenSizeChanged() {
        pointer.x = min(pointer.x, Double(max(0, screen.width - 1)))
        pointer.y = min(pointer.y, Double(max(0, screen.height - 1)))
        host.pointerMoved(to: pointer.x / scale, y: pointer.y / scale)
        server.screenChanged(to: screenInfo)
        arrange()
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
        let cell = (frames.first ?? nil)?.pixels
            ?? Rect(x: 0, y: 0, width: Int(WindowMetrics.tile), height: Int(WindowMetrics.tile))
        // The shell keeps the head of the cell, so the first configure asks
        // for the size that the window really draws. Without this the window
        // draws the whole cell once and then has to draw again.
        return WindowChrome.content(of: cell, sizeClass: SizeClass.of(Proposal(
            width: Double(cell.width), height: Double(cell.height))))
    }

    /// The time from the system clock, in local time. The rail stacks the
    /// hour over the minute over the day.
    private static func clockText() -> Clock {
        var now = time_t(time(nil))
        var parts = tm()
        localtime_r(&now, &parts)
        func twoDigits(_ value: Int32) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        let days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        let day = days.indices.contains(Int(parts.tm_wday)) ? days[Int(parts.tm_wday)] : ""
        return Clock(hour: twoDigits(parts.tm_hour), minute: twoDigits(parts.tm_min),
                     weekday: day)
    }

    private func updateClock() {
        let text = Compositor.clockText()
        guard text != shell.clock else { return }
        shell.clock = text
        screen.setNeedsFrame()
    }

    /// The open windows as the rail shows them, front first, so that the
    /// track reads in the same order as the canvas.
    private var windowEntries: [WindowEntry] {
        let front = frontFirst
        return front.enumerated().map { index, window in
            let place: WindowEntry.Place = if window.frame == nil {
                .rail
            } else if index == 0 {
                .principal
            } else {
                .widget
            }
            return WindowEntry(id: window.id,
                               title: window.surface.toplevel?.title ?? "",
                               appID: window.surface.toplevel?.appID ?? "",
                               place: place,
                               hasFocus: window === front.first)
        }
    }

    /// The bar that the shell draws over each window with room for one.
    private var heads: [WindowHead] {
        let front = frontFirst
        return front.compactMap { window -> WindowHead? in
            guard let cell = window.cell else { return nil }
            let sizeClass = SizeClass.of(Proposal(width: Double(cell.width),
                                                  height: Double(cell.height)))
            guard sizeClass != .widget else { return nil }
            let toplevel = window.surface.toplevel
            let app = apps.first { $0.id == toplevel?.appID }
            return WindowHead(id: window.id,
                              appName: app?.name ?? toplevel?.appID ?? "A window",
                              mark: app?.entry.color ?? Color(hex: 0x6C777D),
                              title: toplevel?.title ?? "",
                              sizeClass: sizeClass,
                              hasFocus: window === front.first,
                              cell: cell)
        }
    }

    /// The cards that the shell draws in the cells that windows cannot use.
    private var standIns: [StandIn] {
        let now = monotonicMilliseconds()
        return frontFirst.compactMap { window -> StandIn? in
            guard let cell = window.reservation else { return nil }
            let toplevel = window.surface.toplevel
            let app = apps.first { $0.id == toplevel?.appID }
            let answer = WindowAnswer.size(minimum: toplevel?.minSize,
                                           content: window.surface.content,
                                           to: Proposal(width: WindowMetrics.tile, height: nil))
            let minimum = toplevel?.minSize != nil ? "at least " : ""
            let drew = window.surface.content.map { "\($0.width) × \($0.height)" } ?? "nothing yet"
            return StandIn(
                id: window.id,
                appName: app?.name ?? toplevel?.appID ?? "A window",
                mark: app?.entry.color ?? Color(hex: 0x6C777D),
                title: toplevel?.title ?? "",
                answered: "\(minimum)\(Int(answer.width)) × \(Int(answer.height))",
                drew: drew,
                changed: Compositor.ago(milliseconds: now - window.changed),
                frame: cell)
        }
    }

    /// How long ago something happened, in a few characters.
    private static func ago(milliseconds: UInt32) -> String {
        let seconds = Int(milliseconds / 1000)
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }

    /// Puts a window in front, which makes it the principal.
    private func raiseWindow(_ id: String) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let window = windows.remove(at: index)
        windows.append(window)
        arrange()
        updateFocus()
        screen.setNeedsFrame()
    }

    /// Says something to the person at the screen. The same message twice
    /// replaces the first one, so a button that fails does not fill the
    /// screen with cards.
    private func post(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
        notices.append(notice)
        log("NOTICE \(notice.kind) \"\(notice.title)\"")
        screen.setNeedsFrame()
    }

    /// Asks one window to close. The app decides what it does with that.
    private func closeWindow(_ id: String) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        window.surface.toplevel?.resource?.sendClose()
        log("WINDOW-CLOSE-SENT \"\(window.surface.toplevel?.title ?? "")\"")
    }

    /// Takes a window out of the large cell. The window under it becomes the
    /// principal, and this one becomes a tile.
    private func makeWidget(_ id: String) {
        guard windows.count > 1, windows.last?.id == id else { return }
        windows.swapAt(windows.count - 1, windows.count - 2)
        arrange()
        updateFocus()
        log("WINDOW-TO-WIDGET \"\(windows.first { $0.id == id }?.surface.toplevel?.title ?? "")\"")
        screen.setNeedsFrame()
    }

    /// Gives the canvas to one layout.
    private func setLayout(_ kind: WindowLayoutKind) {
        guard kind != layoutKind else { return }
        layoutKind = kind
        log("LAYOUT \(kind.rawValue)")
        arrange()
        screen.setNeedsFrame()
    }

    // MARK: - Windows

    private func surfaceCommitted(_ surface: Surface) {
        // A window that waits in the rail shows how long ago it last drew.
        if let window = windows.first(where: { $0.surface === surface }) {
            window.changed = monotonicMilliseconds()
        }
        if surface.isMapped, !windows.contains(where: { $0.surface === surface }),
           let content = surface.content {
            // The newest window goes to the front, and the layout then gives
            // every window a frame.
            nextWindowID += 1
            windows.append(Window(id: "w\(nextWindowID)", surface: surface, frame: nil))
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
            // Ctrl+Alt+Backspace (XKB_KEY_BackSpace = 0xff08) quits.
            if key.pressed, key.control, key.alt, key.keysym == 0xFF08 {
                running = false
                return
            }
            // The Super key opens Summon and closes it again.
            if key.pressed, key.keysym == Keysym.superLeft || key.keysym == Keysym.superRight {
                shell.summonIsOpen.toggle()
                screen.setNeedsFrame()
                return
            }
            // The shell reads the key first. A surface of the shell that is
            // in front, such as Summon, takes it. A key that no view of the
            // shell used goes to the app that has the focus.
            if host.key(KeyEvent(
                keysym: key.keysym,
                characters: Keysym.character(of: key.keysym).map(String.init) ?? "",
                isPressed: key.pressed, control: key.control, alt: key.alt)) {
                screen.setNeedsFrame()
                return
            }
            server.send(key: key)
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
            post(Notice(id: "start:\(id)", kind: .failure, source: "mydistro",
                        title: "No app has the name \(id)",
                        detail: "Its bundle is not in \(AppCatalog.directory)."))
            return
        }
        guard AppCatalog.start(bundle) != nil else {
            post(Notice(id: "start:\(id)", kind: .failure, source: bundle.name,
                        title: "\(bundle.name) did not start",
                        detail: "The system could not run \(bundle.command)."))
            return
        }
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
        host.pointerMoved(to: pointer.x / scale, y: pointer.y / scale)
        screen.setNeedsFrame()
    }
}
