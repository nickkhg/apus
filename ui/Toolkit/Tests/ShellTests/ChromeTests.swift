import Render
@testable import Shell
import Testing
import Toolkit

// What the shell keeps of a cell, and what it draws there: the bar over a
// window, and the card in a cell that a window cannot use.

@Suite("What the shell keeps of a cell")
struct WindowChromeTests {
    @Test("A large cell gives its top to the head")
    func aLargeCellHasAHead() {
        let cell = Rect(x: 72, y: 8, width: 1200, height: 784)
        let content = WindowChrome.content(of: cell, sizeClass: .large)
        #expect(content == Rect(x: 80, y: 40, width: 1184, height: 744))
    }

    @Test("A tile keeps nothing, because the app draws all of it")
    func aTileHasNoHead() {
        let cell = Rect(x: 1016, y: 8, width: 256, height: 256)
        #expect(WindowChrome.content(of: cell, sizeClass: .widget) == cell)
    }

    @Test("A cell too small for a head gives no negative size")
    func aTinyCellIsSafe() {
        let content = WindowChrome.content(of: Rect(x: 0, y: 0, width: 4, height: 4),
                                           sizeClass: .large)
        #expect(content.width == 0)
        #expect(content.height == 0)
    }

    @Test("The window keeps the class that its cell had")
    func theClassComesFromTheCell() {
        // A cell of 936 x 784 is large, and the window inside it is too.
        let cell = Rect(x: 72, y: 8, width: 936, height: 784)
        let content = WindowChrome.content(of: cell, sizeClass: .large)
        #expect(SizeClass.of(Proposal(width: Double(content.width),
                                      height: Double(content.height))) == .large)
    }
}

@Suite("The head of a window")
struct WindowHeadTests {
    private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

    private func head(focus: Bool = true, title: String = "~/apus — bash") -> WindowHead {
        WindowHead(id: "w1", appName: "Terminal", mark: Color(hex: 0x3BB273),
                   title: title, sizeClass: .large, hasFocus: focus,
                   cell: Rect(x: 72, y: 8, width: 936, height: 784))
    }

    private func list(_ head: WindowHead) -> DisplayList {
        ViewRenderer.displayList(for: WindowHeadView(head: head),
                                 in: Rect(x: 0, y: 0, width: head.cell.width,
                                          height: Int(Metrics.headHeight)))
    }

    @Test("The window with the keyboard has a line in the accent colour")
    func theFocusedWindowHasALine() {
        func hasAccent(_ list: DisplayList) -> Bool {
            list.contains { item in
                if case .fill(_, let color) = item { color == Palette.accent.premultiplied }
                else { false }
            }
        }
        #expect(hasAccent(list(head(focus: true))))
        #expect(!hasAccent(list(head(focus: false))))
    }

    @Test("The head names the app and the window")
    func theHeadNamesThings() {
        let texts = list(head()).filter { if case .bitmap = $0 { true } else { false } }
        // The app, the title, the class, and the two controls.
        #expect(texts.count >= 3)
    }

    @Test("A window with no title draws one text less")
    func anEmptyTitleAddsNothing() {
        func texts(_ head: WindowHead) -> Int {
            list(head).count { if case .bitmap = $0 { true } else { false } }
        }
        #expect(texts(head(title: "")) < texts(head(title: "a title")))
    }

    @Test("The close control asks the compositor to close that window")
    func theCloseControlWorks() {
        final class Log: @unchecked Sendable { var closed: [String] = [] }
        let log = Log()
        let actions = ShellActions(closeWindow: { log.closed.append($0) })
        let host = ViewHost()
        let card = head()
        let view = { WindowHeadView(head: card, actions: actions) }
        let box = Rect(x: 0, y: 0, width: card.cell.width, height: Int(Metrics.headHeight))
        // The last control of the head is the one that closes it.
        let pass = ViewRenderer.render(view(), in: box)
        guard let region = pass.tapRegions.last else {
            Issue.record("expected a control")
            return
        }
        _ = host.displayList(for: view(), in: box)
        host.pointerMoved(to: region.frame.x + 1, y: region.frame.y + 1)
        _ = host.displayList(for: view(), in: box)
        host.pointerButton(pressed: true)
        _ = host.displayList(for: view(), in: box)
        host.pointerButton(pressed: false)
        #expect(log.closed == ["w1"])
    }
}

@Suite("A cross and a collapse")
struct HeadGlyphTests {
    private func drawn(_ shape: some Shape, size: Int = 20) -> Int {
        let list = ViewRenderer.displayList(for: shape.fill(Color.white),
                                            in: Rect(x: 0, y: 0, width: size, height: size))
        var buffer = [UInt32](repeating: 0xFF000000, count: size * size)
        buffer.withUnsafeMutableBufferPointer { memory in
            SoftwareRenderer.render(list, into: Canvas(pixels: memory.baseAddress!,
                                                       width: size, height: size, stride: size))
        }
        return buffer.count { $0 != 0xFF000000 }
    }

    @Test("A cross draws both of its arms")
    func theCrossHasTwoArms() {
        #expect(drawn(Cross()) > 40)
    }

    @Test("A collapse draws a ring with a square in it")
    func theCollapseIsHollow() {
        // A ring plus a small square covers less than the whole space.
        let size = 20
        #expect(drawn(Collapse(), size: size) < size * size)
        #expect(drawn(Collapse(), size: size) > 20)
    }
}
