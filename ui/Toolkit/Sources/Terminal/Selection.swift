// What a person has selected with the pointer, and the text of it.
//
// A selection is kept in the numbers that `Screen.scrolledLines` gives, and
// not in rows of the window. The lines under a selection move — the program
// prints, the view scrolls — and the selection stays on the words it was
// made on.

/// One place in the text: which line, and which column of it.
///
/// A place can stand one past the last column, which is where a drag that
/// left the right edge of the window ends.
public struct TextPosition: Equatable, Comparable, Sendable {
    /// The number of the line, as `Screen.scrolledLines` counts.
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (left: TextPosition, right: TextPosition) -> Bool {
        left.line == right.line ? left.column < right.column : left.line < right.line
    }
}

/// The text between the place a drag started and the place it has reached.
public struct Selection: Equatable, Sendable {
    /// Where the drag began. It does not move while the drag goes on.
    public var anchor: TextPosition
    /// Where the drag has reached.
    public var focus: TextPosition

    public init(anchor: TextPosition, focus: TextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    /// The two ends in the order they are read, whichever way the drag went.
    public var start: TextPosition { min(anchor, focus) }
    public var end: TextPosition { max(anchor, focus) }

    /// True when the drag has not left the place it began, so there is
    /// nothing selected and nothing to draw.
    public var isEmpty: Bool { anchor == focus }

    /// The columns of `line` that are in the selection, of a line that is
    /// `columns` wide. Nothing means that the line is not in it.
    ///
    /// The first line of a selection starts where the drag started, the last
    /// one ends where it reached, and the lines between are whole.
    public func columns(onLine line: Int, width columns: Int) -> Range<Int>? {
        guard !isEmpty, line >= start.line, line <= end.line else { return nil }
        let first = line == start.line ? start.column : 0
        let last = line == end.line ? end.column : columns
        let range = max(0, min(first, columns))..<max(0, min(last, columns))
        return range.isEmpty ? nil : range
    }
}

public extension Screen {
    /// The text of a selection, as it would be pasted.
    ///
    /// The spaces that a terminal leaves at the end of a line are not part of
    /// what a person selected: a grid is always as wide as the window, and
    /// the line ends where the text does. A line that the selection crosses
    /// completely therefore ends with a newline and no padding.
    func text(in selection: Selection) -> String {
        guard !selection.isEmpty else { return "" }
        var result = ""
        let first = max(selection.start.line, lineNumbers.lowerBound)
        let last = min(selection.end.line, lineNumbers.upperBound)
        guard first <= last else { return "" }
        for number in first...last {
            guard let line = line(number: number),
                  let range = selection.columns(onLine: number, width: line.count) else { continue }
            var text = String(line[range].map(\.character))
            // Only the end of a line is padding. A selection that stops in
            // the middle of a line keeps what it covers.
            if number < selection.end.line || selection.end.column >= line.count {
                while text.last == " " { text.removeLast() }
            }
            if number > first { result.append("\n") }
            result.append(text)
        }
        return result
    }

    /// The place in the text that a row of the window stands at. The row is
    /// counted from the top of what is drawn.
    func position(atRow row: Int, column: Int) -> TextPosition {
        TextPosition(line: firstVisibleLine + row, column: column)
    }
}
