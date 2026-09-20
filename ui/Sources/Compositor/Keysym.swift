// The key numbers of xkbcommon that the compositor itself acts on.
//
// The list is short, and it stays short: the shell reads the keys through
// the toolkit, which names the keys that it needs (see KeyEvent.Named), and
// every other key goes to the app that has the focus. Only the keys that
// belong to the compositor itself are here.
//
// The values are from xkbcommon-keysyms.h. They are written out because a C
// macro is not visible to Swift.
enum Keysym {
    static let superLeft: UInt32 = 0xFFEB
    static let superRight: UInt32 = 0xFFEC

    /// The character that a key writes, or nil when it writes none.
    ///
    /// A keysym below 0x100 is the Latin-1 character of the same value. The
    /// keys above that are the named ones: an arrow, a function key, a
    /// modifier. Those write nothing.
    static func character(of keysym: UInt32) -> Character? {
        guard keysym >= 0x20, keysym < 0x7F, let scalar = Unicode.Scalar(keysym) else {
            return nil
        }
        return Character(scalar)
    }
}
