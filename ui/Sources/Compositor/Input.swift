import CInput
import CUdev
import CXKBCommon
import Glibc

/// Keyboard and pointer input from libinput, with keymaps from xkbcommon.
/// Devices are opened through the seat.
final class Input {
    enum Failure: Error { case udev, libinput, keymap }

    enum Event {
        /// Relative motion (a mouse), in pixels.
        case pointerMotion(dx: Double, dy: Double)
        /// Absolute position (a tablet, or QEMU's virtio-tablet), 0...1.
        case pointerPosition(x: Double, y: Double)
        case button(code: UInt32, pressed: Bool)
        /// A wheel turned, or two fingers moved on a touchpad. Positive is
        /// down and to the right, as wl_pointer.axis counts. `source` says
        /// what the numbers mean, because a wheel and a touchpad do not
        /// measure in the same units.
        case scroll(dx: Double, dy: Double, source: ScrollSource)
        /// A key of the keyboard.
        case key(Key)
    }

    /// What made a scroll event, and with it what its numbers mean.
    enum ScrollSource {
        /// A wheel, in degrees. One click of a usual wheel is 15 of them.
        case wheel
        /// Fingers on a touchpad, or a device that scrolls smoothly, in the
        /// pixels that the pointer would have moved.
        case finger
    }

    /// One key, for the compositor and for the app with the focus.
    struct Key {
        /// The code of the kernel (evdev). wl_keyboard sends this, and the
        /// app adds 8 to get the xkb keycode.
        let code: UInt32
        /// What the keymap makes of the key (see xkbcommon-keysyms.h). The
        /// compositor uses it for its own keys.
        let keysym: UInt32
        let pressed: Bool
        let control: Bool
        let alt: Bool
        let modifiers: Modifiers
    }

    /// The modifiers that are active, as wl_keyboard.modifiers sends them.
    struct Modifiers: Equatable {
        var depressed: UInt32 = 0
        var latched: UInt32 = 0
        var locked: UInt32 = 0
        var group: UInt32 = 0
    }

    var handler: (Event) -> Void = { _ in }

    /// The keymap of the system, as xkb text. An app gets it in
    /// wl_keyboard.keymap, so that it reads the keys in the same way.
    private(set) var keymapText = ""

    private let seat: Seat
    private var udev: OpaquePointer?
    private var libinput: OpaquePointer?
    private var xkbContext: OpaquePointer?
    private var keymap: OpaquePointer?
    private var xkbState: OpaquePointer?

    // libinput opens devices through these callbacks; we pass them to the seat.
    nonisolated(unsafe) private static let interface = permanent(libinput_interface(
        open_restricted: { path, _, data in
            let input = Unmanaged<Input>.fromOpaque(data!).takeUnretainedValue()
            do { return try input.seat.openDevice(String(cString: path!)) } catch {
                log("input: \(error)")
                return -EACCES
            }
        },
        close_restricted: { fd, data in
            Unmanaged<Input>.fromOpaque(data!).takeUnretainedValue().seat.closeDevice(fd)
        }
    ))

    init(seat: Seat) throws(Failure) {
        self.seat = seat
        guard let context = xkb_context_new(XKB_CONTEXT_NO_FLAGS) else { throw .keymap }
        xkbContext = context
        var names = xkb_rule_names()   // system default layout (us)
        guard let keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS) else {
            throw .keymap
        }
        self.keymap = keymap
        xkbState = xkb_state_new(keymap)
        if let text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1) {
            keymapText = String(cString: text)
            free(text)
        }

        guard let udev = udev_new() else { throw .udev }
        self.udev = udev
        guard let libinput = libinput_udev_create_context(
            Input.interface, Unmanaged.passUnretained(self).toOpaque(), udev
        ) else { throw .libinput }
        self.libinput = libinput
        guard libinput_udev_assign_seat(libinput, seat.name) == 0 else { throw .libinput }
    }

    deinit {
        if let libinput { libinput_unref(libinput) }
        if let udev { udev_unref(udev) }
        if let xkbState { xkb_state_unref(xkbState) }
        if let keymap { xkb_keymap_unref(keymap) }
        if let xkbContext { xkb_context_unref(xkbContext) }
    }

    var fd: Int32 { libinput_get_fd(libinput) }

    /// Reads pending input and calls `handler` for each event.
    func dispatch() {
        libinput_dispatch(libinput)
        while let event = libinput_get_event(libinput) {
            handle(event)
            libinput_event_destroy(event)
        }
    }

    /// The modifier state of xkb, in the form that wl_keyboard wants.
    private func modifiers() -> Modifiers {
        Modifiers(
            depressed: xkb_state_serialize_mods(xkbState, XKB_STATE_MODS_DEPRESSED),
            latched: xkb_state_serialize_mods(xkbState, XKB_STATE_MODS_LATCHED),
            locked: xkb_state_serialize_mods(xkbState, XKB_STATE_MODS_LOCKED),
            group: xkb_state_serialize_layout(xkbState, XKB_STATE_LAYOUT_EFFECTIVE))
    }

    private func handle(_ event: OpaquePointer) {
        let type = libinput_event_get_type(event)
        switch type {
        case LIBINPUT_EVENT_POINTER_MOTION:
            let pointer = libinput_event_get_pointer_event(event)
            handler(.pointerMotion(dx: libinput_event_pointer_get_dx(pointer),
                                   dy: libinput_event_pointer_get_dy(pointer)))
        case LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE:
            let pointer = libinput_event_get_pointer_event(event)
            handler(.pointerPosition(x: libinput_event_pointer_get_absolute_x_transformed(pointer, 1),
                                     y: libinput_event_pointer_get_absolute_y_transformed(pointer, 1)))
        case LIBINPUT_EVENT_POINTER_BUTTON:
            let pointer = libinput_event_get_pointer_event(event)
            handler(.button(code: libinput_event_pointer_get_button(pointer),
                            pressed: libinput_event_pointer_get_button_state(pointer) == LIBINPUT_BUTTON_STATE_PRESSED))
        case LIBINPUT_EVENT_POINTER_SCROLL_WHEEL:
            scroll(event, source: .wheel)
        case LIBINPUT_EVENT_POINTER_SCROLL_FINGER, LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS:
            scroll(event, source: .finger)
        case LIBINPUT_EVENT_KEYBOARD_KEY:
            let keyboard = libinput_event_get_keyboard_event(event)
            // xkb keycodes are evdev codes + 8.
            let keycode = libinput_event_keyboard_get_key(keyboard) + 8
            let pressed = libinput_event_keyboard_get_key_state(keyboard) == LIBINPUT_KEY_STATE_PRESSED
            let keysym = xkb_state_key_get_one_sym(xkbState, keycode)
            xkb_state_update_key(xkbState, keycode, pressed ? XKB_KEY_DOWN : XKB_KEY_UP)
            handler(.key(Key(
                code: libinput_event_keyboard_get_key(keyboard),
                keysym: keysym,
                pressed: pressed,
                control: xkb_state_mod_name_is_active(xkbState, "Control", XKB_STATE_MODS_EFFECTIVE) > 0,
                alt: xkb_state_mod_name_is_active(xkbState, "Mod1", XKB_STATE_MODS_EFFECTIVE) > 0,
                modifiers: modifiers())))
        default:
            break
        }
    }

    /// One scroll event, on either axis or on both.
    private func scroll(_ event: OpaquePointer, source: ScrollSource) {
        let pointer = libinput_event_get_pointer_event(event)
        /// An axis that this event does not carry reads as no movement, and
        /// not as the value of the axis that it does carry.
        func value(_ axis: libinput_pointer_axis) -> Double {
            guard libinput_event_pointer_has_axis(pointer, axis) != 0 else { return 0 }
            return libinput_event_pointer_get_scroll_value(pointer, axis)
        }
        let dx = value(LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL)
        let dy = value(LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL)
        // libinput ends a touchpad gesture with a zero, which wl_pointer
        // says with axis_stop. Nothing here needs kinetic scrolling, so the
        // event that says "the fingers left" carries no movement and goes.
        guard dx != 0 || dy != 0 else { return }
        handler(.scroll(dx: dx, dy: dy, source: source))
    }
}
