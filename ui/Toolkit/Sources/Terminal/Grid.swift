import Render
import Toolkit

// How the grid of characters becomes drawing items. The terminal uses the
// toolkit for the text: the same font code that the shell uses.

/// The size of one character of the terminal font.
public struct CellSize: Sendable {
    public let font: Font
    public let width: Double
    public let height: Double

    /// Measures the font.
    ///
    /// The measured width of a piece of text is the advances of its
    /// characters plus a small constant. Dividing one measurement by the
    /// number of characters therefore gives a width that is a little too
    /// large, and the grid then steps further than the glyphs do: the text
    /// drifts to the left of its cells, one part of a pixel for each
    /// character, and the cursor ends up to the right of the character that
    /// it marks.
    ///
    /// Two measurements that differ by a known number of characters cancel
    /// the constant and give the advance exactly. The width keeps its
    /// fraction, because a whole number would bring the same drift back.
    public init(font: Font) {
        self.font = font
        let steps = 20
        let one = ViewRenderer.size(of: Text("M").font(font), fitting: .unspecified)
        let many = ViewRenderer.size(of: Text(String(repeating: "M", count: steps + 1)).font(font),
                                     fitting: .unspecified)
        width = max(1, (many.width - one.width) / Double(steps))
        // A line has a little space over and under the characters.
        height = max(1, (one.height + 2).rounded(.up))
    }

    /// How many characters fit in this many pixels.
    public func columns(in width: Double) -> Int { max(1, Int(width / self.width)) }
    public func rows(in height: Double) -> Int { max(1, Int(height / self.height)) }
}

/// One piece of a line that has the same colours.
private struct Run {
    var text: String
    var style: Style
    var column: Int
}

public enum Grid {
    /// A colour of the terminal, as the renderer wants it. Every colour of a
    /// terminal is opaque, so the alpha byte is always 255.
    private static func opaque(_ rgb: UInt32) -> UInt32 { rgb | 0xFF00_0000 }

    /// The items that draw `screen` in `frame`.
    public static func displayList(for screen: Screen, cell: CellSize, in frame: Rect) -> DisplayList {
        var list: DisplayList = [.fill(frame, color: opaque(Palette.background))]
        for (row, line) in screen.lines.enumerated() {
            let y = Double(frame.y) + Double(row) * cell.height
            for run in runs(of: line) {
                let x = Double(frame.x) + Double(run.column) * cell.width
                let width = Double(run.text.count) * cell.width
                let colors = run.style.colors
                if colors.background != Palette.background {
                    list.append(.fill(Rect(x: Int(x), y: Int(y),
                                           width: Int(width.rounded(.up)), height: Int(cell.height)),
                                      color: opaque(colors.background)))
                }
                guard run.text.contains(where: { $0 != " " }) else { continue }
                let font = Font(size: cell.font.size, weight: run.style.bold ? .bold : .regular,
                                monospaced: true)
                let text = Text(run.text)
                    .font(font)
                    .foregroundColor(Color(hex: colors.foreground))
                    .frame(width: width, height: cell.height, alignment: .leading)
                list += ViewRenderer.displayList(
                    for: text,
                    in: Rect(x: Int(x), y: Int(y), width: Int(width.rounded(.up)),
                             height: Int(cell.height)))
            }
        }
        if screen.isCursorVisible {
            list.append(cursor(of: screen, cell: cell, in: frame))
        }
        return list
    }

    /// A light block over the character at the cursor. The character stays
    /// readable through it.
    private static func cursor(of screen: Screen, cell: CellSize, in frame: Rect) -> DisplayItem {
        let x = Double(frame.x) + Double(screen.cursor.column) * cell.width
        let y = Double(frame.y) + Double(screen.cursor.row) * cell.height
        var path = Path()
        path.addRectangle(x: x, y: y, width: cell.width, height: cell.height)
        return .path(path, color: Color(white: 1, alpha: 0.45).premultiplied)
    }

    /// The pieces of a line that have the same colours. The spaces at the
    /// end of a line are not drawn.
    private static func runs(of line: [Cell]) -> [Run] {
        var runs: [Run] = []
        var last = line.count
        while last > 0, line[last - 1].character == " ",
              line[last - 1].style.colors.background == Palette.background {
            last -= 1
        }
        var current: Run?
        for column in 0..<last {
            let cell = line[column]
            if var run = current, run.style == cell.style {
                run.text.append(cell.character)
                current = run
            } else {
                if let run = current { runs.append(run) }
                current = Run(text: String(cell.character), style: cell.style, column: column)
            }
        }
        if let run = current { runs.append(run) }
        return runs
    }
}
