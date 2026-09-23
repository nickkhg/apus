import Testing
@testable import Terminal

// The screen of the terminal reads what a program prints. These tests give
// it bytes and look at the grid, as the drawing code does.

private func write(_ screen: Screen, _ text: String) {
    screen.write(Array(text.utf8))
}

/// The characters of a line, without the spaces at the end.
private func line(_ screen: Screen, _ row: Int) -> String {
    let text = String(screen.lines[row].map(\.character))
    return String(text.reversed().drop { $0 == " " }.reversed())
}

@Suite("The terminal screen")
struct ScreenTests {
    @Test("Text goes into the grid, and the cursor moves with it")
    func textGoesIntoTheGrid() {
        let screen = Screen(columns: 20, rows: 5)
        write(screen, "hello")
        #expect(line(screen, 0) == "hello")
        #expect(screen.cursor == (row: 0, column: 5))
    }

    @Test("A return goes to the start of the line, and a line feed one line down")
    func returnAndLineFeed() {
        let screen = Screen(columns: 20, rows: 5)
        write(screen, "one\r\ntwo")
        #expect(line(screen, 0) == "one")
        #expect(line(screen, 1) == "two")
    }

    @Test("A line that is too long goes on in the next line")
    func longLineWraps() {
        let screen = Screen(columns: 4, rows: 3)
        write(screen, "abcdefg")
        #expect(line(screen, 0) == "abcd")
        #expect(line(screen, 1) == "efg")
    }

    @Test("The screen scrolls when the text passes the last line")
    func screenScrolls() {
        let screen = Screen(columns: 10, rows: 3)
        write(screen, "one\r\ntwo\r\nthree\r\nfour")
        #expect(line(screen, 0) == "two")
        #expect(line(screen, 1) == "three")
        #expect(line(screen, 2) == "four")
    }

    @Test("A backspace and a tab move the cursor")
    func backspaceAndTab() {
        let screen = Screen(columns: 20, rows: 3)
        write(screen, "ab\u{8}c")
        #expect(line(screen, 0) == "ac")
        write(screen, "\r\n\tx")
        #expect(screen.cursor.column == 9)
        #expect(screen.lines[1][8].character == "x")
    }

    @Test("CSI H puts the cursor at a place, and CSI 2 J erases the screen")
    func cursorPositionAndErase() {
        let screen = Screen(columns: 10, rows: 4)
        write(screen, "first\r\nsecond")
        write(screen, "\u{1B}[1;1Hx")
        #expect(line(screen, 0) == "xirst")
        write(screen, "\u{1B}[2J")
        #expect(line(screen, 0) == "")
        #expect(line(screen, 1) == "")
    }

    @Test("CSI K erases the rest of the line")
    func eraseInLine() {
        let screen = Screen(columns: 10, rows: 2)
        write(screen, "abcdef\u{1B}[4G\u{1B}[K")
        #expect(line(screen, 0) == "abc")
    }

    @Test("The cursor keys move the cursor and do not print")
    func cursorMoves() {
        let screen = Screen(columns: 10, rows: 4)
        write(screen, "\u{1B}[3;5H")
        #expect(screen.cursor == (row: 2, column: 4))
        write(screen, "\u{1B}[2A\u{1B}[3D")
        #expect(screen.cursor == (row: 0, column: 1))
    }

    @Test("CSI m gives the text a colour, and CSI 0 m takes it back")
    func colors() {
        let screen = Screen(columns: 10, rows: 2)
        write(screen, "\u{1B}[31mred\u{1B}[0mplain")
        #expect(screen.lines[0][0].style.foreground == Palette.color(1))
        #expect(screen.lines[0][3].style.foreground == Palette.foreground)
    }

    @Test("CSI 1 m is bold, and CSI 38;5;n m is one of the 256 colours")
    func boldAndTheColorCube() {
        let screen = Screen(columns: 10, rows: 2)
        write(screen, "\u{1B}[1mB\u{1B}[22m\u{1B}[38;5;196mC")
        #expect(screen.lines[0][0].style.bold)
        #expect(!screen.lines[0][1].style.bold)
        #expect(screen.lines[0][1].style.foreground == Palette.color(196))
    }

    @Test("The title of a window is read and dropped, not printed")
    func operatingSystemCommand() {
        let screen = Screen(columns: 20, rows: 2)
        write(screen, "\u{1B}]0;a title\u{7}text")
        #expect(line(screen, 0) == "text")
        #expect(screen.bells == 0)
    }

    @Test("A bell prints nothing, and the screen counts it")
    func bell() {
        let screen = Screen(columns: 20, rows: 2)
        write(screen, "a\u{7}b\u{7}\u{7}")
        #expect(line(screen, 0) == "ab")
        #expect(screen.bells == 3)
    }

    @Test("A sequence that the terminal does not know prints nothing")
    func unknownSequence() {
        let screen = Screen(columns: 20, rows: 2)
        write(screen, "\u{1B}[?2004hok")
        #expect(line(screen, 0) == "ok")
    }

    @Test("Characters of more than one byte arrive whole")
    func utf8() {
        let screen = Screen(columns: 10, rows: 2)
        let bytes = Array("é→".utf8)
        for byte in bytes { screen.write([byte]) }   // one byte at a time
        #expect(line(screen, 0) == "é→")
    }

    @Test("CSI P deletes characters and CSI @ makes space for them")
    func deleteAndInsertCharacters() {
        let screen = Screen(columns: 10, rows: 2)
        write(screen, "abcdef\u{1B}[1G\u{1B}[2P")
        #expect(line(screen, 0) == "cdef")
        write(screen, "\u{1B}[1G\u{1B}[1@x")
        #expect(line(screen, 0) == "xcdef")
    }

    @Test("CSI L and CSI M move the lines under the cursor")
    func insertAndDeleteLines() {
        let screen = Screen(columns: 10, rows: 4)
        write(screen, "one\r\ntwo\r\nthree")
        write(screen, "\u{1B}[1;1H\u{1B}[1L")
        #expect(line(screen, 0) == "")
        #expect(line(screen, 1) == "one")
        write(screen, "\u{1B}[1;1H\u{1B}[1M")
        #expect(line(screen, 0) == "one")
    }

    @Test("The lines that scroll can be a part of the screen")
    func scrollRegion() {
        let screen = Screen(columns: 10, rows: 4)
        write(screen, "\u{1B}[2;3r")            // lines 2 and 3 scroll
        write(screen, "\u{1B}[2;1Ha\r\nb\r\nc")
        #expect(line(screen, 0) == "")
        #expect(line(screen, 1) == "b")
        #expect(line(screen, 2) == "c")
    }

    @Test("A new size keeps the last lines")
    func resizeKeepsTheText() {
        let screen = Screen(columns: 20, rows: 3)
        write(screen, "one\r\ntwo\r\nthree")
        screen.resize(columns: 20, rows: 2)
        #expect(line(screen, 0) == "two")
        #expect(line(screen, 1) == "three")
    }

    @Test("The cursor can be hidden")
    func cursorVisibility() {
        let screen = Screen(columns: 10, rows: 2)
        #expect(screen.isCursorVisible)
        write(screen, "\u{1B}[?25l")
        #expect(!screen.isCursorVisible)
        write(screen, "\u{1B}[?25h")
        #expect(screen.isCursorVisible)
    }
}

@Suite("The title of the window")
struct TitleTests {
    /// Writes bytes into a screen and gives it back.
    private func screen(_ text: String, columns: Int = 20, rows: Int = 4) -> Screen {
        let screen = Screen(columns: columns, rows: rows)
        screen.write(Array(text.utf8))
        return screen
    }

    @Test("A window has no title until a program sets one")
    func noTitleAtFirst() {
        #expect(screen("hello").title == "")
    }

    @Test("OSC 0 sets the title, and BEL ends it")
    func oscZeroSetsTheTitle() {
        #expect(screen("\u{1B}]0;~/apus — bash\u{07}").title == "~/apus — bash")
    }

    @Test("OSC 2 sets the title as well")
    func oscTwoSetsTheTitle() {
        #expect(screen("\u{1B}]2;make ui\u{07}").title == "make ui")
    }

    @Test("ESC backslash ends a title as BEL does")
    func stringTerminatorEndsTheTitle() {
        #expect(screen("\u{1B}]0;done\u{1B}\\").title == "done")
    }

    @Test("Another OSC code leaves the title alone")
    func otherCodesAreIgnored() {
        let screen = screen("\u{1B}]0;kept\u{07}\u{1B}]8;;https://example.com\u{07}")
        #expect(screen.title == "kept")
    }

    @Test("The text of an OSC never reaches the grid")
    func theTitleIsNotDrawn() {
        let screen = screen("\u{1B}]0;hidden\u{07}ab")
        let first = String(screen.lines[0].map(\.character)).trimmingCharactersInSpaces()
        #expect(first == "ab")
        #expect(screen.title == "hidden")
    }

    @Test("A title that never ends does not grow without limit")
    func anEndlessTitleStops() {
        let screen = Screen(columns: 20, rows: 4)
        screen.write(Array("\u{1B}]0;".utf8))
        screen.write([UInt8](repeating: 0x41, count: 4000))
        // The screen is still usable, and the title is not set until it ends.
        #expect(screen.title == "")
    }
}

extension String {
    func trimmingCharactersInSpaces() -> String {
        var text = self
        while text.last == " " { text.removeLast() }
        return text
    }
}
