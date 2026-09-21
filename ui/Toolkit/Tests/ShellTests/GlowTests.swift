import Render
@testable import Shell
import Testing
import Toolkit

// The shell asks for a move in a handler: the pointer arrives over a
// control, and the control lights up over the frames after that.
//
// This is the whole chain in one test: a handler names a move, the value
// goes to its new value at once, the graph carries the move to the view
// that draws the control, and the view is part of the way there until it
// arrives.

private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

private func state() -> ShellState {
    ShellState(apps: [AppEntry(id: "org.apus.terminal", name: "Terminal",
                               color: Color(hex: 0x3BB273))],
               canvas: RootView.windowArea(screen: screen))
}

/// The colours of every outline that the shell drew.
private func colours(_ list: DisplayList) -> [UInt32] {
    list.compactMap { if case .path(_, let color) = $0 { color } else { nil } }
}

@Suite("A control that lights up")
struct GlowTests {
    @Test("The colour of a control moves over the frames, and arrives")
    func theGlowMoves() {
        let host = ViewHost()
        host.needsUpdate = {}
        let shell = state()
        host.now = 0
        _ = host.displayList(for: RootView(state: shell), in: screen)

        // The pointer arrives over the Summon control, which is the first
        // control in the rail: 40 by 40, 16 points down from the top.
        host.pointerMoved(to: 36, y: 44)
        host.now = 0
        let starting = colours(host.displayList(for: RootView(state: shell), in: screen))
        host.now = 0.06
        let middle = colours(host.displayList(for: RootView(state: shell), in: screen))
        host.now = 1
        let arrived = colours(host.displayList(for: RootView(state: shell), in: screen))

        #expect(middle != starting, "the control did not move")
        #expect(arrived != middle, "the control stopped before it arrived")
        // The control ends at the colour that the view names for a pointer
        // that is over it.
        let lit = Palette.accentSurface.lightened(by: 0.4).premultiplied
        #expect(arrived.contains(lit), "the control did not arrive at its colour")
        #expect(!starting.contains(lit), "the control was there at once")
    }

    @Test("A screen that nothing touches asks for no frames")
    func aStillScreenRests() {
        final class Count: @unchecked Sendable { var frames = 0 }
        let asked = Count()
        let host = ViewHost()
        host.needsUpdate = { asked.frames += 1 }
        let shell = state()
        host.now = 0
        _ = host.displayList(for: RootView(state: shell), in: screen)
        host.now = 1
        _ = host.displayList(for: RootView(state: shell), in: screen)
        asked.frames = 0
        host.now = 2
        _ = host.displayList(for: RootView(state: shell), in: screen)
        #expect(asked.frames == 0)
    }
}
