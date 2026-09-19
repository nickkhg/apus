import DRMKit
import Glibc
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
        var x: Int, y: Int
        init(surface: Surface, x: Int, y: Int) { (self.surface, self.x, self.y) = (surface, x, y) }
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
        server.surfaceCommitted = { [unowned self] surface in surfaceCommitted(surface) }
        server.surfaceDestroyed = { [unowned self] surface in
            windows.removeAll { $0.surface === surface }
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
        var list: DisplayList = [.fill(Rect(x: 0, y: 0, width: screen.width, height: screen.height),
                                       color: options.background)]
        for window in windows {
            if let content = window.surface.content {
                list.append(.bitmap(content, x: window.x, y: window.y))
            }
        }
        list.append(.bitmap(Cursor.bitmap, x: Int(pointer.x), y: Int(pointer.y)))
        return list
    }

    // MARK: - Windows

    private func surfaceCommitted(_ surface: Surface) {
        if surface.isMapped, !windows.contains(where: { $0.surface === surface }),
           let content = surface.content {
            // New windows open centred, each further one offset a little.
            let offset = 32 * windows.count
            let x = (screen.width - content.width) / 2 + offset
            let y = (screen.height - content.height) / 2 + offset
            windows.append(Window(surface: surface, x: x, y: y))
            let title = surface.toplevel?.title ?? ""
            log("WINDOW-MAPPED \"\(title)\" \(content.width)x\(content.height) at \(x),\(y)")
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
        case .button:
            break   // no input focus or window management yet
        case .key(let keysym, let pressed, let control, let alt):
            // Ctrl+Alt+Backspace (XKB_KEY_BackSpace = 0xff08) quits.
            if pressed, control, alt, keysym == 0xFF08 { running = false }
        }
    }

    private func movePointer(to position: (x: Double, y: Double)) {
        pointer = (min(max(position.x, 0), Double(screen.width - 1)),
                   min(max(position.y, 0), Double(screen.height - 1)))
        screen.setNeedsFrame()
    }
}
