import Render
import Testing
@testable import Terminal
import Toolkit

@Suite("The terminal as a tile")
struct TerminalWidgetTests {
    private func screen(_ text: String) -> Screen {
        let screen = Screen(columns: 40, rows: 10)
        screen.write(Array(text.utf8))
        return screen
    }

    private func items(_ view: some View, size: Int = 256) -> DisplayList {
        ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: size, height: size))
    }

    @Test("The tile draws text")
    func theTileDrawsText() {
        let list = items(TerminalWidget(screen: screen("make ui\r\ndone\r\n"),
                                        title: "~/apus — bash"))
        let texts = list.filter { if case .bitmap = $0 { true } else { false } }
        print("ITEMS \(list.count) TEXTS \(texts.count)")
        #expect(!texts.isEmpty)
    }

    @Test("The last lines of the shell are the ones that it shows")
    func itShowsTheLastLines() {
        let widget = TerminalWidget(screen: screen("one\r\ntwo\r\nthree\r\n"), title: "")
        #expect(widget.lastLines.suffix(3) == ["one", "two", "three"])
    }

    @Test("The empty end of the grid is not shown")
    func emptyRowsAreDropped() {
        let widget = TerminalWidget(screen: screen("only\r\n"), title: "")
        #expect(widget.lastLines == ["only"])
    }

    @Test("It shows no more lines than it has room for")
    func itStopsAtTheLineCount() {
        let text = (1...9).map { "line \($0)" }.joined(separator: "\r\n")
        let widget = TerminalWidget(screen: screen(text + "\r\n"), title: "", lineCount: 4)
        #expect(widget.lastLines.count == 4)
        #expect(widget.lastLines.last == "line 9")
    }
}
