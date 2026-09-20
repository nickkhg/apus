// The key numbers of xkbcommon that the compositor itself acts on. Every
// other key goes to the window that has the focus, so this list stays short.
//
// The values are from xkbcommon-keysyms.h. They are written here because the
// compositor compares them in plain Swift, and a C macro is not visible to
// Swift.
enum Keysym {
    static let backspace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let enter: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let up: UInt32 = 0xFF52
    static let down: UInt32 = 0xFF54
    static let keypadEnter: UInt32 = 0xFF8D
    static let superLeft: UInt32 = 0xFFEB
    static let superRight: UInt32 = 0xFFEC

    /// The character that a key makes, or nil when it makes none.
    ///
    /// A keysym below 0x100 is the Latin-1 character of the same value. The
    /// keys above that are the named keys: an arrow, a function key, a
    /// modifier. Those write nothing.
    static func character(of keysym: UInt32) -> Character? {
        guard keysym >= 0x20, keysym < 0x7F, let scalar = Unicode.Scalar(keysym) else {
            return nil
        }
        return Character(scalar)
    }
}
