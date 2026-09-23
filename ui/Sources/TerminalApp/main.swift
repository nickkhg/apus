// apus-terminal [--command PROGRAM]
//
// The terminal of Apus: a window with a shell in it.
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
    var pointerObject: OpaquePointer?
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
    /// The key that is held down and repeats, and when it goes again.
    var keyRepeat = KeyRepeat()
    /// Copying and pasting, and with it the clipboard of the Mac.
    let clipboard = Clipboard()
    /// What a person has selected with the pointer, if anything.
    var selection: Selection?
    /// True while the button is down and the selection is being drawn out.
    var isSelecting = false
    /// Where the pointer is in the window, in points.
    var pointer = (x: 0.0, y: 0.0)
    /// The size of one character, in pixels. It follows the scale, because
    /// the grid is drawn in the pixels of the buffer.
    var cell = CellSize(font: .monospaced(size: 15))
    /// The size of the text in points. The cell is this at `scale`.
    let fontSize: Double = 15
    var screen = Screen(columns: 80, rows: 24)
    var pty: PTY?

    /// Scroll that has arrived and is not yet a whole line of the grid.
    var scrolled = 0.0
    /// What the last axis_source said made the scroll. A wheel and a
    /// touchpad send the same event with numbers that mean different things.
    var scrollIsWheel = true
    /// How far a wheel turns for one line. wl_pointer counts a wheel in
    /// degrees, and one click of a usual wheel is 15 of them: three lines.
    static let degreesPerLine = 5.0
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

    let name = "/apus-terminal-\(getpid())"
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
        : Grid.displayList(for: app.screen, cell: app.cell, in: frame,
                           selection: app.selection)
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

/// Turns the scroll that has arrived into lines, and moves the view.
///
/// A wheel and a touchpad do not measure in the same units, so the step is
/// not the same for the two. What is left over below one line is kept for
/// the next event: a touchpad sends many small moves, and dropping each one
/// would leave the view where it was.
func applyScroll(_ app: App) {
    let perLine = app.scrollIsWheel
        ? App.degreesPerLine
        : app.cell.height / Double(app.scale)
    guard perLine > 0 else { return }
    let lines = (app.scrolled / perLine).rounded(.towardZero)
    guard lines != 0 else { return }
    app.scrolled -= lines * perLine
    // Down the axis is towards the newest line, which is less scrollback.
    app.screen.scrollBack(by: -Int(lines))
}

/// The place in the text under the pointer.
///
/// wl_pointer gives a place in the surface, in points. The grid is drawn in
/// the pixels of the buffer, so the scale of the window is between the two.
/// A column one past the last is allowed: a drag that leaves the right edge
/// of the window selects to the end of the line.
func textPosition(_ app: App, x: Double, y: Double) -> TextPosition {
    let column = Int((x * Double(app.scale) / app.cell.width).rounded(.down))
    let row = Int((y * Double(app.scale) / app.cell.height).rounded(.down))
    return app.screen.position(atRow: min(max(0, row), app.screen.rows - 1),
                               column: min(max(0, column), app.screen.columns))
}

/// Puts what is selected on the clipboard of the system, and with it on the
/// clipboard of the Mac.
func copySelection(_ app: App, data: UnsafeMutableRawPointer?) {
    guard let selection = app.selection, !selection.isEmpty else { return }
    let text = app.screen.text(in: selection)
    guard !text.isEmpty else { return }
    app.clipboard.copy(text, data: data)
}

/// Writes what is on the clipboard to the shell, as if it had been typed.
func pasteIntoTheShell(_ app: App, display: OpaquePointer?) {
    guard let text = app.clipboard.paste(display: display), !text.isEmpty else { return }
    // A shell reads a return as "run this", so a paste of several lines runs
    // all but the last. That is what a terminal without bracketed paste
    // does, and what a person pasting a command expects.
    app.screen.scrollToBottom()
    app.pty?.write(Array(text.utf8))
}

/// What a key that went down does, and what a held key does each time it
/// repeats. It answers whether the key may repeat: copy and paste may not,
/// because a held Control+Shift+V would paste many times.
@discardableResult
func press(_ app: App, key: UInt32, data: UnsafeMutableRawPointer?) -> Bool {
    // Copy, paste and the keys that scroll are read before the key becomes
    // bytes: Control+Shift+C makes the same byte as Control+C, which is the
    // one that stops a program.
    if let chord = app.keyboard.chord(forKey: key) {
        switch chord {
        case .copy:
            copySelection(app, data: data)
            return false
        case .paste:
            pasteIntoTheShell(app, display: wl_proxy_get_display(app.surface))
            return false
        case .scrollUp: app.screen.scrollBack(by: app.screen.rows / 2)
        case .scrollDown: app.screen.scrollBack(by: -(app.screen.rows / 2))
        }
        return true
    }
    let bytes = app.keyboard.bytes(forKey: key)
    guard !bytes.isEmpty else { return false }
    // A person who types wants to see what they are typing, so the view goes
    // back to the live screen, as every terminal does, and what was selected
    // is no longer what they are looking at.
    app.screen.scrollToBottom()
    if app.selection != nil {
        app.selection = nil
        app.screen.hasChanged = true
    }
    app.pty?.write(bytes)
    return true
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
            case "wl_data_device_manager":
                app.clipboard.bind(registry: registry, name: name)
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
            if capabilities & WL_SEAT_CAPABILITY_KEYBOARD.rawValue != 0,
               app.keyboardObject == nil {
                app.keyboardObject = wl_seat_get_keyboard(seat)
                wl_keyboard_add_listener(app.keyboardObject, Listeners.keyboard, data)
            }
            // The pointer scrolls back through the lines that went off the
            // top, and it draws out a selection.
            if capabilities & WL_SEAT_CAPABILITY_POINTER.rawValue != 0,
               app.pointerObject == nil {
                app.pointerObject = wl_seat_get_pointer(seat)
                wl_pointer_add_listener(app.pointerObject, Listeners.pointer, data)
            }
            // The clipboard belongs to the seat as well.
            app.clipboard.start(seat: seat, data: data)
        },
        name: { _, _, _ in }
    ))

    /// The pointer. Only the wheel does anything: there is no text to select
    /// and nothing in the window to press.
    nonisolated(unsafe) static let pointer = permanent(wl_pointer_listener(
        enter: { data, _, serial, _, x, y in
            let app = appState(data)
            app.clipboard.lastSerial = serial
            app.pointer = (wl_fixed_to_double(x), wl_fixed_to_double(y))
        },
        leave: { _, _, _, _ in },
        motion: { data, _, _, x, y in
            let app = appState(data)
            app.pointer = (wl_fixed_to_double(x), wl_fixed_to_double(y))
            guard app.isSelecting, let anchor = app.selection?.anchor else { return }
            let focus = textPosition(app, x: app.pointer.x, y: app.pointer.y)
            let drawn = Selection(anchor: anchor, focus: focus)
            guard drawn != app.selection else { return }
            app.selection = drawn
            app.screen.hasChanged = true
        },
        button: { data, _, serial, _, button, state in
            let app = appState(data)
            app.clipboard.lastSerial = serial
            // BTN_LEFT of the kernel. Only that one selects.
            guard button == 0x110 else { return }
            if state == WL_POINTER_BUTTON_STATE_PRESSED.rawValue {
                let place = textPosition(app, x: app.pointer.x, y: app.pointer.y)
                app.selection = Selection(anchor: place, focus: place)
                app.isSelecting = true
                app.screen.hasChanged = true       // the last selection goes
            } else {
                app.isSelecting = false
                // A click with no drag in it is not a selection; it only
                // takes the last one away.
                if app.selection?.isEmpty == true { app.selection = nil }
            }
        },
        axis: { data, _, _, axis, value in
            guard axis == WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue else { return }
            appState(data).scrolled += wl_fixed_to_double(value)
        },
        // The events of one movement end with a frame, and the view moves
        // once for all of them.
        frame: { data, _ in applyScroll(appState(data)) },
        axis_source: { data, _, source in
            appState(data).scrollIsWheel = source == WL_POINTER_AXIS_SOURCE_WHEEL.rawValue
        },
        axis_stop: { _, _, _, _ in },
        axis_discrete: { _, _, _, _ in },
        axis_value120: { _, _, _, _ in },
        axis_relative_direction: { _, _, _, _ in },
        warp: { _, _, _, _ in }
    ))

    nonisolated(unsafe) static let keyboard = permanent(wl_keyboard_listener(
        keymap: { data, _, format, fd, size in
            if format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1.rawValue {
                appState(data).keyboard.read(keymapFD: fd, size: Int(size))
            }
            close(fd)
        },
        // The keys that are down when the window gets the focus do not
        // repeat: they went down somewhere else.
        enter: { _, _, _, _, _ in },
        // A window without the keys hears no release, so a key that was
        // held stops here.
        leave: { data, _, _, _ in appState(data).keyRepeat.stop() },
        key: { data, _, serial, _, key, keyState in
            let app = appState(data)
            app.clipboard.lastSerial = serial
            guard keyState == WL_KEYBOARD_KEY_STATE_PRESSED.rawValue else {
                app.keyRepeat.released(key)
                return
            }
            // The compositor sends one press for a key that is held; the
            // repeat is the app's to make. The keymap says which keys
            // repeat, and a modifier does not.
            let repeats = press(app, key: key, data: data) && app.keyboard.repeats(key: key)
            app.keyRepeat.pressed(key, repeats: repeats, at: monotonic())
        },
        modifiers: { data, _, _, depressed, latched, locked, group in
            appState(data).keyboard.setModifiers(depressed: depressed, latched: latched,
                                                 locked: locked, group: group)
        },
        repeat_info: { data, _, rate, delay in
            appState(data).keyRepeat.set(rate: rate, delay: delay)
        }
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
        fail("usage: apus-terminal [--command PROGRAM]")
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
xdg_toplevel_set_app_id(app.toplevel, "org.apus.terminal")
wl_surface_commit(app.surface)

// The app waits for two things: events of the compositor (keys, frames) and
// text from the shell. A key that is held down ends the wait early, when it
// is due to go again.
let displayFD = wl_display_get_fd(display)
while app.running {
    wl_display_flush(display)
    var watched = [
        pollfd(fd: displayFD, events: Int16(POLLIN), revents: 0),
        pollfd(fd: app.pty?.fd ?? -1, events: Int16(POLLIN), revents: 0),
    ]
    let wait = min(1000, app.keyRepeat.wait(at: monotonic()) ?? 1000)
    guard poll(&watched, 2, wait) >= 0 || errno == EINTR else { break }
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
    if let key = app.keyRepeat.due(at: monotonic()),
       !press(app, key: key, data: appPointer) {
        app.keyRepeat.stop()
    }
    if app.screen.hasChanged, !app.framePending { draw(app) }
}
wl_display_flush(display)
