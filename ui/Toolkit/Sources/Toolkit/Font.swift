/// A font: which face to use and at which size. `Text` asks the font cache
/// for the face, and the cache loads it with FreeType.
public struct Font: Sendable, Equatable, Hashable {
    public enum Weight: Sendable, Hashable {
        case regular
        case bold
    }

    /// Points. One point is one pixel for now.
    public var size: Double
    public var weight: Weight
    /// A face where every glyph has the same width, for a terminal or code.
    public var isMonospaced: Bool

    public init(size: Double, weight: Weight = .regular, monospaced: Bool = false) {
        self.size = size
        self.weight = weight
        self.isMonospaced = monospaced
    }

    public static func system(size: Double, weight: Weight = .regular) -> Font {
        Font(size: size, weight: weight)
    }

    public static func monospaced(size: Double, weight: Weight = .regular) -> Font {
        Font(size: size, weight: weight, monospaced: true)
    }

    public static let largeTitle = Font(size: 32, weight: .bold)
    public static let title = Font(size: 22, weight: .bold)
    public static let headline = Font(size: 15, weight: .bold)
    public static let body = Font(size: 15)
    public static let caption = Font(size: 12)
}

extension Font {
    /// How wide `string` is in this font, in pixels, with nothing rounded.
    ///
    /// A layout works in whole points, so the size that `ViewRenderer` gives
    /// for a `Text` is rounded up to one. Code that puts characters in cells
    /// of its own needs the advance as the font has it: rounded, a cell
    /// drifts from the glyphs in it.
    public func width(of string: String) -> Double {
        FontCache.shared.shape(string, font: self).width
    }
}
