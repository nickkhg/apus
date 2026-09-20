import Render

/// A colour, with values from 0 to 1. A Color is also a view: it fills the
/// space that it gets.
public struct Color: View, Equatable, Sendable {
    public typealias Body = Never

    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Color.clamp(red)
        self.green = Color.clamp(green)
        self.blue = Color.clamp(blue)
        self.alpha = Color.clamp(alpha)
    }

    /// From 0xRRGGBB, as the rest of mydistro writes colours.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Grey, from 0 (black) to 1 (white).
    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    public static let clear = Color(white: 0, alpha: 0)
    public static let black = Color(white: 0)
    public static let white = Color(white: 1)
    public static let gray = Color(white: 0.5)
    public static let red = Color(red: 1, green: 0, blue: 0)
    public static let green = Color(red: 0, green: 1, blue: 0)
    public static let blue = Color(red: 0, green: 0, blue: 1)
    /// The mydistro accent colour.
    public static let accent = Color(hex: 0x965ADC)

    /// The same colour, nearer to black. 0 keeps it, 1 makes it black.
    public func darkened(by amount: Double) -> Color {
        let keep = 1 - Color.clamp(amount)
        return Color(red: red * keep, green: green * keep, blue: blue * keep, alpha: alpha)
    }

    public func opacity(_ alpha: Double) -> Color {
        Color(red: red, green: green, blue: blue, alpha: self.alpha * alpha)
    }

    var isOpaque: Bool { alpha >= 1 }

    /// 0xRRGGBB, for an opaque fill. The compositor uses it for the desktop.
    public var packed: UInt32 {
        (Color.byte(red) << 16) | (Color.byte(green) << 8) | Color.byte(blue)
    }

    /// 0xAARRGGBB with the colour multiplied by alpha, as the renderer
    /// wants it in a path item.
    public var premultiplied: UInt32 {
        (Color.byte(alpha) << 24)
            | (Color.byte(red * alpha) << 16)
            | (Color.byte(green * alpha) << 8)
            | Color.byte(blue * alpha)
    }

    private static func byte(_ value: Double) -> UInt32 {
        UInt32((clamp(value) * 255).rounded())
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(FillNode(color: self))
    }
}
