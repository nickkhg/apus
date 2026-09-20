// The screen of the terminal: a grid of characters, and the parser that
// fills it from what the program prints.
//
// The program writes text and escape sequences. This file understands the
// part of the sequences that a shell, `ls` and an editor need:
//
//   the control characters  BS, TAB, LF, CR
//   CSI A B C D G H f d     move the cursor
//   CSI J K X               erase
//   CSI L M P @             insert and delete lines and characters
//   CSI S T                 scroll
//   CSI r                   the lines that scroll
//   CSI m                   colours and bold (SGR), with 256 colours
//   CSI ? h l               DEC settings; only "cursor visible" changes
//   ESC 7 8 M D E           save and restore the cursor, and move lines
//   OSC ... BEL/ST          the title and other text; read and dropped
//
// Anything else is read and dropped, so that it does not become text on the
// screen.

/// The colour of a character and of the space behind it.
public struct Style: Equatable, Sendable {
    public var foreground = Palette.foreground
    public var background = Palette.background
    public var bold = false
    public var inverse = false

    public init() {}

    /// The two colours as they are drawn.
    public var colors: (foreground: UInt32, background: UInt32) {
        inverse ? (background, foreground) : (foreground, background)
    }
}

/// One place on the screen.
public struct Cell: Equatable, Sendable {
    public var character: Character = " "
    public var style = Style()

    public init(character: Character = " ", style: Style = Style()) {
        self.character = character
        self.style = style
    }
}

/// The colours of the terminal: the 16 colours of a terminal, the 216 of the
/// colour cube, and 24 greys, as xterm numbers them.
public enum Palette {
    public static let foreground: UInt32 = 0xD8D8E0
    public static let background: UInt32 = 0x14111E

    public static let base: [UInt32] = [
        0x14111E, 0xE05561, 0x3BB273, 0xE0A458, 0x4C8DF6, 0xC678DD, 0x2DB5C0, 0xB0B0BC,
        0x5A5A68, 0xFF7A85, 0x5FD39A, 0xFFC177, 0x79ADFF, 0xE29BF2, 0x5FD7E0, 0xF0F0F8,
    ]

    /// The colour with this number, 0 to 255.
    public static func color(_ number: Int) -> UInt32 {
        if number < 16 { return base[max(0, number)] }
        if number < 232 {
            let value = number - 16
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            let red = steps[(value / 36) % 6]
            let green = steps[(value / 6) % 6]
            let blue = steps[value % 6]
            return red << 16 | green << 8 | blue
        }
        let grey = UInt32(8 + (min(number, 255) - 232) * 10)
        return grey << 16 | grey << 8 | grey
    }
}

/// The grid of characters, and where the next character goes.
public final class Screen {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var lines: [[Cell]]
    public private(set) var cursor = (row: 0, column: 0)
    public private(set) var isCursorVisible = true
    /// True when the screen changed and must be drawn again.
    public var hasChanged = true

    private var style = Style()
    private var savedCursor = (row: 0, column: 0)
    private var scrollTop = 0
    private var scrollBottom: Int
    /// The parser is in one of these while a sequence arrives.
    private enum State {
        case ground
        case escape
        case csi
        case osc
        case drop      // one more byte, and back to ground (character sets)
    }
    private var state = State.ground
    private var parameters = ""
    /// The bytes of the OSC that is being read.
    private var oscText: [UInt8] = []
    /// What the program in the terminal calls this window. A shell usually
    /// sets it to the directory and the command (OSC 0 or OSC 2). The tile
    /// of the terminal shows it.
    public private(set) var title = ""
    private var pendingBytes: [UInt8] = []

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        lines = Screen.emptyLines(columns: self.columns, rows: self.rows, style: Style())
        scrollBottom = self.rows - 1
    }

    private static func emptyLines(columns: Int, rows: Int, style: Style) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(character: " ", style: style), count: columns),
              count: rows)
    }

    /// Makes the screen another size. The text that is in it stays, as far as
    /// the new size holds it.
    public func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns)
        let newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }
        var result = Screen.emptyLines(columns: newColumns, rows: newRows, style: Style())
        // Keep the last lines: that is where the work is.
        let kept = min(newRows, rows)
        let first = rows - kept
        for row in 0..<kept {
            for column in 0..<min(newColumns, columns) {
                result[row][column] = lines[first + row][column]
            }
        }
        lines = result
        columns = newColumns
        rows = newRows
        cursor = (row: min(max(0, cursor.row - first), rows - 1), column: min(cursor.column, columns - 1))
        scrollTop = 0
        scrollBottom = rows - 1
        hasChanged = true
    }

    /// Reads what the program printed.
    public func write(_ bytes: [UInt8]) {
        for byte in bytes { consume(byte) }
        hasChanged = true
    }

    // MARK: - The parser

    private func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            escape(byte)
        case .csi:
            // Parameters and the bytes between them, then a final byte.
            if byte >= 0x20, byte <= 0x3F {
                parameters.append(Character(UnicodeScalar(byte)))
            } else if byte >= 0x40, byte <= 0x7E {
                control(final: Character(UnicodeScalar(byte)))
                state = .ground
            } else {
                state = .ground
            }
        case .osc:
            // A title and other text: it ends with BEL, or with ESC \.
            if byte == 0x07 {
                takeOSC()
                state = .ground
            } else if byte == 0x1B {
                takeOSC()
                state = .drop
            } else if oscText.count < 512 {
                // The bytes are kept, so that OSC 0 and OSC 2 can set the
                // title. They are decoded as UTF-8 at the end, because a
                // title can hold any character. A run that never ends stops
                // here, so that a program cannot fill memory with it.
                oscText.append(byte)
            }
        case .drop:
            state = .ground
        }
    }

    /// Reads an OSC that ended. `0` and `2` set the title of the window.
    private func takeOSC() {
        let bytes = oscText
        oscText = []
        guard let semicolon = bytes.firstIndex(of: 0x3B) else { return }   // ";"
        let code = String(decoding: bytes[..<semicolon], as: UTF8.self)
        guard code == "0" || code == "2" else { return }
        title = String(decoding: bytes[(semicolon + 1)...], as: UTF8.self)
    }

    private func ground(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            state = .escape
            parameters = ""
        case 0x07:
            break                       // the bell has no sound here
        case 0x08:
            cursor.column = max(0, cursor.column - 1)
        case 0x09:
            cursor.column = min(columns - 1, (cursor.column / 8 + 1) * 8)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            cursor.column = 0
        case 0x00...0x1F, 0x7F:
            break                       // the other control characters do nothing
        default:
            character(byte)
        }
    }

    /// Text is UTF-8: a character can be up to four bytes.
    private func character(_ byte: UInt8) {
        if byte < 0x80 {
            put(Character(UnicodeScalar(byte)))
            return
        }
        pendingBytes.append(byte)
        let first = pendingBytes[0]
        let length = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1
        guard pendingBytes.count >= length else { return }
        let text = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll(keepingCapacity: true)
        for character in text { put(character) }
    }

    private func escape(_ byte: UInt8) {
        state = .ground
        switch Character(UnicodeScalar(byte)) {
        case "[":
            state = .csi
            parameters = ""
        case "]":
            state = .osc
            oscText = []
        case "(", ")", "*", "+", "#", "%":
            state = .drop               // a character set: one byte more
        case "7":
            savedCursor = cursor
        case "8":
            cursor = (row: min(savedCursor.row, rows - 1), column: min(savedCursor.column, columns - 1))
        case "M":
            reverseLineFeed()
        case "D":
            lineFeed()
        case "E":
            cursor.column = 0
            lineFeed()
        case "c":
            reset()
        default:
            break
        }
    }

    /// One CSI sequence, for example "CSI 2 J".
    private func control(final: Character) {
        let isPrivate = parameters.hasPrefix("?")
        let text = isPrivate ? String(parameters.dropFirst()) : parameters
        let values = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ index: Int, _ fallback: Int = 1) -> Int {
            guard index < values.count, values[index] > 0 else { return fallback }
            return values[index]
        }

        if isPrivate {
            // Only "the cursor is visible" changes anything here.
            if values.first == 25 { isCursorVisible = (final == "h") }
            return
        }

        switch final {
        case "A": cursor.row = max(scrollTop, cursor.row - value(0))
        case "B": cursor.row = min(scrollBottom, cursor.row + value(0))
        case "C": cursor.column = min(columns - 1, cursor.column + value(0))
        case "D": cursor.column = max(0, cursor.column - value(0))
        case "E": cursor.row = min(rows - 1, cursor.row + value(0)); cursor.column = 0
        case "F": cursor.row = max(0, cursor.row - value(0)); cursor.column = 0
        case "G", "`": cursor.column = min(columns - 1, value(0) - 1)
        case "d": cursor.row = min(rows - 1, value(0) - 1)
        case "H", "f":
            cursor = (row: min(rows - 1, value(0) - 1), column: min(columns - 1, value(1) - 1))
        case "J": eraseInDisplay(values.first ?? 0)
        case "K": eraseInLine(values.first ?? 0)
        case "X": erase(count: value(0))
        case "L": insertLines(value(0))
        case "M": deleteLines(value(0))
        case "P": deleteCharacters(value(0))
        case "@": insertCharacters(value(0))
        case "S": scrollUp(value(0))
        case "T": scrollDown(value(0))
        case "r":
            scrollTop = min(rows - 1, value(0) - 1)
            scrollBottom = min(rows - 1, value(1, rows) - 1)
            if scrollBottom <= scrollTop { (scrollTop, scrollBottom) = (0, rows - 1) }
            cursor = (row: scrollTop, column: 0)
        case "s": savedCursor = cursor
        case "u": cursor = (row: min(savedCursor.row, rows - 1), column: min(savedCursor.column, columns - 1))
        case "m": select(graphics: values.isEmpty ? [0] : values)
        default: break
        }
    }

    /// SGR: the colours and bold.
    private func select(graphics values: [Int]) {
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0: style = Style()
            case 1: style.bold = true
            case 7: style.inverse = true
            case 21, 22: style.bold = false
            case 27: style.inverse = false
            case 30...37: style.foreground = Palette.color(value - 30)
            case 39: style.foreground = Palette.foreground
            case 40...47: style.background = Palette.color(value - 40)
            case 49: style.background = Palette.background
            case 90...97: style.foreground = Palette.color(value - 90 + 8)
            case 100...107: style.background = Palette.color(value - 100 + 8)
            case 38, 48:
                // 5;n is one of the 256 colours, 2;r;g;b is a colour of its own.
                let color: UInt32?
                if index + 2 < values.count, values[index + 1] == 5 {
                    color = Palette.color(values[index + 2])
                    index += 2
                } else if index + 4 < values.count, values[index + 1] == 2 {
                    color = UInt32(values[index + 2] & 0xFF) << 16
                        | UInt32(values[index + 3] & 0xFF) << 8
                        | UInt32(values[index + 4] & 0xFF)
                    index += 4
                } else {
                    color = nil
                }
                if let color {
                    if value == 38 { style.foreground = color } else { style.background = color }
                }
            default: break     // underline and the rest are not drawn yet
            }
            index += 1
        }
    }

    // MARK: - The grid

    private func put(_ character: Character) {
        if cursor.column >= columns {
            cursor.column = 0
            lineFeed()
        }
        lines[cursor.row][cursor.column] = Cell(character: character, style: style)
        cursor.column += 1
    }

    private func lineFeed() {
        if cursor.row == scrollBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    private func reverseLineFeed() {
        if cursor.row == scrollTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<max(1, count) {
            lines.remove(at: scrollTop)
            lines.insert(emptyLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<max(1, count) {
            lines.remove(at: scrollBottom)
            lines.insert(emptyLine(), at: scrollTop)
        }
    }

    private func insertLines(_ count: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        for _ in 0..<max(1, count) {
            lines.remove(at: scrollBottom)
            lines.insert(emptyLine(), at: cursor.row)
        }
    }

    private func deleteLines(_ count: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        for _ in 0..<max(1, count) {
            lines.remove(at: cursor.row)
            lines.insert(emptyLine(), at: scrollBottom)
        }
    }

    private func deleteCharacters(_ count: Int) {
        // After a character in the last column, the cursor stands one place
        // after it. The characters move from the last column then.
        let column = min(cursor.column, columns - 1)
        for _ in 0..<max(1, count) {
            lines[cursor.row].remove(at: column)
            lines[cursor.row].append(Cell(character: " ", style: style))
        }
    }

    private func insertCharacters(_ count: Int) {
        let column = min(cursor.column, columns - 1)
        for _ in 0..<max(1, count) {
            lines[cursor.row].insert(Cell(character: " ", style: style), at: column)
            lines[cursor.row].removeLast()
        }
    }

    private func erase(count: Int) {
        let last = min(columns, cursor.column + max(1, count))
        for column in cursor.column..<last {
            lines[cursor.row][column] = Cell(character: " ", style: style)
        }
    }

    private func eraseInLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 1: range = 0..<min(columns, cursor.column + 1)
        case 2: range = 0..<columns
        default: range = cursor.column..<columns
        }
        for column in range { lines[cursor.row][column] = Cell(character: " ", style: style) }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 1:
            for row in 0..<cursor.row { lines[row] = emptyLine() }
            eraseInLine(1)
        case 2, 3:
            for row in 0..<rows { lines[row] = emptyLine() }
        default:
            eraseInLine(0)
            for row in (cursor.row + 1)..<rows { lines[row] = emptyLine() }
        }
    }

    private func reset() {
        lines = Screen.emptyLines(columns: columns, rows: rows, style: Style())
        cursor = (row: 0, column: 0)
        style = Style()
        scrollTop = 0
        scrollBottom = rows - 1
        isCursorVisible = true
    }

    private func emptyLine() -> [Cell] {
        Array(repeating: Cell(character: " ", style: style), count: columns)
    }
}
