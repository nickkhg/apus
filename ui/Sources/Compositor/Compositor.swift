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
        /// APUS_SCALE sets it. Without it the scale comes from the size
        /// of the screen in millimetres, when the display reports one that
        /// makes sense. A virtual display often reports none, and the scale
        /// is then 1.
        public var scale: Double?
        public init() {}
    }

    /// An app that was asked to start.
    private final class PendingLaunch {
        let id: String
        let bundle: AppBundle
        /// When the app was asked to start, in milliseconds.
        var startedAt: UInt32
        /// Why it did not start, once the shell has given up on it.
        var failure: String?
        /// The cell that the layout gave it.
        var frame: Rect?

        init(id: String, bundle: AppBundle) {
            self.id = id
            self.bundle = bundle
            startedAt = monotonicMilliseconds()
        }
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
        /// The length of a tile that a person gave the window with a resize.
        /// The window answers it when the layout leaves a side free.
        var preferredLength: Double?
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
    /// The buttons of the pointer that are down now.
    private var buttonsDown: Set<UInt32> = []

    /// What holds the pointer while a button is down.
    private enum Grab {
        /// A press on the window of an app. The app keeps the pointer until
        /// the last button comes up, wherever the pointer goes, so that a
        /// drag that leaves the window still reaches it. Wayland calls this
        /// the implicit grab.
        case window(Window)
        /// A press on the chrome of the shell.
        case shell
        /// A move. The window follows the pointer, and it takes the cell
        /// under the pointer when the button comes up.
        case move(Window, from: (x: Double, y: Double))
        /// A resize. `start` is the length that the edge had at the press:
        /// the width of the first window side by side, or the length of a
        /// tile.
        case resize(Window, WindowResize, from: (x: Double, y: Double), start: Double)

        var window: Window? {
            switch self {
            case .window(let window), .move(let window, _), .resize(let window, _, _, _): window
            case .shell: nil
            }
        }
    }
    private var grab: Grab?
    /// The window that a press will bring into the large cell once the
    /// button comes up. A window that moved at the press would leave the
    /// pointer while the button holds it, so it moves at the release.
    private var raiseOnRelease: Window?
    /// Where the edge between two windows side by side is. A resize moves
    /// it, and it stays there until the next one.
    private var split = SideBySide.even
    /// The window that a person gave the keys, in a layout where the keys do
    /// not follow the first place. See `focusedWindow`.
    private weak var chosenFocus: Window?
    /// The window that heard last that it has the keys.
    private weak var announcedFocus: Window?
    private var running = true
    /// How the shell draws depth. It follows the renderer, because the two
    /// modes are for different costs, and APUS_SHELL_MODE overrides it.
    /// A test that compares the two renderers pins this, so that the only
    /// difference between the two pictures is the renderer.
    private let shellMode: RenderMode

    /// What the shell shows. The clock updates it every minute.
    private var shell = ShellState()
    /// Writes the screen to a file for the tests, when
    /// APUS_SCREENSHOT_SOCKET names a socket. Otherwise nil.
    private var screenshot: Screenshot?
    /// Carries the clipboard to and from the machine that runs the VM.
    private var hostClipboard: HostClipboard!

    /// The shell's view tree: its `@State` values and the pointer.
    private let host = ViewHost()
    /// What the shell can ask the compositor to do.
    private var shellActions = ShellActions()
    /// The messages that wait to be read.
    private var notices: [Notice] = []
    /// The apps between the moment a person chose them and the moment their
    /// window appears. A launch holds a cell, so that a person sees the app
    /// in the place where it will be.
    private var launches: [PendingLaunch] = []
    /// Counts the launches, to name each one.
    private var nextLaunchID = 0
    /// How long an app has to open a window before the shell says that it
    /// did not start, in milliseconds.
    private static let launchLimit: UInt32 = 10_000
    /// The layout that owns the canvas. A window never floats: this is the
    /// only thing that gives a window a frame.
    private var layoutKind = WindowLayoutKind.principal
    /// Counts the windows that have been opened, to name each one.
    private var nextWindowID = 0
    /// The apps in /Applications. The dock shows one icon for each.
    private var apps: [AppBundle]
    /// The same apps, as the shell gets them. They do not change, so the
    /// compositor makes them once and not for each frame.
    private var appEntries: [AppEntry]

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
        // An app that the dock starts connects to this compositor. The
        // compositor does not wait for the child, so the kernel removes the
        // child when it ends.
        setenv("WAYLAND_DISPLAY", server.socketName, 1)
        setSessionEnvironment()
        signal(SIGCHLD, SIG_IGN)

        // The clipboard of the apps and the clipboard of the Mac are the
        // same clipboard. On real hardware there is no Mac and no socket,
        // and the apps go on sharing a clipboard between themselves.
        hostClipboard = HostClipboard(loop: loop)
        server.clipboard.textChanged = { [unowned self] text in hostClipboard.send(text) }
        hostClipboard.received = { [unowned self] text in server.clipboard.setHostText(text) }

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
            },
            retryLaunch: { [unowned self] id in
                guard let launch = launches.first(where: { $0.id == id }) else { return }
                launches.removeAll { $0.id == id }
                startLaunch(of: launch.bundle)
            },
            dismissLaunch: { [unowned self] id in
                launches.removeAll { $0.id == id }
                arrange()
                screen.setNeedsFrame()
            }
        )
        shell.clock = Compositor.clockText()
        // The clock changes once a minute. A one-second timer keeps it right
        // without a frame between minutes.
        try loop.onTimer(milliseconds: 1000) { [unowned self] in
            updateClock()
            checkLaunches()
        }
        server.keymap = input.keymapText
        server.screenChanged(to: screenInfo)
        server.sizeForNewWindow = { [unowned self] surface in sizeForNewWindow(surface) }
        server.surfaceCommitted = { [unowned self] surface in surfaceCommitted(surface) }
        server.moveRequested = { [unowned self] surface in startMove(of: surface) }
        server.resizeRequested = { [unowned self] surface, edges in
            startResize(of: surface, edges: WindowEdges(rawValue: edges))
        }
        server.surfaceDestroyed = { [unowned self] surface in
            if grab?.window?.surface === surface {
                // The window went away under the pointer. The shell has the
                // pointer until the buttons come up.
                grab = .shell
                server.pressEnded()
            }
            if raiseOnRelease?.surface === surface { raiseOnRelease = nil }
            windows.removeAll { $0.surface === surface }
            arrange()
            updateFocus()
            screen.setNeedsFrame()
        }
        if let path = getenv("APUS_SCREENSHOT_SOCKET").map({ String(cString: $0) }) {
            screenshot = Screenshot(path: path, loop: loop, screen: screen)
        }
        usePointer()
        screen.setNeedsFrame()
    }

    /// Runs until SIGINT/SIGTERM or Ctrl+Alt+Backspace, then gives the
    /// screen back.
    public func run() {
        while running {
            // Everything that arrived together is in one frame: the events of
            // a pass all run before this, so a frame holds the newest pointer
            // position and not the first of the batch. Drawing from inside an
            // event would hold the loop for the whole of a frame, and the
            // input behind it would arrive late.
            screen.drawIfNeeded()
            server.flush()
            loop.dispatch()
        }
        screen.release()
    }

    /// The DRM card to draw on: the one that carries a GPU, or the first
    /// one with a connected output.
    ///
    /// APUS_DRM_DEVICE names one card instead. A machine can have more than
    /// one: a virtual machine on a Mac has the display of the framework,
    /// which is a 2D scanout and nothing else, beside the device that
    /// carries the GPU of the Mac. Both have an output, and the first of
    /// them is the one with no GPU, so a search that stops at the first
    /// takes the slow one. A frame of the shell costs 10.2 ms on the device
    /// with the GPU and 24.5 ms on the other, and the window of apus-vm
    /// shows the device with the GPU.
    ///
    /// A machine with one real GPU has one card, and it answers that it
    /// carries a GPU or it does not; either way it is the one that is left.
    private static func openDisplayDevice(seat: Seat) throws -> DRMDevice {
        if let name = getenv("APUS_DRM_DEVICE") {
            let path = String(cString: name)
            guard let fd = try? seat.openDevice(path) else {
                throw DRMError.open(path: path, errno: errno)
            }
            return DRMDevice(fd: fd, path: path)
        }
        var first: DRMDevice?
        for index in 0..<8 {
            let path = "/dev/dri/card\(index)"
            guard access(path, F_OK) == 0, let fd = try? seat.openDevice(path) else { continue }
            let device = DRMDevice(fd: fd, path: path)
            guard let outputs = try? device.connectedOutputs(), !outputs.isEmpty else {
                seat.closeDevice(fd)
                continue
            }
            if device.carriesGPU {
                if let first { seat.closeDevice(first.fd) }
                log("SCREEN-DEVICE \(path) carries a GPU")
                return device
            }
            if first == nil { first = device } else { seat.closeDevice(fd) }
        }
        guard let first else { throw DRMError.noDevice }
        log("SCREEN-DEVICE \(first.path) has no GPU of its own")
        return first
    }

    // MARK: - Drawing

    private func displayList() -> DisplayList {
        // The option is 0xRRGGBB. The renderer wants an alpha byte, and the
        // desktop is always opaque. This one rectangle is in pixels, because
        // it covers the whole screen whatever the scale is.
        var list: DisplayList = [.fill(Rect(x: 0, y: 0, width: screen.width, height: screen.height),
                                       color: options.background | 0xFF00_0000)]
        var moving: (Window, Rect)?
        for window in windows {
            guard let points = window.frame else { continue }
            if case .move(let held, let from) = grab, held === window {
                // A window that a person moves follows the pointer, over
                // everything else, until the button comes up.
                let point = pointerPoints
                moving = (window, Rect(x: points.x + Int((point.x - from.x).rounded()),
                                       y: points.y + Int((point.y - from.y).rounded()),
                                       width: points.width, height: points.height))
                continue
            }
            append(window, in: points, to: &list)
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
        state.launches = launchCards
        state.canvas = windowArea
        // The time of this frame. Everything that moves reads it, so things
        // that start together stay together.
        host.now = Double(monotonicMilliseconds()) / 1000
        list += host.displayList(for: RootView(state: state, actions: shellActions),
                                 in: screenRect, scale: scale)
        if let moving { append(moving.0, in: moving.1, to: &list) }
        // The pointer is kept in pixels, because that is what the mouse and
        // the screen work in. A display with a plane for it draws it itself,
        // and then it is not in the frame at all: moving the mouse over an
        // empty desktop costs no frame.
        if !screen.drawsPointer {
            list.append(.bitmap(Cursor.bitmap(scale: Int(scale.rounded())),
                                x: Int(pointer.x), y: Int(pointer.y)))
        }
        return list
    }

    /// The content of a window, in a frame of points.
    private func append(_ window: Window, in points: Rect, to list: inout DisplayList) {
        guard let content = window.surface.content else { return }
        // The frame is in points and the buffer is in pixels, because an
        // app draws at the scale of the screen. The frame is the layout's,
        // not the app's: an app that drew a larger buffer is cut to its
        // frame, and a smaller one sits in the middle of it.
        let frame = Compositor.inPixels(points, scale: scale)
        let x = frame.x + max(0, (frame.width - content.width) / 2)
        let y = frame.y + max(0, (frame.height - content.height) / 2)
        list.append(.pushClip(frame))
        list.append(.bitmap(content, x: x, y: y))
        list.append(.popClip)
    }

    /// Where the pointer is, in points.
    private var pointerPoints: (x: Double, y: Double) {
        (pointer.x / scale, pointer.y / scale)
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
    /// APUS_SHELL_MODE overrides.
    private static func chosenShellMode(usesGPU: Bool) -> RenderMode {
        guard let text = getenv("APUS_SHELL_MODE").map({ String(cString: $0) }),
              !text.isEmpty else {
            return usesGPU ? .gpu : .cpu
        }
        guard let mode = RenderMode(rawValue: text) else {
            log("compositor: APUS_SHELL_MODE must be 'cpu' or 'gpu', not '\(text)'")
            return usesGPU ? .gpu : .cpu
        }
        return mode
    }

    private static func chosenScale(options: Options, screen: Screen) -> Double {
        if let scale = options.scale, scale > 0 { return scale }
        if let text = getenv("APUS_SCALE").map({ String(cString: $0) }),
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
                         preferred: Double? = nil, content: Bitmap?) -> LayoutSubview {
        LayoutSubview(id: id) { proposal in
            WindowAnswer.size(minimum: minimum, preferred: preferred, content: content,
                              to: proposal)
        }
    }

    private func subview(for window: Window) -> LayoutSubview {
        subview(id: ObjectIdentifier(window),
                minimum: window.surface.toplevel?.minSize,
                preferred: window.preferredLength,
                content: window.surface.content)
    }

    /// The layout that owns the canvas, with the edge that a person moved.
    private var layout: AnyLayout { layoutKind.layout(split: split) }

    /// The window that has the keys.
    ///
    /// In the principal layout it is the window in the large cell, and in
    /// Full the one window that shows. Side by side and in the grid the
    /// cells have one rank, so a click gives a window the keys and moves
    /// nothing: the keys stay with the window that a person chose, while it
    /// has a cell.
    private var focusedWindow: Window? {
        if !layoutKind.keysFollowFirstPlace, let chosen = chosenFocus, chosen.frame != nil,
           windows.contains(where: { $0 === chosen }) {
            return chosen
        }
        return windows.last
    }

    /// Runs the layout and gives every window its frame. A window whose size
    /// changed is asked for the new one, because the layout owns the size.
    private func arrange() {
        // A launch is a cell of its own until its window comes. The newest
        // launch is first, so it takes the large cell as a new window does.
        let starting = launches.reversed().map { $0 }
        let ordered = frontFirst
        let subviews = LayoutSubviews(
            starting.map { launch in
                LayoutSubview(id: launch.id) { proposal in
                    WindowAnswer.size(minimum: nil, content: nil, to: proposal)
                }
            } + ordered.map { subview(for: $0) })
        let frames = layout.frames(in: canvas, subviews: subviews)
        for (launch, frame) in zip(starting, frames) {
            launch.frame = frame?.pixels
        }
        let windowFrames = Array(frames.dropFirst(starting.count))
        let windowSubviews = Array(subviews.dropFirst(starting.count))
        for (window, subview) in zip(ordered, windowSubviews) {
            window.reservation = subview.reservation?.pixels
        }
        for (window, frame) in zip(ordered, windowFrames) {
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
        }
        // The states come after the frames, because which window has the
        // keys depends on which windows have a cell.
        let focused = focusedWindow
        var resizing: Window?
        if case .resize(let window, _, _, _) = grab { resizing = window }
        for window in ordered {
            let title = window.surface.toplevel?.title ?? ""
            guard let rect = window.frame else {
                log("WINDOW-IN-RAIL \"\(title)\"")
                continue
            }
            let states = WindowStates(activated: window === focused,
                                      resizing: window === resizing)
            let asked = window.surface.toplevel?.configuredSize
            let sameSize = asked?.width == rect.width && asked?.height == rect.height
            if sameSize {
                guard window.surface.toplevel?.configuredStates != states else {
                    log("WINDOW-KEPT \"\(title)\" \(rect.width)x\(rect.height)")
                    continue
                }
                log("WINDOW-STATE \"\(title)\" \(rect.width)x\(rect.height)"
                    + (states.activated ? " activated" : "")
                    + (states.resizing ? " resizing" : ""))
            } else {
                log("WINDOW-CONFIGURED \"\(title)\" \(rect.width)x\(rect.height)"
                    + " was \(asked.map { "\($0.width)x\($0.height)" } ?? "new")"
                    + (states.resizing ? " resizing" : ""))
            }
            server.configure(window.surface, width: rect.width, height: rect.height,
                             states: states)
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
        usePointer()
        server.screenChanged(to: screenInfo)
        arrange()
    }

    /// Gives the display the picture of the pointer, at the scale in use. A
    /// display that takes it draws the pointer from then on.
    private func usePointer() {
        screen.usePointer(Cursor.bitmap(scale: Int(scale.rounded())))
        screen.movePointer(toX: Int(pointer.x), y: Int(pointer.y))
    }

    /// Where a window that is about to appear will go. The new window goes
    /// to the front, so the layout is run with it there.
    private func sizeForNewWindow(_ surface: Surface) -> Rect {
        var subviews = [subview(id: ObjectIdentifier(surface),
                                minimum: surface.toplevel?.minSize, content: nil)]
        subviews += frontFirst.map { subview(for: $0) }
        let frames = layout.frames(in: canvas, subviews: LayoutSubviews(subviews))
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
        // Settings changes the zone by giving /etc/localtime a new link.
        // tzset reads it again when it changed; localtime_r alone keeps the
        // zone that the compositor started with.
        tzset()
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
                               hasFocus: window === focusedWindow)
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
                              hasFocus: window === focusedWindow,
                              cell: cell)
        }
    }

    /// The cells of the apps that are starting, and of the ones that did not.
    private var launchCards: [Launch] {
        launches.reversed().compactMap { launch -> Launch? in
            guard let frame = launch.frame else { return nil }
            return Launch(id: launch.id,
                          appName: launch.bundle.name,
                          mark: launch.bundle.entry.color,
                          command: launch.bundle.command,
                          state: launch.failure.map { Launch.State.failed($0) } ?? .starting,
                          frame: frame)
        }
    }

    /// Asks an app to start and keeps a cell for it. An app that is already
    /// starting is not started again.
    private func startLaunch(of bundle: AppBundle) {
        guard !launches.contains(where: { $0.bundle.id == bundle.id }) else { return }
        nextLaunchID += 1
        let launch = PendingLaunch(id: "l\(nextLaunchID)", bundle: bundle)
        if AppCatalog.start(bundle) == nil {
            launch.failure = "The system could not run the program of the bundle."
        }
        launches.append(launch)
        arrange()
        screen.setNeedsFrame()
    }

    /// An app that has taken too long has not started. The one-second timer
    /// of the clock looks for these.
    private func checkLaunches() {
        let now = monotonicMilliseconds()
        var changed = false
        for launch in launches where launch.failure == nil {
            guard now &- launch.startedAt > Compositor.launchLimit else { continue }
            launch.failure = "It ran, and it opened no window."
            log("APP-DID-NOT-START \(launch.bundle.id)")
            changed = true
        }
        if changed { screen.setNeedsFrame() }
    }

    /// The window of an app arrived, so its launch is over.
    private func endLaunch(ofApp appID: String) {
        guard launches.contains(where: { $0.bundle.id == appID }) else { return }
        launches.removeAll { $0.bundle.id == appID }
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

    /// Tells the apps that they are on Wayland.
    ///
    /// A toolkit that can draw on more than one kind of display server picks
    /// one when it starts, and most of them still pick X11 first. Each reads
    /// an environment variable of its own to be told otherwise, and a
    /// session sets them all: that is how a program that knows nothing about
    /// Apus comes up on it without being told anything about it.
    ///
    /// Apus has no X server at all, so there is nothing to fall back to and
    /// nothing to weigh up. A toolkit that is not listed here, or one that
    /// takes a command line option rather than a variable, needs a desktop
    /// entry of its own in `~/.local/share/applications`, which wins over
    /// the one that the package installed. That entry can put `env` in
    /// front of the program to change one of these for one app.
    ///
    /// Each of them is set over whatever was there. systemd starts the shell
    /// as a service on tty1 and sets `XDG_SESSION_TYPE=tty`, which says how
    /// the compositor was started and not what it offers the apps it starts.
    /// Leaving that in place is how an app ends up looking for an X server.
    private func setSessionEnvironment() {
        let session = [
            // What kind of session this is. Chromium and others read it.
            "XDG_SESSION_TYPE": "wayland",
            "XDG_CURRENT_DESKTOP": "Apus",
            "GDK_BACKEND": "wayland",                   // GTK 3 and GTK 4
            "QT_QPA_PLATFORM": "wayland",               // Qt 5 and Qt 6
            "SDL_VIDEODRIVER": "wayland",               // SDL 2 and SDL 3
            "CLUTTER_BACKEND": "wayland",
            "MOZ_ENABLE_WAYLAND": "1",                  // Firefox
            "ELECTRON_OZONE_PLATFORM_HINT": "auto",     // apps built on Electron
        ]
        for (name, value) in session { setenv(name, value, 1) }
    }

    /// Reads the apps of the machine again: the bundles of /Applications and
    /// the desktop entries of the packages that are installed.
    private func readApps() {
        apps = AppCatalog.bundles()
        appEntries = apps.map(\.entry)
    }

    /// Puts a window in front, which makes it the principal.
    private func raiseWindow(_ id: String) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let window = windows.remove(at: index)
        windows.append(window)
        chosenFocus = window
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
        // A layout where the keys follow the first place puts the window
        // that has them there, so that the window a person was typing into
        // keeps the keys and takes the large cell.
        if kind.keysFollowFirstPlace, let focused = focusedWindow, focused !== windows.last,
           let index = windows.firstIndex(where: { $0 === focused }) {
            windows.append(windows.remove(at: index))
        }
        layoutKind = kind
        log("LAYOUT \(kind.rawValue)")
        arrange()
        updateFocus()
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
            let window = Window(id: "w\(nextWindowID)", surface: surface, frame: nil)
            windows.append(window)
            chosenFocus = window
            // The app opened its window, so its launch is over and the cell
            // that held its place goes back to the layout.
            endLaunch(ofApp: surface.toplevel?.appID ?? "")
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
            handleButton(code, pressed: pressed)
        case .scroll(let dx, let dy, let source):
            // A scroll goes where the pointer is, as a button does. The
            // shell has nothing that scrolls yet, so a scroll over its own
            // chrome goes nowhere.
            guard windowUnderPointer != nil else { break }
            server.sendPointer(scrollDX: dx, dy: dy, fromWheel: source == .wheel,
                               time: monotonicMilliseconds())
        case .key(let key):
            // Ctrl+Alt+Backspace (XKB_KEY_BackSpace = 0xff08) quits.
            if key.pressed, key.control, key.alt, key.keysym == 0xFF08 {
                running = false
                return
            }
            // The Super key opens Summon and closes it again.
            if key.pressed, key.keysym == Keysym.superLeft || key.keysym == Keysym.superRight {
                // The list is read again as it opens, so an app that was
                // installed a moment ago is in it. Reading a few hundred
                // small files takes less time than the list takes to appear.
                if !shell.summonIsOpen { readApps() }
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
            chosenFocus = window
            arrange()
            updateFocus()
            log("APP-RAISED \(id)")
            screen.setNeedsFrame()
            return
        }
        guard let bundle = apps.first(where: { $0.id == id }) else {
            log("compositor: no app with the id \(id)")
            post(Notice(id: "start:\(id)", kind: .failure, source: "Apus",
                        title: "No app has the name \(id)",
                        detail: "Its bundle is not in \(AppCatalog.directory)."))
            return
        }
        startLaunch(of: bundle)
    }

    /// The window that has the keys hears it. See `focusedWindow`.
    private func updateFocus() {
        let focused = focusedWindow
        server.setKeyboardFocus(focused?.surface)
        guard focused !== announcedFocus else { return }
        announcedFocus = focused
        if let focused { log("FOCUS \"\(focused.surface.toplevel?.title ?? "")\"") }
    }

    /// Asks the window with the keys to close. The app decides what it does.
    private func closeFrontWindow() {
        guard let window = focusedWindow else { return }
        window.surface.toplevel?.resource?.sendClose()
        server.flush()
        log("WINDOW-CLOSE-SENT \"\(window.surface.toplevel?.title ?? "")\"")
    }

    private func movePointer(to position: (x: Double, y: Double)) {
        pointer = (min(max(position.x, 0), Double(screen.width - 1)),
                   min(max(position.y, 0), Double(screen.height - 1)))
        screen.movePointer(toX: Int(pointer.x), y: Int(pointer.y))
        routePointer()
        // A display that draws the pointer needs no frame for a move. What
        // the move changed asks for its own: a view that lights up under the
        // pointer asks through needsUpdate, and an app that took the pointer
        // asks when it commits.
        if !screen.drawsPointer { screen.setNeedsFrame() }
    }

    /// The window under the pointer, or nil when the shell wants it.
    ///
    /// The shell keeps the pointer over its own chrome: the rail, the head
    /// of a window, a card, a notice. Summon covers everything while it is
    /// open, so the shell keeps the pointer then as well.
    private var windowUnderPointer: Window? {
        guard !shell.summonIsOpen else { return nil }
        let point = (x: pointer.x / scale, y: pointer.y / scale)
        return frontFirst.first { window in
            guard let frame = window.frame else { return false }
            return point.x >= Double(frame.x) && point.x < Double(frame.x + frame.width)
                && point.y >= Double(frame.y) && point.y < Double(frame.y + frame.height)
        }
    }

    /// Gives the pointer to the window under it, or to the shell. While a
    /// button is down, what the press started keeps it.
    private func routePointer() {
        let point = pointerPoints
        switch grab {
        case .window(let window):
            // The app keeps the pointer, also outside its window, in the
            // coordinates of its surface.
            if let frame = window.frame {
                server.sendPointer(motion: (point.x - Double(frame.x), point.y - Double(frame.y)),
                                   time: monotonicMilliseconds())
            }
            return
        case .shell:
            host.pointerMoved(to: point.x, y: point.y)
            return
        case .move:
            // The window follows the pointer, which is a new frame.
            screen.setNeedsFrame()
            return
        case .resize(let window, let resize, let from, let start):
            follow(resize, of: window, from: from, start: start, to: point)
            return
        case nil:
            break
        }
        guard let window = windowUnderPointer, let frame = window.frame else {
            // The shell has it. An app that had it hears that it left.
            server.setPointerFocus(nil, at: (0, 0))
            host.pointerMoved(to: point.x, y: point.y)
            return
        }
        // The app has it, so no view of the shell is under the pointer.
        host.pointerLeft()
        let inside = (x: point.x - Double(frame.x), y: point.y - Double(frame.y))
        server.setPointerFocus(window.surface, at: inside)
        server.sendPointer(motion: inside, time: monotonicMilliseconds())
    }

    // MARK: - Window management

    /// A button of the pointer. The first press decides who holds the
    /// pointer until the last button comes up: the window under it, or the
    /// shell. A move or a resize then takes it from the window.
    private func handleButton(_ code: UInt32, pressed: Bool) {
        let first = pressed && buttonsDown.isEmpty
        if pressed { buttonsDown.insert(code) } else { buttonsDown.remove(code) }
        if first {
            // A window can open or move under a pointer that stands still,
            // so the pointer is given again before the press.
            routePointer()
            if let window = windowUnderPointer {
                grab = .window(window)
                self.pressed(on: window)
            } else {
                grab = .shell
            }
        }
        switch grab {
        case .window:
            server.sendPointer(button: code, pressed: pressed, time: monotonicMilliseconds())
        case .shell, nil:
            if code == 0x110 { host.pointerButton(pressed: pressed) }
        case .move, .resize:
            // The compositor holds the pointer, and the app heard that it
            // left, so the app hears nothing of the buttons.
            break
        }
        if !pressed, buttonsDown.isEmpty { endGrab() }
    }

    /// A press on a window gives it the keys.
    ///
    /// Where the keys follow the first place, that means the large cell. The
    /// window goes there when the button comes up and not now: in its new
    /// cell it would no longer be under the pointer that holds it, and a
    /// press that starts a move goes to the cell of the drop instead. Side
    /// by side and in the grid, the window keeps its cell and gets the keys
    /// at once.
    private func pressed(on window: Window) {
        if layoutKind.keysFollowFirstPlace {
            if window !== windows.last { raiseOnRelease = window }
            return
        }
        guard focusedWindow !== window else { return }
        chosenFocus = window
        arrange()
        updateFocus()
        screen.setNeedsFrame()
    }

    /// The last button came up. What the press started ends.
    private func endGrab() {
        let ended = grab
        let raise = raiseOnRelease
        grab = nil
        raiseOnRelease = nil
        server.pressEnded()
        switch ended {
        case .window(let window):
            if raise === window, windows.contains(where: { $0 === window }) {
                raiseWindow(window.id)
                log("WINDOW-RAISED \"\(window.surface.toplevel?.title ?? "")\"")
            }
        case .move(let window, _):
            drop(window)
        case .resize(let window, _, _, _):
            // The configure that follows has no resizing state, and it has
            // the size that the edge stopped at.
            arrange()
            let size = window.frame.map { "\($0.width)x\($0.height)" } ?? "in the rail"
            log("WINDOW-RESIZED \"\(window.surface.toplevel?.title ?? "")\" \(size)")
        case .shell, nil:
            break
        }
        routePointer()
        screen.setNeedsFrame()
    }

    /// The window of a press, when this surface is that window and the
    /// button is still down.
    private func heldWindow(_ surface: Surface) -> Window? {
        guard case .window(let window) = grab, window.surface === surface,
              !buttonsDown.isEmpty else { return nil }
        return window
    }

    /// An app asked to move its window (xdg_toplevel.move).
    ///
    /// No window floats, so the window does not stay where the pointer
    /// leaves it. It follows the pointer while the button is down, and then
    /// changes places with the window whose cell is under the pointer.
    private func startMove(of surface: Surface) {
        let title = surface.toplevel?.title ?? ""
        guard let window = heldWindow(surface) else {
            return log("WINDOW-MOVE-IGNORED \"\(title)\" no button holds it")
        }
        guard WindowMove.isPossible(in: layoutKind), window.frame != nil else {
            return log("WINDOW-MOVE-REFUSED \"\(title)\" the layout has no other cell")
        }
        raiseOnRelease = nil
        grab = .move(window, from: pointerPoints)
        server.setPointerFocus(nil, at: (0, 0))
        log("WINDOW-MOVE-START \"\(title)\"")
        screen.setNeedsFrame()
    }

    /// The button came up at the end of a move.
    private func drop(_ window: Window) {
        let title = window.surface.toplevel?.title ?? ""
        let front = frontFirst
        guard let from = front.firstIndex(where: { $0 === window }) else { return }
        // A stand-in holds a cell too, so a window can change places with a
        // window that waits in the rail.
        let cells = front.map { $0.cell ?? $0.reservation }
        guard let target = WindowMove.target(at: pointerPoints, cells: cells, moving: from),
              let a = windows.firstIndex(where: { $0 === window }),
              let b = windows.firstIndex(where: { $0 === front[target] }) else {
            return log("WINDOW-MOVE-DROPPED \"\(title)\" keeps its cell")
        }
        windows.swapAt(a, b)
        chosenFocus = window
        arrange()
        updateFocus()
        log("WINDOW-MOVED \"\(title)\" to the cell of"
            + " \"\(front[target].surface.toplevel?.title ?? "")\"")
    }

    /// An app asked to change the size of its window from these edges
    /// (xdg_toplevel.resize).
    ///
    /// The layout owns every size, so a resize moves only an edge that the
    /// layout lets a person move. Every other resize is refused, and the app
    /// keeps the pointer as if it had not asked.
    private func startResize(of surface: Surface, edges: WindowEdges) {
        let title = surface.toplevel?.title ?? ""
        guard let window = heldWindow(surface) else {
            return log("WINDOW-RESIZE-IGNORED \"\(title)\" no button holds it")
        }
        // The cells of the apps that are starting come first in the layout,
        // so they count for the place of the window.
        guard let place = frontFirst.firstIndex(where: { $0 === window }),
              let cell = window.cell,
              let resize = WindowResize.of(layout: layoutKind, index: launches.count + place,
                                           placed: true,
                                           edges: edges, canvas: canvas) else {
            return log("WINDOW-RESIZE-REFUSED \"\(title)\" the layout owns that edge")
        }
        let start: Double
        switch resize {
        case .split:
            start = SideBySide.firstWidth(split: split, in: canvas.width)
        case .tileLength(let axis, _):
            start = Double(axis == .vertical ? cell.height : cell.width)
        }
        raiseOnRelease = nil
        grab = .resize(window, resize, from: pointerPoints, start: start)
        server.setPointerFocus(nil, at: (0, 0))
        log("WINDOW-RESIZE-START \"\(title)\" edges \(edges.rawValue)")
        // The app hears at once that it is being resized.
        arrange()
        screen.setNeedsFrame()
    }

    /// The pointer moved during a resize. The edge follows it, and the
    /// windows whose size changed are asked for the new one.
    private func follow(_ resize: WindowResize, of window: Window,
                        from: (x: Double, y: Double), start: Double,
                        to point: (x: Double, y: Double)) {
        switch resize {
        case .split:
            let moved = SideBySide.split(firstWidth: start + point.x - from.x, in: canvas.width)
            guard moved != split else { return }
            split = moved
        case .tileLength(let axis, let sign):
            let delta = axis == .vertical ? point.y - from.y : point.x - from.x
            let length = WindowResize.tileLength(from: start, moved: delta, sign: sign)
            guard length != window.preferredLength else { return }
            window.preferredLength = length
        }
        arrange()
        screen.setNeedsFrame()
    }
}
