import Testing
@testable import Terminal

// A selection is kept in line numbers that never repeat, so that the text
// under it can scroll without the selection moving off the words it was
// made on. These tests print lines, select some of them, and read the text.

private func write(_ screen: Screen, _ text: String) {
    screen.write(Array(text.utf8))
}

private func counted(_ count: Int, rows: Int = 4, columns: Int = 20) -> Screen {
    let screen = Screen(columns: columns, rows: rows)
    write(screen, (1...count).map { "line \($0)" }.joined(separator: "\r\n"))
    return screen
}

private func at(_ line: Int, _ column: Int) -> TextPosition {
    TextPosition(line: line, column: column)
}

@Suite("Selecting text")
struct SelectionTests {
    @Test("A line keeps its number however much scrolls past it")
    func aLineKeepsItsNumber() {
        let screen = counted(10)                 // four rows hold lines 7...10
        #expect(screen.scrolledLines == 6)
        #expect(screen.firstVisibleLine == 6)
        #expect(String(screen.line(number: 0)!.map(\.character)).hasPrefix("line 1"))
        #expect(String(screen.line(number: 9)!.map(\.character)).hasPrefix("line 10"))
        write(screen, "\r\nline 11")
        // The same number is the same text, though the window moved.
        #expect(String(screen.line(number: 0)!.map(\.character)).hasPrefix("line 1"))
        #expect(screen.firstVisibleLine == 7)
    }

    @Test("A place in the window is a place in the text")
    func aRowIsALine() {
        let screen = counted(10)
        #expect(screen.position(atRow: 0, column: 2) == at(6, 2))
        screen.scrollBack(by: 4)
        #expect(screen.position(atRow: 0, column: 2) == at(2, 2))
    }

    @Test("A drag inside one line gives the characters it covers")
    func insideOneLine() {
        let screen = counted(10)
        let selection = Selection(anchor: at(6, 0), focus: at(6, 4))
        #expect(screen.text(in: selection) == "line")
    }

    @Test("A drag backwards gives the same text as one forwards")
    func backwardsIsTheSame() {
        let screen = counted(10)
        let forwards = Selection(anchor: at(6, 0), focus: at(6, 4))
        let backwards = Selection(anchor: at(6, 4), focus: at(6, 0))
        #expect(screen.text(in: backwards) == screen.text(in: forwards))
    }

    @Test("A drag over several lines gives them with newlines between")
    func overSeveralLines() {
        let screen = counted(10)
        let selection = Selection(anchor: at(6, 0), focus: at(8, 6))
        #expect(screen.text(in: selection) == "line 7\nline 8\nline 9")
    }

    @Test("The spaces that fill out a line are not part of the text")
    func theFillingIsNotText() {
        let screen = counted(10, rows: 4, columns: 40)
        // Every row is 40 wide; the text on it is six characters.
        let selection = Selection(anchor: at(6, 0), focus: at(7, 40))
        #expect(screen.text(in: selection) == "line 7\nline 8")
    }

    @Test("A selection reaches into the lines that scrolled away")
    func intoTheLinesAbove() {
        let screen = counted(10)
        let selection = Selection(anchor: at(1, 0), focus: at(2, 6))
        #expect(screen.text(in: selection) == "line 2\nline 3")
    }

    @Test("A selection whose lines have gone gives what is left")
    func linesThatHaveGone() {
        let screen = Screen(columns: 10, rows: 2)
        for index in 1...(Screen.historyLimit + 20) { write(screen, "\(index)\r\n") }
        // Line 0 was dropped long ago; nothing is returned for it.
        let gone = Selection(anchor: at(0, 0), focus: at(1, 5))
        #expect(screen.text(in: gone) == "")
        #expect(screen.line(number: 0) == nil)
    }

    @Test("An empty selection selects nothing")
    func anEmptySelection() {
        let screen = counted(10)
        let selection = Selection(anchor: at(6, 3), focus: at(6, 3))
        #expect(selection.isEmpty)
        #expect(screen.text(in: selection) == "")
        #expect(selection.columns(onLine: 6, width: 20) == nil)
    }

    @Test("A line of a selection knows which of its columns are in it")
    func theColumnsOfALine() {
        let selection = Selection(anchor: at(2, 3), focus: at(5, 7))
        #expect(selection.columns(onLine: 1, width: 20) == nil)
        #expect(selection.columns(onLine: 2, width: 20) == 3..<20)    // the first
        #expect(selection.columns(onLine: 3, width: 20) == 0..<20)    // a whole one
        #expect(selection.columns(onLine: 5, width: 20) == 0..<7)     // the last
        #expect(selection.columns(onLine: 6, width: 20) == nil)
    }

    @Test("A place past the last column is kept inside the line")
    func pastTheLastColumn() {
        let selection = Selection(anchor: at(2, 0), focus: at(2, 99))
        #expect(selection.columns(onLine: 2, width: 20) == 0..<20)
    }
}
