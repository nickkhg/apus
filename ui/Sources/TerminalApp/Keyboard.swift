import CXKBCommon
import Glibc

/// The keys of the compositor, as the bytes that a program in a terminal
/// reads from its input.
///
/// The compositor sends the keymap of the system, so the terminal reads the
/// keys in the same way as the rest of the system. xkbcommon gives the text
/// of a key; the keys that make no text (the arrows, for example) have
/// sequences of their own.
final class Keyboard {
    /// The keysyms that need a sequence, from xkbcommon-keysyms.h.
    private enum Key {
        static let backspace: UInt32 = 0xFF08
        static let tab: UInt32 = 0xFF09
        static let enter: UInt32 = 0xFF0D
        static let escape: UInt32 = 0xFF1B
        static let home: UInt32 = 0xFF50
        static let left: UInt32 = 0xFF51
        static let up: UInt32 = 0xFF52
        static let right: UInt32 = 0xFF53
        static let down: UInt32 = 0xFF54
        static let pageUp: UInt32 = 0xFF55
        static let pageDown: UInt32 = 0xFF56
        static let end: UInt32 = 0xFF57
        static let insert: UInt32 = 0xFF63
        static let keypadEnter: UInt32 = 0xFF8D
        static let delete: UInt32 = 0xFFFF
    }

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

    /// Reads the keymap that the compositor sent in a file. The terminal
    /// closes the file itself.
    func read(keymapFD fd: Int32, size: Int) {
        guard let context, size > 0,
              let memory = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), memory != MAP_FAILED else {
            report("can't read the keymap")
            return
        }
        defer { munmap(memory, size) }
        let text = memory.assumingMemoryBound(to: CChar.self)
        guard let newKeymap = xkb_keymap_new_from_string(
            context, text, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) else {
            report("the keymap of the compositor does not compile")
            return
        }
        if let state { xkb_state_unref(state) }
        if let keymap { xkb_keymap_unref(keymap) }
        keymap = newKeymap
        state = xkb_state_new(newKeymap)
    }

    /// The modifiers that the compositor reports (Shift, Control and the
    /// rest).
    func setModifiers(depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32) {
        guard let state else { return }
        xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group)
    }

    /// What a key that went down sends to the program. `code` is the code of
    /// the kernel, as wl_keyboard gives it; xkb adds 8 to it.
    func bytes(forKey code: UInt32) -> [UInt8] {
        guard let state else { return [] }
        let keycode = code + 8
        let keysym = xkb_state_key_get_one_sym(state, keycode)
        switch keysym {
        case Key.backspace: return [0x7F]
        case Key.enter, Key.keypadEnter: return [0x0D]
        case Key.tab: return [0x09]
        case Key.escape: return [0x1B]
        case Key.up: return sequence("A")
        case Key.down: return sequence("B")
        case Key.right: return sequence("C")
        case Key.left: return sequence("D")
        case Key.home: return sequence("H")
        case Key.end: return sequence("F")
        case Key.insert: return sequence("2~")
        case Key.delete: return sequence("3~")
        case Key.pageUp: return sequence("5~")
        case Key.pageDown: return sequence("6~")
        default: break
        }
        // The text of the key, with Control and Shift in it: Control+C is
        // one byte, 0x03.
        var buffer = [CChar](repeating: 0, count: 8)
        // xkbcommon gives the length that the text needs, which can be more
        // than the buffer holds. The buffer holds every key of a keymap.
        let count = xkb_state_key_get_utf8(state, keycode, &buffer, buffer.count)
        let length = min(Int(count), buffer.count - 1)
        guard length > 0 else { return [] }
        return buffer[0..<length].map { UInt8(bitPattern: $0) }
    }

    /// An escape sequence, for example ESC [ A for the arrow up.
    private func sequence(_ tail: String) -> [UInt8] {
        [0x1B, 0x5B] + Array(tail.utf8)
    }
}
