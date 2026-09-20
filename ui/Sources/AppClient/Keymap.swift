import CXKBCommon
import Glibc
import Toolkit

/// Turns the keys of the compositor into the keys that a view reads.
///
/// The compositor sends the keymap of the system in a file, so an app reads
/// the keys in the same way as everything else. xkbcommon says what a key
/// means and what it writes; `KeyEvent` is what a view sees.
final class Keymap {
    private var context: OpaquePointer?
    private var keymap: OpaquePointer?
    private var state: OpaquePointer?

    init() {
        context = xkb_context_new(XKB_CONTEXT_NO_FLAGS)
    }

    deinit {
        if let state { xkb_state_unref(state) }
        if let keymap { xkb_keymap_unref(keymap) }
        if let context { xkb_context_unref(context) }
    }

    /// Reads the keymap that the compositor sent. The caller closes the file.
    func read(fd: Int32, size: Int) {
        guard let context, size > 0,
              let memory = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              memory != MAP_FAILED else {
            Console.report("the keymap of the compositor cannot be read")
            return
        }
        defer { munmap(memory, size) }
        guard let new = xkb_keymap_new_from_string(
            context, memory.assumingMemoryBound(to: CChar.self),
            XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) else {
            Console.report("the keymap of the compositor does not compile")
            return
        }
        if let state { xkb_state_unref(state) }
        if let keymap { xkb_keymap_unref(keymap) }
        keymap = new
        state = xkb_state_new(new)
    }

    /// The modifiers, as wl_keyboard.modifiers sends them.
    func setModifiers(depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32) {
        guard let state else { return }
        xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group)
    }

    /// One key of the compositor, as a view reads it. `code` is the key of
    /// the kernel; xkb counts from eight higher.
    func event(code: UInt32, pressed: Bool) -> KeyEvent? {
        guard let state else { return nil }
        let keycode = code + 8
        let keysym = xkb_state_key_get_one_sym(state, keycode)
        var buffer = [CChar](repeating: 0, count: 16)
        let written = xkb_state_key_get_utf8(state, keycode, &buffer, buffer.count)
        let length = min(Int(written), buffer.count - 1)
        let characters = length > 0 ? String(cString: buffer) : ""
        return KeyEvent(
            keysym: keysym,
            // A key that writes a control character writes nothing that a
            // view can put in a line of text.
            characters: characters.unicodeScalars.allSatisfy { $0.value >= 0x20 }
                ? characters : "",
            isPressed: pressed,
            control: xkb_state_mod_name_is_active(state, "Control", XKB_STATE_MODS_EFFECTIVE) > 0,
            alt: xkb_state_mod_name_is_active(state, "Mod1", XKB_STATE_MODS_EFFECTIVE) > 0,
            shift: xkb_state_mod_name_is_active(state, "Shift", XKB_STATE_MODS_EFFECTIVE) > 0)
    }
}
