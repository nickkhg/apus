import Toolkit

// The colours and the sizes of Settings. They are the colours of the design,
// written here because an app does not link the user interface of the
// system (see docs/apps.md). Every value has a name, so that a view never
// writes a number of its own.

/// The colours of the app.
public enum Ink {
    /// The window, behind everything.
    static let background = Color(hex: 0x0E1114)
    /// The list of the panes on the left.
    static let sidebar = Color(hex: 0x12161A)
    /// A card on the pane, and a control on the sidebar.
    static let card = Color(hex: 0x171C21)
    /// A control on a card.
    static let control = Color(hex: 0x1E252B)
    /// A place that takes text.
    static let field = Color(hex: 0x0E1114)
    /// A line between two parts of a card.
    static let divider = Color(hex: 0x232A31)

    /// The accent: the one colour that says "this has the keyboard", and
    /// the colour of a choice that is on.
    static let accent = Color(hex: 0xA9E34B)
    /// The accent, as the background of a control.
    static let accentSurface = Color(hex: 0x1D2A12)
    /// The mark of the app, in its bundle as well.
    public static let mark = Color(hex: 0x8E9BF0)

    static let good = Color(hex: 0x3BB273)
    static let warning = Color(hex: 0xE0A458)
    static let failure = Color(hex: 0xE0574B)
    static let failureSurface = Color(hex: 0x2A1614)

    /// Text and marks, from clear to faint.
    static let text = Color(hex: 0xF2F5F4)
    static let secondaryText = Color(hex: 0xA3AEB4)
    static let dimText = Color(hex: 0x6C777D)
    static let faintText = Color(hex: 0x444E54)
}

/// The sizes of the app, in points.
enum Metrics {
    static let sidebarWidth: Double = 212
    static let compactSidebarWidth: Double = 168
    static let sidebarRow: Double = 32
    static let panePadding: Double = 28
    static let compactPanePadding: Double = 18
    static let cardRadius: Double = 12
    static let cardSpacing: Double = 16
    static let row: Double = 44
    static let rowWithDetail: Double = 54
    static let rowPadding: Double = 16
    static let listRow: Double = 36
    static let controlRadius: Double = 7
    static let controlHeight: Double = 28
    static let fieldWidth: Double = 220
}

/// The moves of the app, as the shell names them.
enum Moves {
    /// A control answers the pointer at once.
    static let quick = Animation.easeOut(duration: 0.12)
}
