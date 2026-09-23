import Render

// A text of many lines, with a caret and a selection, that wraps at the
// edge of its frame and scrolls with the wheel.
//
//     TextEditor(note, isFocused: store.focus == .editor)
//
// The editor draws a `TextEditing` value; it does not keep one. The keys go
// to the app, which gives them to the value with `apply(_:)`. That is how
// the rest of the toolkit reads the keys too: a view has no focus, so the
// app knows which text the keys belong to.
//
// It is the smallest editor that a notes app needs:
//
// - The font is monospaced, so a column of the text is one width. The
//   caret and the selection then need no measure of each character, and a
//   line breaks at a number of columns.
// - A long line wraps at a space, or inside a word that is longer than the
//   whole line.
// - Up and Down go by the lines of the text, not by the rows that a wrap
//   makes.
// - The editor scrolls with the wheel. It scrolls by itself so that the
//   caret shows after it moves.
// - A handler of the toolkit gets no position, so a click cannot place the
//   caret.

public struct TextEditor: View {
    let editing: TextEditing
    let isFocused: Bool
    let font: Font
    let color: Color
    let caretColor: Color
    let selectionColor: Color
    @State private var offset = 0.0
    /// The caret that the editor last scrolled to, and the text it was in.
    @State private var revealed = -1

    public init(_ editing: TextEditing, isFocused: Bool,
                font: Font = .monospaced(size: 14),
                color: Color = Color(white: 0.95),
                caretColor: Color = Color(hex: 0xA9E34B),
                selectionColor: Color = Color(hex: 0xA9E34B, alpha: 0.28)) {
        self.editing = editing
        self.isFocused = isFocused
        self.font = Font(size: font.size, weight: font.weight, monospaced: true)
        self.color = color
        self.caretColor = caretColor
        self.selectionColor = selectionColor
    }

    public var body: some View {
        TextEditorArea(editing: editing, isFocused: isFocused, font: font, color: color,
                       caretColor: caretColor, selectionColor: selectionColor,
                       offset: $offset, revealed: $revealed)
    }
}

/// The part of the editor that lays out and draws.
struct TextEditorArea: View {
    typealias Body = Never
    let editing: TextEditing
    let isFocused: Bool
    let font: Font
    let color: Color
    let caretColor: Color
    let selectionColor: Color
    let offset: Binding<Double>
    let revealed: Binding<Int>

    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(TextEditorNode(area: self, scale: environment.scale))
    }
}

/// One row of the text on the screen: a line, or a part of a line that a
/// wrap made.
struct TextRow: Equatable {
    /// The characters of the row, as indices into the text. The newline at
    /// the end of a line is in no row.
    var range: Range<Int>
    /// The row is the last one of its line, so the caret at its end is on
    /// it and not at the start of the next row.
    var endsLine: Bool
}

extension TextEditing {
    /// The rows of the text when a row holds at most `columns` characters.
    /// A line breaks after its last space that fits, or at `columns` when
    /// no space fits.
    func rows(columns: Int) -> [TextRow] {
        let columns = max(1, columns)
        var rows: [TextRow] = []
        var start = 0
        while true {
            let end = lineEnd(of: start)
            var position = start
            while end - position > columns {
                var cut = position + columns
                if let space = characters[position..<(position + columns + 1)].lastIndex(of: " "),
                   space > position {
                    cut = space + 1
                }
                rows.append(TextRow(range: position..<cut, endsLine: false))
                position = cut
            }
            rows.append(TextRow(range: position..<end, endsLine: true))
            guard end < characters.count else { break }
            start = end + 1
        }
        return rows
    }

    /// The row that holds the caret, and its column in that row.
    func caretRow(in rows: [TextRow]) -> (row: Int, column: Int) {
        for (index, row) in rows.enumerated()
        where row.range.contains(caret) || (row.endsLine && caret == row.range.upperBound) {
            return (index, caret - row.range.lowerBound)
        }
        return (max(0, rows.count - 1), 0)
    }
}

final class TextEditorNode: LayoutNode {
    let area: TextEditorArea
    let scale: Double
    /// The width of one column, in points.
    let advance: Double
    /// The height of one row, in points.
    let lineHeight: Double
    private var cachedRows: (width: Double, rows: [TextRow])?

    /// Room at the right for the caret and the line that says where the
    /// view is.
    static let inset = 6.0

    init(area: TextEditorArea, scale: Double) {
        self.area = area
        self.scale = scale
        let drawn = Font(size: area.font.size * scale, weight: area.font.weight, monospaced: true)
        let width = drawn.width(of: "0") / scale
        advance = width > 0 ? width : area.font.size * 0.6
        lineHeight = (area.font.size * 1.5).rounded()
    }

    func rows(width: Double) -> [TextRow] {
        if let cachedRows, cachedRows.width == width { return cachedRows.rows }
        let columns = Int(((width - TextEditorNode.inset) / advance).rounded(.down))
        let rows = area.editing.rows(columns: columns)
        cachedRows = (width, rows)
        return rows
    }

    /// All of the width and the height that it is offered. With no width
    /// offered, the longest line; with no height, every row.
    override func computeSize(fitting proposal: Proposal) -> Size {
        let width: Double
        if let offered = proposal.width, offered.isFinite {
            width = offered
        } else {
            let longest = area.editing.rows(columns: Int.max / 2).map(\.range.count).max() ?? 0
            width = Double(longest) * advance + TextEditorNode.inset
        }
        let height: Double
        if let offered = proposal.height, offered.isFinite {
            height = offered
        } else {
            height = Double(rows(width: width).count) * lineHeight
        }
        return Size(width: width, height: height)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let rect = frame.pixels(scale: pass.scale)
        guard rect.width > 0, rect.height > 0 else { return }
        let editing = area.editing
        let rows = rows(width: frame.width)
        let contentHeight = Double(rows.count) * lineHeight
        let limit = max(0, contentHeight - frame.height)
        var shown = min(max(0, area.offset.wrappedValue), limit)

        // The caret moved: show its row with the least move.
        let caret = editing.caretRow(in: rows)
        if area.revealed.wrappedValue != editing.caret {
            let top = Double(caret.row) * lineHeight
            if top + lineHeight > shown + frame.height { shown = top + lineHeight - frame.height }
            if top < shown { shown = top }
            shown = min(max(0, shown), limit)
            area.revealed.wrappedValue = editing.caret
        }
        if shown != area.offset.wrappedValue { area.offset.wrappedValue = shown }

        let binding = area.offset
        pass.scrollRegions.append(ScrollRegion(frame: frame) { delta in
            let now = min(max(0, binding.wrappedValue), limit)
            let next = min(max(0, now + delta), limit)
            guard next != now else { return false }
            binding.wrappedValue = next
            return true
        })

        pass.list.append(.pushClip(rect))
        let first = max(0, Int(shown / lineHeight))
        let last = min(rows.count, Int((shown + frame.height) / lineHeight) + 1)
        let selection = editing.selection
        for index in first..<max(first, last) {
            let row = rows[index]
            let y = frame.y + Double(index) * lineHeight - shown
            if let selection {
                // A selection that goes on past the end of a line takes a
                // little of the space after it, so that a selected empty
                // line shows.
                let from = max(selection.lowerBound, row.range.lowerBound)
                var to = min(selection.upperBound, row.range.upperBound)
                var extra = 0.0
                if row.endsLine, selection.upperBound > row.range.upperBound,
                   selection.lowerBound <= row.range.upperBound {
                    to = row.range.upperBound
                    extra = advance / 2
                }
                if to > from || extra > 0 {
                    var path = Path()
                    path.addRectangle(x: frame.x + Double(from - row.range.lowerBound) * advance,
                                      y: y, width: Double(to - from) * advance + extra,
                                      height: lineHeight)
                    pass.list.append(.path(path.scaled(by: pass.scale),
                                           color: area.selectionColor.premultiplied))
                }
            }
            guard !row.range.isEmpty else { continue }
            // A tab would draw as nothing, or as a box. It takes one column,
            // so it draws as one space.
            let string = String(editing.characters[row.range].map { $0 == "\t" ? " " : $0 })
            let text = TextNode(string: string, font: area.font, color: area.color, scale: scale)
            // The text is drawn in the same place as its columns: from the
            // top of its row, with the space of the row around its line.
            let textHeight = text.size(fitting: Proposal(width: nil, height: nil)).height
            text.render(in: Frame(x: frame.x, y: y + ((lineHeight - textHeight) / 2).rounded(),
                                  width: frame.width, height: textHeight),
                        into: &pass)
        }
        if area.isFocused {
            let y = frame.y + Double(caret.row) * lineHeight - shown
            var path = Path()
            path.addRectangle(x: frame.x + Double(caret.column) * advance, y: y + 2,
                              width: 2, height: lineHeight - 4)
            pass.list.append(.path(path.scaled(by: pass.scale), color: area.caretColor.premultiplied))
        }
        if limit > 0 {
            let part = frame.height / contentHeight
            let length = max(24, frame.height * part)
            let top = frame.y + (frame.height - length) * (shown / limit)
            var line = Path()
            line.addRoundedRectangle(x: frame.x + frame.width - 3, y: top, width: 3,
                                     height: length, radius: 1.5)
            pass.list.append(.path(line.scaled(by: pass.scale),
                                   color: Color(white: 1, alpha: 0.16).premultiplied))
        }
        pass.list.append(.popClip)
    }
}
