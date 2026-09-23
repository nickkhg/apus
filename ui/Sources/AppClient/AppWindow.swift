import CWaylandClient
import CXDGShellClient
import Glibc
import Render
import Toolkit

// How an app of Apus opens a window.
//
// An app gives a view tree and gets a window. This holds everything between
// the two: the connection, the surface, the shared memory that the pixels
// live in, the size that the compositor asks for, and the pointer and the
// keys. The view tree goes through `ViewHost`, so an app gets the hover, the
// click and the key handling of the toolkit without writing any of it.
//
//     let window = AppWindow(title: "System", appID: "org.apus.system")
//     window.body = { SystemView(state: readings()) }
//     window.run()
//
// The terminal does not use this: it draws a grid of characters rather than
// a view tree, and it reads the keys as bytes for a pseudo terminal. See
// ui/Sources/TerminalApp.

/// One window of one app.
public final class AppWindow {
    /// The view tree to draw. The app gives a new one for each frame.
    public var body: () -> any View = { Color.clear }
    /// Called after the window learns its size, and after every change of
    /// it. An app that keeps its own state of the size reads it here.
    public var sizeChanged: (Size, SizeClass) -> Void = { _, _ in }
    /// The keys that no view of the app took.
    public var onKey: (KeyEvent) -> Void = { _ in }
    /// Called about once a second, for an app that shows something that
    /// changes on its own. The window wakes up that often anyway, to carry
    /// on a move that a view started.
    public var everySecond: () -> Void = {}

    /// The size of the window in points, as the compositor asked for it.
    public internal(set) var size = Size(width: 640, height: 480)
    /// How much room the window has, which says which user interface to draw.
    public internal(set) var sizeClass = SizeClass.large
    /// How many pixels of the buffer make one point. wl_output says it.
    public internal(set) var scale = 1

    let title: String
    let appID: String
    /// The smallest size that this window accepts, or nil for any size.
    let minimumSize: Size?

    // Wayland objects.
    var display: OpaquePointer?
    var compositor: OpaquePointer?
    var shm: OpaquePointer?
    var wmBase: OpaquePointer?
    var seat: OpaquePointer?
    var output: OpaquePointer?
    var surface: OpaquePointer?
    var xdgSurface: OpaquePointer?
    var toplevel: OpaquePointer?
    var keyboardObject: OpaquePointer?
    var pointerObject: OpaquePointer?

    // The pixels.
    var pool: OpaquePointer?
    var buffer: OpaquePointer?
    var pixels: UnsafeMutablePointer<UInt32>?
    var mappedBytes = 0
    var buffers = 0

    /// The size that the last configure asked for, in points.
    var newSize: Size?
    var running = true
    var framePending = false
    var needsDraw = true
    let host = ViewHost()
    let keys = Keymap()
    /// When the window opened, so that a view can move from the start.
    let startedAt = monotonic()
    /// When `everySecond` last ran.
    var lastSecond = monotonic()
    /// The scroll of one movement of the wheel, which a frame event of the
    /// pointer ends.
    var scrolled = 0.0
    /// What the last axis_source said made the scroll. A wheel counts in
    /// degrees, 15 to a click, and a touchpad counts in points.
    var scrollIsWheel = true
    /// How far one degree of the wheel moves a view: a click is 45 points,
    /// about three lines of text.
    static let pointsPerDegree = 3.0

    public init(title: String, appID: String, minimumSize: Size? = nil) {
        self.title = title
        self.appID = appID
        self.minimumSize = minimumSize
        host.needsUpdate = { [unowned self] in needsDraw = true }
    }

    /// Asks for a new frame. An app calls this when what it shows changes.
    public func setNeedsDraw() {
        needsDraw = true
    }

    /// Closes the window and ends `run()`.
    public func close() {
        running = false
    }

    /// Gives the scroll of one movement to the view under the pointer.
    func applyScroll() {
        guard scrolled != 0 else { return }
        let delta = scrolled * (scrollIsWheel ? AppWindow.pointsPerDegree : 1)
        scrolled = 0
        host.pointerScrolled(by: delta)
    }

    var pixelWidth: Int { Int(size.width) * scale }
    var pixelHeight: Int { Int(size.height) * scale }
}

/// Seconds since the machine started. Every move of a view reads it.
func monotonic() -> Double {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000
}

/// Allocates a value that never moves, because libwayland keeps the pointer.
func permanent<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    pointer.initialize(to: value)
    return pointer
}

/// The app, from the pointer that a listener of libwayland gives back.
func window(_ data: UnsafeMutableRawPointer?) -> AppWindow {
    Unmanaged<AppWindow>.fromOpaque(data!).takeUnretainedValue()
}

public func fail(_ message: String) -> Never {
    Console.report(message)
    exit(1)
}

/// Writes a line on the standard error. The toolkit has no Foundation.
public enum Console {
    public static func report(_ message: String) {
        var line = message + "\n"
        line.withUTF8 { bytes in
            _ = Glibc.write(2, bytes.baseAddress, bytes.count)
        }
    }
}
