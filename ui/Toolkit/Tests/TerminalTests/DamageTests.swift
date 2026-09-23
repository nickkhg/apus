import Render
@testable import Terminal
import Testing
import Toolkit

// The terminal keeps its buffer between frames and tells the compositor
// what changed. A key that a person types changes one line of the grid, so
// that line is all that the frame draws and all that the compositor copies.

private let cell = CellSize(font: .monospaced(size: 14))
private let frame = Rect(x: 0, y: 0, width: 400, height: 200)

@Suite("What a frame of the terminal changes")
struct TerminalDamageTests {
    @Test("A character that is typed damages its line and not the grid")
    func oneCharacter() {
        let screen = Screen(columns: 40, rows: 10)
        screen.write(Array("$ ls\r\nfiles\r\n$ ".utf8))
        let tracker = DamageTracker()
        _ = tracker.damage(for: Grid.displayList(for: screen, cell: cell, in: frame), screen: frame)
        screen.write(Array("e".utf8))
        let region = tracker.damage(for: Grid.displayList(for: screen, cell: cell, in: frame),
                                    screen: frame)
        guard let bounds = region.bounds else {
            Issue.record("nothing changed")
            return
        }
        // The line of the prompt, with the cursor that moved along it.
        #expect(bounds.y >= Int(2 * cell.height) - 2)
        #expect(bounds.height <= Int(cell.height) + 4)
        #expect(region.area < frame.width * frame.height / 10)
    }
}
