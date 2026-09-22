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
    /// A cell is one advance of the face wide, and every glyph of a
    /// monospaced face has the same advance. The width keeps its fraction:
    /// a whole number would make the grid step further than the glyphs do,
    /// and the text would drift to the left of its cells, one part of a
    /// pixel for each character.
    ///
    /// The width comes from the font itself and not from `ViewRenderer`,
    /// which rounds the size of a text up to a whole point. A cell that is
    /// a fraction of a pixel narrower than the advance makes a frame that
    /// is narrower than the text it holds, and a `Text` that does not fit
    /// its frame cuts itself and ends in "…". Over a line of a terminal
    /// that eats the last characters of every line.
    public init(font: Font) {
        self.font = font
        width = max(1, font.width(of: "M"))
        // A line has a little space over and under the characters.
        let line = ViewRenderer.size(of: Text("M").font(font), fitting: .unspecified)
        height = max(1, (line.height + 2).rounded(.up))
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

    /// The colour over the characters that are selected.
    ///
    /// It goes over the line, as the block at the cursor does, and it lets
    /// the characters through: output with colours in it stays readable, and
    /// no run has to be drawn twice.
    public static let selectionColor: UInt32 = 0x4C8DF6

    /// The items that draw `screen` in `frame`.
    public static func displayList(for screen: Screen, cell: CellSize, in frame: Rect,
                                   selection: Selection? = nil) -> DisplayList {
        var list: DisplayList = [.fill(frame, color: opaque(Palette.background))]
        // What the window draws is the live screen, or the lines above it
        // when a person has scrolled back into what went off the top.
        for (row, line) in screen.visibleLines.enumerated() {
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
            // The selection goes on after the runs of the line, so that it
            // covers the whole of what is selected and not one run of it.
            if let columns = selection?.columns(onLine: screen.firstVisibleLine + row,
                                                width: line.count) {
                let x = Double(frame.x) + Double(columns.lowerBound) * cell.width
                let width = Double(columns.count) * cell.width
                list.append(.fill(Rect(x: Int(x), y: Int(y),
                                       width: Int(width.rounded(.up)), height: Int(cell.height)),
                                  color: Color(hex: selectionColor, alpha: 0.35).premultiplied))
            }
        }
        // The cursor marks a place on the live screen. A view that stands
        // above it would put the block on a line that is not that one.
        if screen.isCursorVisible, !screen.isScrolledBack {
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
