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
        /// An X keysym (see xkbcommon-keysyms.h) with the modifiers active.
        case key(keysym: UInt32, pressed: Bool, control: Bool, alt: Bool)
    }

    var handler: (Event) -> Void = { _ in }

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
        case LIBINPUT_EVENT_KEYBOARD_KEY:
            let keyboard = libinput_event_get_keyboard_event(event)
            // xkb keycodes are evdev codes + 8.
            let keycode = libinput_event_keyboard_get_key(keyboard) + 8
            let pressed = libinput_event_keyboard_get_key_state(keyboard) == LIBINPUT_KEY_STATE_PRESSED
            let keysym = xkb_state_key_get_one_sym(xkbState, keycode)
            xkb_state_update_key(xkbState, keycode, pressed ? XKB_KEY_DOWN : XKB_KEY_UP)
            handler(.key(keysym: keysym, pressed: pressed,
                         control: xkb_state_mod_name_is_active(xkbState, "Control", XKB_STATE_MODS_EFFECTIVE) > 0,
                         alt: xkb_state_mod_name_is_active(xkbState, "Mod1", XKB_STATE_MODS_EFFECTIVE) > 0))
        default:
            break
        }
    }
}
