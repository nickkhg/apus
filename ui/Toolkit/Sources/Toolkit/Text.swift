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
                              color: environment.foregroundColor))
    }
}

/// Draws one line of text. It asks the font cache for the glyphs, then makes
/// one bitmap with the text in it, because the renderer draws bitmaps.
final class TextNode: LayoutNode {
    let string: String
    let font: Font
    let color: Color
    private let shaped: ShapedText

    init(string: String, font: Font, color: Color) {
        self.string = string
        self.font = font
        self.color = color
        shaped = FontCache.shared.shape(string, font: font)
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        // The text is as wide as its glyphs, whatever the parent proposes.
        // Only the height of a line comes from the font.
        Size(width: shaped.width.rounded(.up), height: shaped.height.rounded(.up))
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        guard !shaped.glyphs.isEmpty, color.alpha > 0 else { return }
        let width = Int(shaped.width.rounded(.up))
        let height = Int(shaped.height.rounded(.up))
        guard width > 0, height > 0 else { return }

        var pixels = [UInt32](repeating: 0, count: width * height)
        let baseline = shaped.ascent
        for glyph in shaped.glyphs {
            guard let image = FontCache.shared.image(of: glyph.id, font: font) else { continue }
            draw(image, x: glyph.x + Double(image.left), y: baseline + glyph.y - Double(image.top),
                 into: &pixels, width: width, height: height)
        }
        let bitmap = Bitmap(width: width, height: height, isOpaque: false, pixels: pixels)
        // The text sits at the top-left of its frame; a frame or a stack has
        // already put the frame where the alignment wants it.
        pass.list.append(.bitmap(bitmap, x: Int(frame.x.rounded()), y: Int(frame.y.rounded())))
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
