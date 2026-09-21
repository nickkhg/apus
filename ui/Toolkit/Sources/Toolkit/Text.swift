import Render

/// A line of text. It takes the font and the colour from the environment,
/// and it does not wrap: a long string keeps one line.
public struct Text: View {
    public typealias Body = Never
    let string: String

    public init(_ string: String) {
        self.string = string
    }

    public init<Value: CustomStringConvertible>(_ value: Value) {
        self.string = value.description
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(TextNode(string: string, font: environment.font,
                              color: environment.foregroundColor,
                              scale: environment.scale))
    }
}

/// Draws one line of text. It asks the font cache for the glyphs, then makes
/// one bitmap with the text in it, because the renderer draws bitmaps.
final class TextNode: LayoutNode {
    let string: String
    /// The font at the size that the glyphs are made at: the size in points
    /// multiplied by the scale of the screen.
    let font: Font
    let color: Color
    let scale: Double
    private let shaped: ShapedText

    init(string: String, font: Font, color: Color, scale: Double = 1) {
        self.string = string
        // The glyphs are made at the size that they are drawn at, so that
        // the text is sharp on a screen with more than one pixel to the
        // point. The layout below then works in points again.
        self.font = Font(size: font.size * scale, weight: font.weight,
                         monospaced: font.isMonospaced)
        self.color = color
        self.scale = scale
        shaped = FontCache.shared.shape(string, font: self.font)
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        // The text is as wide as its glyphs, unless the parent offers less.
        // Then it takes what it is offered and cuts itself when it draws.
        // Only the height of a line comes from the font. The glyphs are in
        // pixels, and a layout is in points.
        let natural = (shaped.width / scale).rounded(.up)
        var width = natural
        if let offered = proposal.width, offered.isFinite, offered < natural {
            width = max(0, offered)
        }
        return Size(width: width, height: (shaped.height / scale).rounded(.up))
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        guard !shaped.glyphs.isEmpty, color.alpha > 0 else { return }
        // The same line in the same colour at the same width is the same
        // picture, so it is drawn one time. A frame that draws it again
        // gets the same object back, and with it the texture that the GPU
        // renderer made for that object.
        let room = frame.width * scale
        let picture = FontCache.shared.picture(string, font: font, color: color, room: room) {
            // A line that is too long for its space ends in "…". The frame
            // is in points and the glyphs are in pixels.
            let shaped = fitted(to: room)
            guard !shaped.glyphs.isEmpty else { return nil }
            let width = Int(shaped.width.rounded(.up))
            let height = Int(shaped.height.rounded(.up))
            guard width > 0, height > 0 else { return nil }

            var pixels = [UInt32](repeating: 0, count: width * height)
            let baseline = shaped.ascent
            for glyph in shaped.glyphs {
                guard let image = FontCache.shared.image(of: glyph.id, font: font) else { continue }
                draw(image, x: glyph.x + Double(image.left),
                     y: baseline + glyph.y - Double(image.top),
                     into: &pixels, width: width, height: height)
            }
            return Bitmap(width: width, height: height, isOpaque: false, pixels: pixels)
        }
        guard let picture else { return }
        // The text sits at the top-left of its frame; a frame or a stack has
        // already put the frame where the alignment wants it. The frame is in
        // points and the bitmap is in pixels.
        pass.list.append(.bitmap(picture, x: Int((frame.x * pass.scale).rounded()),
                                 y: Int((frame.y * pass.scale).rounded())))
    }

    /// The text that fits in `room` pixels: the whole line, or as much of it
    /// as fits with "…" at the end.
    ///
    /// The search is over the characters of the string and not over the
    /// glyphs, because one glyph is not one character: a letter and the mark
    /// over it are two glyphs of one character, and some pairs of letters
    /// are one glyph. Cutting between glyphs would cut inside a character.
    private func fitted(to room: Double) -> ShapedText {
        guard room > 0, shaped.width > room else { return shaped }
        let characters = Array(string)
        guard !characters.isEmpty else { return shaped }

        // The longest prefix that still fits with the "…" after it.
        var low = 0, high = characters.count
        var best = FontCache.shared.shape("…", font: font)
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = FontCache.shared.shape(String(characters[0..<middle]) + "…", font: font)
            if candidate.width <= room {
                best = candidate
                low = middle
            } else {
                high = middle - 1
            }
        }
        return best
    }

    /// Multiplies the glyph's coverage by the colour and puts it in the image.
    private func draw(_ image: GlyphImage, x: Double, y: Double,
                      into pixels: inout [UInt32], width: Int, height: Int) {
        let left = Int(x.rounded())
        let top = Int(y.rounded())
        for row in 0..<image.height {
            let target = top + row
            guard target >= 0, target < height else { continue }
            for column in 0..<image.width {
                let coverage = image.coverage[row * image.width + column]
                guard coverage > 0 else { continue }
                let position = left + column
                guard position >= 0, position < width else { continue }
                let alpha = color.alpha * Double(coverage) / 255
                let over = color.opacity(Double(coverage) / 255).premultiplied
                let index = target * width + position
                // Glyphs can touch, so keep whatever is under this pixel.
                pixels[index] = alpha >= 1 ? over : TextNode.blend(over, under: pixels[index], alpha: alpha)
            }
        }
    }

    /// Source-over for premultiplied colours.
    private static func blend(_ over: UInt32, under: UInt32, alpha: Double) -> UInt32 {
        let inverse = UInt32(((1 - alpha) * 255).rounded())
        var result: UInt32 = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            let sum = ((over >> UInt32(shift)) & 0xFF) + (((under >> UInt32(shift)) & 0xFF) * inverse) / 255
            result |= min(sum, 0xFF) << UInt32(shift)
        }
        return result
    }
}
