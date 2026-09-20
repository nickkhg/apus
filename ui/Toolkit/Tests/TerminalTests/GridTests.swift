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
        #expect(cell.width >= narrow.width)
    }

    @Test("The first item fills the window with the background colour")
    func backgroundFirst() {
        let screen = Screen(columns: 20, rows: 5)
        guard case .fill(let rect, let color) = items(screen).first else {
            Issue.record("the first item is not a fill")
            return
        }
        #expect(rect == frame)
        #expect(color == Palette.background)
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
        #expect(color == Palette.color(4))
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
