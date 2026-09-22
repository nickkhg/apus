import Testing
@testable import Terminal

// The lines that go off the top of the screen are kept, and a person scrolls
// back into them with the wheel. These tests write more lines than the screen
// holds and look at what the window would draw.

private func write(_ screen: Screen, _ text: String) {
    screen.write(Array(text.utf8))
}

/// The characters of a line of the view, without the spaces at the end.
private func shown(_ screen: Screen, _ row: Int) -> String {
    let text = String(screen.visibleLines[row].map(\.character))
    return String(text.reversed().drop { $0 == " " }.reversed())
}

/// A screen of `rows` lines with `count` numbered lines printed into it.
private func counted(_ count: Int, rows: Int = 4, columns: Int = 20) -> Screen {
    let screen = Screen(columns: columns, rows: rows)
    write(screen, (1...count).map { "line \($0)" }.joined(separator: "\r\n"))
    return screen
}

@Suite("Looking back over what scrolled away")
struct ScrollbackTests {
    @Test("A screen that has not scrolled has nothing above it")
    func nothingAboveAFreshScreen() {
        let screen = counted(3)
        #expect(screen.history.isEmpty)
        #expect(screen.scrollback == 0)
        #expect(!screen.isScrolledBack)
        #expect(screen.visibleLines.map(\.count) == screen.lines.map(\.count))
    }

    @Test("The lines that go off the top are kept")
    func linesThatGoOffTheTopAreKept() {
        let screen = counted(10)                 // four rows hold lines 7...10
        #expect(screen.history.count == 6)
        #expect(shown(screen, 0) == "line 7")
        #expect(shown(screen, 3) == "line 10")
    }

    @Test("Scrolling back shows the lines above, and the live screen below them")
    func scrollingBackShowsTheLinesAbove() {
        let screen = counted(10)
        screen.scrollBack(by: 2)
        #expect(screen.isScrolledBack)
        // Two lines from above, then the top of the live screen.
        #expect(shown(screen, 0) == "line 5")
        #expect(shown(screen, 1) == "line 6")
        #expect(shown(screen, 2) == "line 7")
        #expect(shown(screen, 3) == "line 8")
        #expect(screen.visibleLines.count == 4)
    }

    @Test("The view stops at the oldest line that was kept")
    func theViewStopsAtTheOldestLine() {
        let screen = counted(10)
        screen.scrollBack(by: 1000)
        #expect(screen.scrollback == screen.history.count)
        #expect(shown(screen, 0) == "line 1")
    }

    @Test("The view stops at the live screen and does not go past it")
    func theViewStopsAtTheLiveScreen() {
        let screen = counted(10)
        screen.scrollBack(by: 3)
        screen.scrollBack(by: -100)
        #expect(screen.scrollback == 0)
        #expect(shown(screen, 3) == "line 10")
    }

    @Test("Going back to the bottom shows the live screen again")
    func backToTheBottom() {
        let screen = counted(10)
        screen.scrollBack(by: 4)
        screen.scrollToBottom()
        #expect(!screen.isScrolledBack)
        #expect(shown(screen, 0) == "line 7")
    }

    @Test("New output does not pull the view away from what is being read")
    func newOutputLeavesTheViewWhereItIs() {
        let screen = counted(10)
        screen.scrollBack(by: 3)
        #expect(shown(screen, 0) == "line 4")
        write(screen, "\r\nline 11\r\nline 12")
        // The screen moved under the view; the same text is still in it.
        #expect(shown(screen, 0) == "line 4")
        #expect(screen.scrollback == 5)
    }

    @Test("A screen that draws on a part of itself adds nothing to the history")
    func aScrollingRegionIsNotHistory() {
        let screen = counted(10)
        let kept = screen.history.count
        // CSI 2;4r: the lines that scroll are 2 to 4, as an editor with a
        // heading sets them. What moves there is drawing, not printing.
        write(screen, "\u{1B}[2;4r\u{1B}[4;1Ha\r\nb\r\nc\r\nd")
        #expect(screen.history.count == kept)
    }

    @Test("Only so many lines are kept")
    func theHistoryHasALimit() {
        let screen = Screen(columns: 10, rows: 2)
        for index in 1...(Screen.historyLimit + 50) {
            write(screen, "\(index)\r\n")
        }
        #expect(screen.history.count == Screen.historyLimit)
        // The oldest lines went, so the view cannot reach line 1 any more.
        screen.scrollBack(by: Screen.historyLimit * 2)
        #expect(shown(screen, 0) != "1")
    }

    @Test("A window that changes width still shows the lines above it")
    func aResizeKeepsTheLinesAbove() {
        let screen = counted(10, rows: 4, columns: 20)
        screen.scrollBack(by: 3)
        screen.resize(columns: 8, rows: 4)
        // Every line of the view is as wide as the screen is now.
        #expect(screen.visibleLines.allSatisfy { $0.count == 8 })
        #expect(shown(screen, 0) == "line 4")
    }
}
