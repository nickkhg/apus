import Toolkit

// The colours and the sizes of the shell, from the design. Every value has a
// name, so that a view never writes a number of its own.
//
// The shell draws in one of two modes. CPU mode separates surfaces with a
// step in the background colour and a line of one point. GPU mode has a
// shadow and a blur to do that work, so it holds a smaller step and drops
// most of the lines. Neither mode is the other one with the effects turned
// off: each has its own values below.

/// How the shell draws depth. The compositor picks it from the hardware.
public enum RenderMode: String, Sendable {
    /// Solid colours, one-point lines, short motion. The software renderer.
    case cpu
    /// Shadows, blur and gradients. A renderer with a GPU behind it.
    case gpu
}

/// What differs between the two modes.
///
/// CPU mode separates one surface from another with a line of one point and
/// a large step in the background colour. GPU mode has a shadow and a blur
/// to do that work, so it holds a smaller step and drops most of the lines.
///
/// Neither mode is the other one with the effects turned off. Turn the
/// shadows off in GPU mode and the surfaces run together, which is the proof
/// that the two sets of values are not the same set.
public struct Appearance: Equatable, Sendable {
    public let mode: RenderMode

    public init(_ mode: RenderMode) {
        self.mode = mode
    }

    /// The line around a surface that floats. GPU mode draws a shadow there
    /// instead, so it needs no line.
    public var surfaceLine: Double {
        mode == .cpu ? 1 : 0
    }

    /// How dark the layer under a surface makes what is behind it. A blur
    /// does some of that work in GPU mode, so the layer is lighter.
    public var dim: Double {
        mode == .cpu ? 0.66 : 0.5
    }

    /// A surface over the canvas. CPU mode leans on the step between one
    /// colour and the next, so its surface stays near the desktop. GPU mode
    /// lifts the surface, because a shadow holds it off instead.
    public var surface: Color {
        mode == .cpu ? Palette.surface : Palette.surface.lightened(by: 0.04)
    }
}

/// The colours of the shell.
public enum Palette {
    /// The desktop, behind everything.
    public static let desktop = Color(hex: 0x07080A)
    /// A cell that holds nothing: the empty widget slot.
    public static let slot = Color(hex: 0x0E1114)
    /// The rail, and any surface that floats over the canvas.
    public static let surface = Color(hex: 0x12161A)
    /// A control on a surface.
    public static let control = Color(hex: 0x171C21)
    /// A line between two parts of a surface.
    public static let divider = Color(hex: 0x232A31)

    /// The accent: the one colour that says "this has the keyboard".
    public static let accent = Color(hex: 0xA9E34B)
    /// The accent, as the background of a control.
    public static let accentSurface = Color(hex: 0x1D2A12)
    /// The window that has the large cell.
    public static let principal = Color(hex: 0x3BB273)
    /// A window in a tile.
    public static let widget = Color(hex: 0x49C7C7)

    /// A notice that warns, and one that reports a failure.
    public static let warning = Color(hex: 0xE0A458)
    public static let error = Color(hex: 0xE0574B)

    /// Text and marks, from clear to faint.
    public static let text = Color(hex: 0xF2F5F4)
    public static let secondaryText = Color(hex: 0xA3AEB4)
    public static let dimText = Color(hex: 0x6C777D)
    public static let faintText = Color(hex: 0x444E54)
}

/// The sizes of the shell, in points.
public enum Metrics {
    /// The space around the canvas and between the cells.
    public static let gap: Double = 8
    /// The rail on the left edge.
    public static let railWidth: Double = 56
    public static let railRadius: Double = 16
    /// A control in the rail.
    public static let buttonSize: Double = 40
    public static let buttonRadius: Double = 12
    /// A line between the parts of the rail.
    public static let dividerWidth: Double = 24
    /// The bars of the track: one for each window.
    public static let trackWidth: Double = 24
    public static let principalBar: Double = 40
    public static let widgetBar: Double = 20
    public static let railBar: Double = 12
    public static let barSpacing: Double = 8
    /// The ring that says which window has the keyboard.
    public static let ringWidth: Double = 2
    /// The head above the large cell: the app, the title and the controls.
    public static let headHeight: Double = 32
    /// The corner of a cell.
    public static let cellRadius: Double = 14
}
