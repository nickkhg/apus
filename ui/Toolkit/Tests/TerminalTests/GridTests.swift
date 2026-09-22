import Render
@testable import Terminal
import Testing
import Toolkit

// The grid becomes drawing items: a background, the text of each line, and a
// block at the cursor.

private let cell = CellSize(font: .monospaced(size: 14))
private let frame = Rect(x: 0, y: 0, width: 400, height: 200)

private func items(_ screen: Screen) -> DisplayList {
    Grid.displayList(for: screen, cell: cell, in: frame)
}

@Suite("The terminal grid")
struct GridTests {
    @Test("A character is as wide as the others")
    func cellSizeIsTheSameForEveryCharacter() {
        let narrow = ViewRenderer.size(of: Text("i").font(cell.font), fitting: .unspecified)
        let wide = ViewRenderer.size(of: Text("W").font(cell.font), fitting: .unspecified)
        #expect(narrow.width == wide.width)
        // A measurement is rounded up to a whole point, so the cell is a
        // little narrower than one.
        #expect(cell.width <= narrow.width)
        #expect(narrow.width - cell.width <= 1)
    }

    @Test("The first item fills the window with the background colour")
    func backgroundFirst() {
        let screen = Screen(columns: 20, rows: 5)
        guard case .fill(let rect, let color) = items(screen).first else {
            Issue.record("the first item is not a fill")
            return
        }
        #expect(rect == frame)
        #expect(color == Palette.background | 0xFF00_0000)
    }

    @Test("An empty screen draws only the background and the cursor")
    func emptyScreen() {
        let screen = Screen(columns: 20, rows: 5)
        #expect(items(screen).count == 2)
    }

    @Test("A line of text is drawn at the place of its line")
    func textIsAtTheRightPlace() {
        let screen = Screen(columns: 20, rows: 5)
        screen.write(Array("\u{1B}[3;1Hhello".utf8))
        let bitmaps = items(screen).compactMap { item -> (Int, Int)? in
            if case .bitmap(_, let x, let y) = item { (x, y) } else { nil }
        }
        #expect(bitmaps.count == 1)
        #expect(bitmaps.first?.0 == 0)
        // The text is in the band of the third line. It is in the middle of
        // the line, so its top is a little under the top of the line.
        let top = bitmaps.first?.1 ?? -1
        #expect(Double(top) >= cell.height * 2)
        #expect(Double(top) < cell.height * 3)
    }

    @Test("The colours of a line make one run each")
    func runsPerColor() {
        let screen = Screen(columns: 20, rows: 2)
        screen.write(Array("\u{1B}[31mred\u{1B}[32mgreen".utf8))
        let bitmaps = items(screen).filter { if case .bitmap = $0 { true } else { false } }
        #expect(bitmaps.count == 2)
    }

    @Test("A colour behind the text fills the cells")
    func backgroundRun() {
        let screen = Screen(columns: 20, rows: 2)
        screen.write(Array("\u{1B}[44mfour".utf8))
        let fills = items(screen).filter { if case .fill = $0 { true } else { false } }
        // The window, and the four cells behind the word.
        #expect(fills.count == 2)
        guard case .fill(let rect, let color) = fills.last else { return }
        #expect(color == Palette.color(4) | 0xFF00_0000)
        #expect(rect.width == Int((cell.width * 4).rounded(.up)))
    }

    @Test("The cursor is a block over its cell")
    func cursorBlock() {
        let screen = Screen(columns: 20, rows: 5)
        screen.write(Array("ab".utf8))
        guard case .path(let path, let color) = items(screen).last else {
            Issue.record("the last item is not the cursor")
            return
        }
        #expect(color >> 24 > 0, "the block lets the character through")
        var left = Double.infinity
        for element in path.elements {
            if case .move(let x, _) = element { left = min(left, x) }
            if case .line(let x, _) = element { left = min(left, x) }
        }
        #expect(left == cell.width * 2)
    }

    @Test("A hidden cursor draws nothing")
    func hiddenCursor() {
        let screen = Screen(columns: 20, rows: 5)
        screen.write(Array("\u{1B}[?25l".utf8))
        #expect(items(screen).count == 1)
    }
}

@Suite("The grid when a person has scrolled back")
struct ScrolledBackGridTests {
    @Test("The view above the live screen is what gets drawn")
    func theViewAboveIsDrawn() {
        let screen = Screen(columns: 20, rows: 4)
        screen.write(Array((1...10).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        let live = items(screen).count
        screen.scrollBack(by: 3)
        // Four lines of text are drawn either way, so the same items come
        // out; only the cursor is gone.
        #expect(items(screen).count == live - 1)
    }

    @Test("The cursor is not drawn above the live screen")
    func noCursorAboveTheLiveScreen() {
        let screen = Screen(columns: 20, rows: 4)
        screen.write(Array((1...10).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        func hasCursor(_ list: DisplayList) -> Bool {
            list.contains { if case .path = $0 { true } else { false } }
        }
        #expect(hasCursor(items(screen)))
        screen.scrollBack(by: 1)
        #expect(!hasCursor(items(screen)))
        screen.scrollToBottom()
        #expect(hasCursor(items(screen)))
    }
}

@Suite("The cell size")
struct CellSizeTests {
    private let font = Font.monospaced(size: 15)

    @Test("The cell width is the advance of the font, so the grid follows the glyphs")
    func theCellWidthIsTheAdvance() {
        let cell = CellSize(font: font)
        // The advance from two measurements that differ by 40 characters.
        let one = ViewRenderer.size(of: Text("M").font(font), fitting: .unspecified).width
        let many = ViewRenderer.size(of: Text(String(repeating: "M", count: 41)).font(font),
                                     fitting: .unspecified).width
        // Each measurement is rounded to a whole pixel, so an advance taken
        // over 40 characters can be out by a fortieth of a pixel.
        #expect(abs((many - one) / 40 - cell.width) < 0.1)
    }

    @Test("A long line does not drift away from its cells")
    func aLongLineDoesNotDrift() {
        let cell = CellSize(font: font)
        let columns = 60
        let line = String(repeating: "M", count: columns)
        let drawn = ViewRenderer.size(of: Text(line).font(font), fitting: .unspecified).width
        let grid = Double(columns) * cell.width
        // Over a whole line the two must stay within one character of each
        // other. The old measurement was out by a pixel for each character.
        #expect(abs(drawn - grid) < cell.width)
    }

    @Test("A line of any length fits in its cells, so no line ends in an ellipsis")
    func aLineFitsInItsCells() {
        let cell = CellSize(font: font)
        // A `Text` that is wider than its frame cuts itself and ends in
        // "…". The grid gives a run of characters a frame of that many
        // cells, so a cell that is even a fraction of a pixel too narrow
        // eats the end of every line.
        for columns in [1, 2, 14, 40, 80, 200] {
            let line = String(repeating: "M", count: columns)
            #expect(font.width(of: line) <= Double(columns) * cell.width)
        }
        // And a real prompt, which is not one character repeated.
        let prompt = "[root@apus ~]#"
        #expect(font.width(of: prompt) <= Double(prompt.count) * cell.width)
    }

    @Test("The cursor sits at the column that it marks")
    func theCursorSitsOnItsColumn() {
        let cell = CellSize(font: font)
        let screen = Screen(columns: 40, rows: 4)
        screen.write(Array("[root@apus ~]# abc".utf8))
        let frame = Rect(x: 0, y: 0, width: 800, height: 200)
        let list = Grid.displayList(for: screen, cell: cell, in: frame)
        guard case .path(let path, _) = list.last,
              case .move(let x, _) = path.elements.first else {
            Issue.record("expected the cursor path last, got \(String(describing: list.last))")
            return
        }
        // The cursor is after the text, and the text ends where the glyphs do.
        let text = ViewRenderer.size(of: Text("[root@apus ~]# abc").font(font),
                                     fitting: .unspecified).width
        #expect(abs(x - text) < 2 * cell.width)
    }
}
