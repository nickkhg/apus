import Render
@testable import Shell
import Testing
import Toolkit

// The panel is a view, so a test can draw it into a display list and look at
// the items. No screen and no compositor are needed.

private func items(_ state: ShellState, width: Int = 1280) -> DisplayList {
    ViewRenderer.displayList(for: Panel(state: state),
                             in: Rect(x: 0, y: 0, width: width, height: Int(Panel.height)))
}

private func texts(_ list: DisplayList) -> [(Bitmap, Int, Int)] {
    list.compactMap { item in
        if case .bitmap(let bitmap, let x, let y) = item { (bitmap, x, y) } else { nil }
    }
}

@Suite("Panel")
struct PanelTests {
    @Test("The panel fills the bar with its background colour")
    func backgroundFillsTheBar() {
        let list = items(ShellState(clock: "14:05"))
        guard case .fill(let rect, let color) = list.first else {
            Issue.record("the first item is not a fill: \(list.first as Any)")
            return
        }
        #expect(rect == Rect(x: 0, y: 0, width: 1280, height: 28))
        #expect(color == 0x1B1626)
    }

    @Test("The panel shows the name and the time, and nothing else when no window is open")
    func nameAndClock() {
        let list = items(ShellState(clock: "14:05"))
        #expect(texts(list).count == 2)
    }

    @Test("The panel shows the title of the front window")
    func windowTitle() {
        let list = items(ShellState(windowTitles: ["first", "second"], clock: "14:05"))
        #expect(texts(list).count == 3)
    }

    @Test("The name is on the left and the time is on the right")
    func nameLeftClockRight() {
        let width = 1280
        let list = items(ShellState(clock: "14:05"), width: width)
        let drawn = texts(list)
        guard drawn.count == 2 else {
            Issue.record("expected two pieces of text, got \(drawn.count)")
            return
        }
        let (name, clock) = (drawn[0], drawn[1])
        #expect(name.1 == 12, "the name starts after the padding")
        #expect(clock.1 + clock.0.width == width - 12, "the time ends before the padding")
    }

    @Test("The text sits inside the bar")
    func textInsideTheBar() {
        for (bitmap, _, y) in texts(items(ShellState(windowTitles: ["window"], clock: "14:05"))) {
            #expect(y >= 0)
            #expect(y + bitmap.height <= Int(Panel.height))
        }
    }

    @Test("An empty title adds no text")
    func emptyTitle() {
        #expect(texts(items(ShellState(windowTitles: [""], clock: "14:05"))).count == 2)
    }
}
