import CWaylandClient
import CXDGShellClient
import Glibc
import Render
import Toolkit

// The listeners of libwayland. They live in an enum of their own because a
// listener is a C callback, and a C callback can hold no state of Swift: it
// reads the window back from the pointer that it is given. `nonisolated(unsafe)`
// is needed because a `let` at the top of a file belongs to the main actor.
enum Listeners {
    nonisolated(unsafe) static let registry = permanent(wl_registry_listener(
        global: { data, registry, name, interface, version in
            let app = window(data)
            switch String(cString: interface!) {
            case "wl_compositor":
                app.compositor = OpaquePointer(
                    wl_registry_bind(registry, name, wl_compositor_interface_ptr(), 4))
            case "wl_shm":
                app.shm = OpaquePointer(
                    wl_registry_bind(registry, name, wl_shm_interface_ptr(), 1))
            case "xdg_wm_base":
                app.wmBase = OpaquePointer(
                    wl_registry_bind(registry, name, xdg_wm_base_interface_ptr(), 1))
            case "wl_seat":
                app.seat = OpaquePointer(
                    wl_registry_bind(registry, name, wl_seat_interface_ptr(), 5))
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
            let app = window(data)
            xdg_surface_ack_configure(xdgSurface, serial)
            app.take(size: app.newSize ?? app.size)
            if app.pixels == nil { app.makeBuffer() }
            app.draw()
        }
    ))

    nonisolated(unsafe) static let toplevel = permanent(xdg_toplevel_listener(
        configure: { data, _, width, height, _ in
            // A size of zero means "pick your own".
            guard width > 0, height > 0 else { return }
            window(data).newSize = Size(width: Double(width), height: Double(height))
        },
        close: { data, _ in window(data).close() },
        configure_bounds: { _, _, _, _ in },
        wm_capabilities: { _, _, _ in }
    ))

    nonisolated(unsafe) static let frame = permanent(wl_callback_listener(
        done: { data, callback, _ in
            let app = window(data)
            wl_callback_destroy(callback)
            app.framePending = false
            if app.needsDraw { app.draw() }
        }
    ))

    nonisolated(unsafe) static let output = permanent(wl_output_listener(
        geometry: { _, _, _, _, _, _, _, _, _, _ in },
        mode: { _, _, _, _, _, _ in },
        done: { _, _ in },
        scale: { data, _, factor in
            let app = window(data)
            let scale = max(1, Int(factor))
            guard scale != app.scale else { return }
            app.scale = scale
            // The window keeps its size in points and draws more pixels.
            if app.pixels != nil {
                app.makeBuffer()
                app.draw()
            }
        },
        name: { _, _, _ in },
        description: { _, _, _ in }
    ))

    nonisolated(unsafe) static let seat = permanent(wl_seat_listener(
        capabilities: { data, seat, capabilities in
            let app = window(data)
            if capabilities & WL_SEAT_CAPABILITY_KEYBOARD.rawValue != 0, app.keyboardObject == nil {
                app.keyboardObject = wl_seat_get_keyboard(seat)
                wl_keyboard_add_listener(app.keyboardObject, Listeners.keyboard, data)
            }
            if capabilities & WL_SEAT_CAPABILITY_POINTER.rawValue != 0, app.pointerObject == nil {
                app.pointerObject = wl_seat_get_pointer(seat)
                wl_pointer_add_listener(app.pointerObject, Listeners.pointer, data)
            }
        },
        name: { _, _, _ in }
    ))

    nonisolated(unsafe) static let keyboard = permanent(wl_keyboard_listener(
        keymap: { data, _, _, fd, size in
            window(data).keys.read(fd: fd, size: Int(size))
            close(fd)
        },
        // The keys that are down when the window gets the focus do not
        // repeat: they went down somewhere else.
        enter: { _, _, _, _, _ in },
        // A window without the keys hears no release, so a key that was
        // held stops here.
        leave: { data, _, _, _ in window(data).keyRepeat.stop() },
        key: { data, _, _, _, key, state in
            let app = window(data)
            let pressed = state == WL_KEYBOARD_KEY_STATE_PRESSED.rawValue
            // The compositor sends one press for a key that is held; the
            // repeat is the app's to make. The keymap says which keys
            // repeat, and a modifier does not.
            if pressed {
                app.keyRepeat.pressed(key, repeats: app.keys.repeats(code: key), at: monotonic())
            } else {
                app.keyRepeat.released(key)
            }
            // A view of the app reads the key first. A key that no view took
            // belongs to the app itself.
            app.deliver(key: key, pressed: pressed)
        },
        modifiers: { data, _, _, depressed, latched, locked, group in
            window(data).keys.setModifiers(depressed: depressed, latched: latched,
                                           locked: locked, group: group)
        },
        repeat_info: { data, _, rate, delay in
            window(data).keyRepeat.set(rate: rate, delay: delay)
        }
    ))

    nonisolated(unsafe) static let pointer = permanent(wl_pointer_listener(
        enter: { data, _, _, _, x, y in
            window(data).host.pointerMoved(to: wl_fixed_to_double(x), y: wl_fixed_to_double(y))
        },
        leave: { data, _, _, _ in window(data).host.pointerLeft() },
        motion: { data, _, _, x, y in
            window(data).host.pointerMoved(to: wl_fixed_to_double(x), y: wl_fixed_to_double(y))
        },
        button: { data, _, _, _, button, state in
            // BTN_LEFT.
            guard button == 0x110 else { return }
            window(data).host.pointerButton(
                pressed: state == WL_POINTER_BUTTON_STATE_PRESSED.rawValue)
        },
        axis: { data, _, _, axis, value in
            guard axis == WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue else { return }
            window(data).scrolled += wl_fixed_to_double(value)
        },
        // The events of one movement end with a frame, and the views move
        // once for all of them.
        frame: { data, _ in window(data).applyScroll() },
        axis_source: { data, _, source in
            window(data).scrollIsWheel = source == WL_POINTER_AXIS_SOURCE_WHEEL.rawValue
        },
        axis_stop: { _, _, _, _ in },
        axis_discrete: { _, _, _, _ in },
        axis_value120: { _, _, _, _ in },
        axis_relative_direction: { _, _, _, _ in },
        warp: { _, _, _, _ in }
    ))
}
