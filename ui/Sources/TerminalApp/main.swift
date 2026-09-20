// mydistro-terminal [--command PROGRAM]
//
// The terminal of mydistro: a window with a shell in it.
//
// The app opens one window, which the compositor gives the app area of the
// screen. It starts a shell on a pseudo terminal, reads what the shell
// prints into a grid of characters (Screen.swift), and draws the grid with
// the toolkit (Grid.swift). The keys come from the compositor through
// wl_keyboard, and Keyboard.swift makes the bytes of them that the shell
// reads.
//
// The app is a bundle in /Applications, so the dock shows it and a click on
// the icon starts it.

import CWaylandClient
import CXDGShellClient
import Glibc
import Render
import Terminal
import Toolkit

// MARK: - The state of the app

final class App {
    var compositor: OpaquePointer?
    var shm: OpaquePointer?
    var wmBase: OpaquePointer?
    var seat: OpaquePointer?
    var keyboardObject: OpaquePointer?
    var surface: OpaquePointer?
    var xdgSurface: OpaquePointer?
    var toplevel: OpaquePointer?
    var pool: OpaquePointer?
    var buffer: OpaquePointer?

    /// The pixels of the window, and how many bytes are mapped.
    var pixels: UnsafeMutablePointer<UInt32>?
    var mappedBytes = 0
    /// The size of the window in points. A point is `scale` pixels.
    var width = 800
    var height = 500
    /// The size that the last configure asked for.
    var newWidth = 0
    var newHeight = 0
    /// How many pixels of the buffer make one point. wl_output says it, and
    /// the window draws that many times more pixels so that the text is
    /// sharp.
    var scale = 1
    /// The size of the buffer, in pixels.
    var pixelWidth: Int { width * scale }
    var pixelHeight: Int { height * scale }
    /// How much room the window has, which says which user interface it
    /// draws. It comes from the size that the compositor asked for, so the
    /// app knows what to draw before it draws anything.
    var sizeClass: SizeClass {
        SizeClass.of(Proposal(width: Double(width), height: Double(height)))
    }
    /// The title that the shell in the terminal set, as the window last
    /// told the compositor.
    var sentTitle = ""
    var output: OpaquePointer?

    /// The compositor is drawing the last buffer: wait for the frame event.
    var framePending = false
    var running = true

    var command = "/bin/bash"
    let keyboard = Keyboard()
    /// The size of one character, in pixels. It follows the scale, because
    /// the grid is drawn in the pixels of the buffer.
    var cell = CellSize(font: .monospaced(size: 15))
    /// The size of the text in points. The cell is this at `scale`.
    let fontSize: Double = 15
    var screen = Screen(columns: 80, rows: 24)
    var pty: PTY?
}

let app = App()
let appPointer = Unmanaged.passUnretained(app).toOpaque()

/// The app, from the pointer that libwayland gives a listener.
func appState(_ data: UnsafeMutableRawPointer?) -> App {
    Unmanaged<App>.fromOpaque(data!).takeUnretainedValue()
}

func fail(_ message: String) -> Never {
    report(message)
    exit(1)
}

// MARK: - The window's pixels

/// Makes a buffer of the size of the window, and tells the shell how many
/// characters fit in it.
func applySize(_ app: App) {
    // The buffer is in pixels: a window of `width` points on a screen with
    // `scale` pixels to the point needs `width * scale` of them.
    app.cell = CellSize(font: .monospaced(size: app.fontSize * Double(app.scale)))
    let stride = app.pixelWidth * 4
    let size = stride * app.pixelHeight
    if let buffer = app.buffer { wl_buffer_destroy(buffer) }
    if let pool = app.pool { wl_shm_pool_destroy(pool) }
    if let pixels = app.pixels, app.mappedBytes > 0 { munmap(pixels, app.mappedBytes) }
    app.buffer = nil
    app.pool = nil
    app.pixels = nil
    app.mappedBytes = 0

    let name = "/mydistro-terminal-\(getpid())"
    let fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail("no memory for the window: \(String(cString: strerror(errno)))") }
    shm_unlink(name)
    defer { close(fd) }
    guard ftruncate(fd, off_t(size)) == 0,
          let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
          memory != MAP_FAILED else {
        fail("can't map the window")
    }
    app.pixels = memory.assumingMemoryBound(to: UInt32.self)
    app.mappedBytes = size
    app.pool = wl_shm_create_pool(app.shm, fd, Int32(size))
    app.buffer = wl_shm_pool_create_buffer(app.pool, 0, Int32(app.pixelWidth), Int32(app.pixelHeight),
                                           Int32(stride), WL_SHM_FORMAT_XRGB8888.rawValue)
    // The compositor needs to know that the buffer is at this scale.
    wl_surface_set_buffer_scale(app.surface, Int32(app.scale))

    let columns = app.cell.columns(in: Double(app.pixelWidth))
    let rows = app.cell.rows(in: Double(app.pixelHeight))
    app.screen.resize(columns: columns, rows: rows)
    app.pty?.setSize(columns: columns, rows: rows, width: app.pixelWidth, height: app.pixelHeight)
}

/// Draws the grid into the buffer and gives the buffer to the compositor.
func draw(_ app: App) {
    guard let pixels = app.pixels, let surface = app.surface, let buffer = app.buffer else { return }
    let canvas = Canvas(pixels: pixels, width: app.pixelWidth, height: app.pixelHeight,
                        stride: app.pixelWidth)
    let frame = Rect(x: 0, y: 0, width: app.pixelWidth, height: app.pixelHeight)
    // A tile is too narrow for a grid that a person can work in, so it
    // shows what the shell is doing instead of a small terminal.
    let list = app.sizeClass == .widget
        ? ViewRenderer.displayList(for: TerminalWidget(screen: app.screen, title: app.screen.title),
                                   in: frame, scale: Double(app.scale))
        : Grid.displayList(for: app.screen, cell: app.cell, in: frame)
    SoftwareRenderer.render(list, into: canvas)
    app.screen.hasChanged = false
    // The shell draws the title in the head of the window and in the card
    // of a window that waits, so a change goes to the compositor.
    if app.screen.title != app.sentTitle {
        app.sentTitle = app.screen.title
        xdg_toplevel_set_title(app.toplevel, app.sentTitle.isEmpty ? "Terminal" : app.sentTitle)
    }

    // The compositor says when the frame is on the screen. Until then, the
    // app draws nothing new.
    let callback = wl_surface_frame(surface)
    wl_callback_add_listener(callback, Listeners.frame, Unmanaged.passUnretained(app).toOpaque())
    app.framePending = true

    wl_surface_attach(surface, buffer, 0, 0)
    wl_surface_damage_buffer(surface, 0, 0, Int32.max, Int32.max)
    wl_surface_commit(surface)
}

// MARK: - The listeners of libwayland
//
// A listener is a table of C functions, so it holds no state: each one gets
// the app in its `data` argument. The tables live here because they must
// stay at the same address for as long as the app runs.

enum Listeners {
    /// The screen. Only the scale matters here: it says how many pixels the
    /// window draws for each point that the compositor gives it.
    nonisolated(unsafe) static let output = permanent(wl_output_listener(
        geometry: { _, _, _, _, _, _, _, _, _, _ in },
        mode: { _, _, _, _, _, _ in },
        done: { _, _ in },
        scale: { data, _, factor in
            let app = appState(data)
            let scale = max(1, Int(factor))
            guard scale != app.scale else { return }
            app.scale = scale
            // The window keeps its size in points and draws more pixels.
            if app.pixels != nil {
                applySize(app)
                draw(app)
            }
        },
        name: { _, _, _ in },
        description: { _, _, _ in }
    ))

    nonisolated(unsafe) static let registry = permanent(wl_registry_listener(
        global: { data, registry, name, interface, _ in
            let app = appState(data)
            switch String(cString: interface!) {
            case "wl_compositor":
                app.compositor = OpaquePointer(
                    wl_registry_bind(registry, name, wl_compositor_interface_ptr(), 4))
            case "wl_shm":
                app.shm = OpaquePointer(wl_registry_bind(registry, name, wl_shm_interface_ptr(), 1))
            case "xdg_wm_base":
                app.wmBase = OpaquePointer(
                    wl_registry_bind(registry, name, xdg_wm_base_interface_ptr(), 1))
            case "wl_seat":
                app.seat = OpaquePointer(wl_registry_bind(registry, name, wl_seat_interface_ptr(), 5))
                wl_seat_add_listener(app.seat, Listeners.seat, data)
            case "wl_output":
                app.output = OpaquePointer(
                    wl_registry_bind(registry, name, wl_output_interface_ptr(), 2))
                wl_output_add_listener(app.output, Listeners.output, data)
            default:
                break
            }
        },
        global_remove: { _, _, _ in }
    ))

    nonisolated(unsafe) static let wmBase = permanent(xdg_wm_base_listener(
        ping: { _, wmBase, serial in xdg_wm_base_pong(wmBase, serial) }
    ))

    nonisolated(unsafe) static let xdgSurface = permanent(xdg_surface_listener(
        configure: { data, xdgSurface, serial in
            let app = appState(data)
            xdg_surface_ack_configure(xdgSurface, serial)
            if app.newWidth > 0, app.newHeight > 0,
               app.newWidth != app.width || app.newHeight != app.height || app.pixels == nil {
                (app.width, app.height) = (app.newWidth, app.newHeight)
                applySize(app)
            } else if app.pixels == nil {
                applySize(app)
            }
            // The shell starts once the size of the window is known, so that
            // it never sees a size that changes at once.
            if app.pty == nil { start(app) }
            draw(app)
        }
    ))

    nonisolated(unsafe) static let toplevel = permanent(xdg_toplevel_listener(
        configure: { data, _, width, height, _ in
            let app = appState(data)
            // A zero size means "pick your own".
            if width > 0, height > 0 { (app.newWidth, app.newHeight) = (Int(width), Int(height)) }
        },
        close: { data, _ in appState(data).running = false },
        configure_bounds: { _, _, _, _ in },
        wm_capabilities: { _, _, _ in }
    ))

    nonisolated(unsafe) static let frame = permanent(wl_callback_listener(
        done: { data, callback, _ in
            let app = appState(data)
            wl_callback_destroy(callback)
            app.framePending = false
            if app.screen.hasChanged { draw(app) }
        }
    ))

    nonisolated(unsafe) static let seat = permanent(wl_seat_listener(
        capabilities: { data, seat, capabilities in
            let app = appState(data)
            guard capabilities & WL_SEAT_CAPABILITY_KEYBOARD.rawValue != 0,
                  app.keyboardObject == nil else { return }
            app.keyboardObject = wl_seat_get_keyboard(seat)
            wl_keyboard_add_listener(app.keyboardObject, Listeners.keyboard, data)
        },
        name: { _, _, _ in }
    ))

    nonisolated(unsafe) static let keyboard = permanent(wl_keyboard_listener(
        keymap: { data, _, format, fd, size in
            if format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1.rawValue {
                appState(data).keyboard.read(keymapFD: fd, size: Int(size))
            }
            close(fd)
        },
        enter: { _, _, _, _, _ in },
        leave: { _, _, _, _ in },
        key: { data, _, _, _, key, keyState in
            let app = appState(data)
            guard keyState == WL_KEYBOARD_KEY_STATE_PRESSED.rawValue else { return }
            let bytes = app.keyboard.bytes(forKey: key)
            if !bytes.isEmpty { app.pty?.write(bytes) }
        },
        modifiers: { data, _, _, depressed, latched, locked, group in
            appState(data).keyboard.setModifiers(depressed: depressed, latched: latched,
                                                 locked: locked, group: group)
        },
        repeat_info: { _, _, _, _ in }
    ))
}

/// Starts the shell in the terminal.
func start(_ app: App) {
    app.pty = PTY(command: app.command,
                  columns: app.screen.columns, rows: app.screen.rows)
    guard app.pty != nil else {
        app.running = false
        return
    }
    app.pty?.setSize(columns: app.screen.columns, rows: app.screen.rows,
                     width: app.width, height: app.height)
    report("TERMINAL-READY \(app.screen.columns)x\(app.screen.rows)")
}

// MARK: - Arguments

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--command":
        guard let command = arguments.popFirst() else { fail("--command needs a program") }
        app.command = command
    default:
        fail("usage: mydistro-terminal [--command PROGRAM]")
    }
}

// MARK: - Main

guard let display = wl_display_connect(nil) else {
    fail("can't connect to a Wayland compositor (is WAYLAND_DISPLAY set?)")
}
let registry = wl_display_get_registry(display)
wl_registry_add_listener(registry, Listeners.registry, appPointer)
wl_display_roundtrip(display)
guard app.compositor != nil, app.shm != nil, app.wmBase != nil else {
    fail("the compositor has no wl_compositor, wl_shm or xdg_wm_base")
}
wl_display_roundtrip(display)       // the seat answers with its capabilities
xdg_wm_base_add_listener(app.wmBase, Listeners.wmBase, appPointer)

app.surface = wl_compositor_create_surface(app.compositor)
app.xdgSurface = xdg_wm_base_get_xdg_surface(app.wmBase, app.surface)
xdg_surface_add_listener(app.xdgSurface, Listeners.xdgSurface, appPointer)
app.toplevel = xdg_surface_get_toplevel(app.xdgSurface)
xdg_toplevel_add_listener(app.toplevel, Listeners.toplevel, appPointer)
xdg_toplevel_set_title(app.toplevel, "Terminal")
xdg_toplevel_set_app_id(app.toplevel, "org.mydistro.terminal")
wl_surface_commit(app.surface)

// The app waits for two things: events of the compositor (keys, frames) and
// text from the shell.
let displayFD = wl_display_get_fd(display)
while app.running {
    wl_display_flush(display)
    var watched = [
        pollfd(fd: displayFD, events: Int16(POLLIN), revents: 0),
        pollfd(fd: app.pty?.fd ?? -1, events: Int16(POLLIN), revents: 0),
    ]
    guard poll(&watched, 2, 1000) >= 0 || errno == EINTR else { break }
    if watched[0].revents & Int16(POLLIN) != 0 {
        if wl_display_dispatch(display) < 0 { break }
    }
    if watched[1].revents != 0 {
        guard let bytes = app.pty?.read() else {
            app.running = false       // the shell ended: so does the window
            break
        }
        if !bytes.isEmpty { app.screen.write(bytes) }
    }
    if app.screen.hasChanged, !app.framePending { draw(app) }
}
wl_display_flush(display)
