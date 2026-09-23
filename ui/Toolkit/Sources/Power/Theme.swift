import Toolkit

// The colours and the sizes of Power. They are the colours of the design,
// written here because an app does not link the user interface of the
// system (see docs/apps.md).

/// The colours of the app.
public enum Ink {
    static let background = Color(hex: 0x0E1114)
    static let card = Color(hex: 0x171C21)
    static let control = Color(hex: 0x1E252B)
    static let divider = Color(hex: 0x232A31)

    /// The mark of the app, in its bundle as well, and the colour of the
    /// charge.
    public static let mark = Color(hex: 0xA9E34B)
    static let good = Color(hex: 0x3BB273)
    static let warning = Color(hex: 0xE0A458)
    static let failure = Color(hex: 0xE0574B)
    /// The power that goes in or out.
    static let flow = Color(hex: 0x49C7C7)

    static let text = Color(hex: 0xF2F5F4)
    static let secondaryText = Color(hex: 0xA3AEB4)
    static let dimText = Color(hex: 0x6C777D)
    static let faintText = Color(hex: 0x444E54)

    /// The colour of a charge: the mark, then amber under a fifth, then
    /// red under a tenth.
    static func charge(_ percent: Double) -> Color {
        percent < 10 ? failure : percent < 20 ? warning : mark
    }
}

/// The sizes of the app, in points.
enum Metrics {
    static let cardRadius: Double = 14
    static let row: Double = 40
}
