import Toolkit

// The colours and the sizes of Notes. They are the colours of the design,
// written here because an app does not link the user interface of the
// system (see docs/apps.md).

/// The colours of the app.
public enum Ink {
    static let background = Color(hex: 0x0E1114)
    static let sidebar = Color(hex: 0x12161A)
    static let card = Color(hex: 0x171C21)
    static let control = Color(hex: 0x1E252B)
    static let divider = Color(hex: 0x232A31)

    /// The one colour that says "this has the keyboard".
    static let accent = Color(hex: 0xA9E34B)
    static let accentSurface = Color(hex: 0x1D2A12)
    /// The mark of the app, in its bundle as well.
    public static let mark = Color(hex: 0xF2C94C)
    static let good = Color(hex: 0x3BB273)
    static let failure = Color(hex: 0xE0574B)
    static let failureSurface = Color(hex: 0x2A1614)

    static let text = Color(hex: 0xF2F5F4)
    static let secondaryText = Color(hex: 0xA3AEB4)
    static let dimText = Color(hex: 0x6C777D)
    static let faintText = Color(hex: 0x444E54)
}

/// The sizes of the app, in points.
enum Metrics {
    static let listWidth: Double = 260
    static let compactListWidth: Double = 196
    static let head: Double = 52
    static let row: Double = 54
}

enum Moves {
    static let quick = Animation.easeOut(duration: 0.12)
}
