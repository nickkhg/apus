import Render
import Testing
@testable import Toolkit

// The pointer: hovering, pressing and clicking. ViewHost is what the
// compositor uses, so these tests drive it the same way: draw, move the
// pointer, press the button.

@Suite("Hover")
struct HoverTests {
    @Test("A view that watches the pointer gives its place to the host")
    func hoverRegionHasTheFrame() {
        let view = Color.red.frame(width: 20, height: 10).onHover { _ in }
        let pass = ViewRenderer.render(view, in: Rect(x: 0, y: 0, width: 100, height: 100))
        #expect(pass.hoverRegions.count == 1)
        #expect(pass.hoverRegions[0].frame == Frame(x: 40, y: 45, width: 20, height: 10))
    }

    @Test("The host calls the handler when the pointer enters and leaves")
    func hostReportsEnterAndLeave() {
        final class Log { var events: [Bool] = [] }
        let log = Log()
        let host = ViewHost()
        var updates = 0
        host.needsUpdate = { updates += 1 }
        let view = Color.red.frame(width: 20, height: 10)
            .onHover { log.events.append($0) }

        _ = host.displayList(for: view, in: Rect(x: 0, y: 0, width: 100, height: 100))
        host.pointerMoved(to: 50, y: 50)
        #expect(log.events == [true])
        host.pointerMoved(to: 51, y: 51)
        #expect(log.events == [true], "the pointer stays over the same view")
        host.pointerMoved(to: 5, y: 5)
        #expect(log.events == [true, false])
        // This handler changes no value, so the screen does not change and
        // the host asks for no frame.
        #expect(updates == 0)
    }

    @Test("The pointer that leaves the screen ends the hover")
    func pointerLeavingEndsTheHover() {
        final class Log { var events: [Bool] = [] }
        let log = Log()
        let host = ViewHost()
        let view = Color.red.onHover { log.events.append($0) }
        _ = host.displayList(for: view, in: Rect(x: 0, y: 0, width: 100, height: 100))
        host.pointerMoved(to: 50, y: 50)
        host.pointerLeft()
        #expect(log.events == [true, false])
    }

    @Test("A view keeps its name for the pointer from one frame to the next")
    func hoverIdentityIsStable() {
        let host = ViewHost()
        let view = Color.red.onHover { _ in }
        let rect = Rect(x: 0, y: 0, width: 100, height: 100)
        let first = ViewRenderer.render(view, in: rect, state: ViewState())
        _ = host.displayList(for: view, in: rect)
        let second = ViewRenderer.render(view, in: rect, state: ViewState())
        #expect(first.hoverRegions[0].id == second.hoverRegions[0].id)
    }
}

@Suite("Hover and drawing together")
struct HoverRedrawTests {
    /// A view that remembers the pointer, as a dock icon does.
    private struct Box: View {
        @State var isHovered = false

        var body: some View {
            Color(hex: isHovered ? 0xFFFFFF : 0x000000)
                .frame(width: 20, height: 20)
                .onHover { isHovered = $0 }
        }
    }

    /// The compositor draws at once when something asks for a frame. This
    /// counts the frames, and stops a run that does not end.
    private final class Screen {
        let host = ViewHost()
        var frames = 0

        init() {
            host.needsUpdate = { [unowned self] in draw() }
        }

        func draw() {
            frames += 1
            guard frames < 50 else { return }
            _ = host.displayList(for: Box(), in: Rect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    @Test("A hover handler that asks for a frame does not draw for ever")
    func hoverThatRedrawsEnds() {
        let screen = Screen()
        screen.draw()
        screen.host.pointerMoved(to: 50, y: 50)
        // One frame at the start, and one for the change.
        #expect(screen.frames == 2, "the pointer entering the view drew \(screen.frames) frames")

        screen.host.pointerMoved(to: 5, y: 5)
        #expect(screen.frames == 3, "the pointer leaving the view drew \(screen.frames) frames")

        // The pointer moves inside the view and outside it. Nothing changes,
        // so there is no new frame.
        screen.host.pointerMoved(to: 6, y: 6)
        #expect(screen.frames == 3)
    }
}

@Suite("Clicks")
struct ClickTests {
    private let screen = Rect(x: 0, y: 0, width: 100, height: 100)

    private final class Log {
        var taps = 0
        var presses: [Bool] = []
    }

    /// A 20 x 10 view in the middle of a 100 x 100 screen: 40,45 to 60,55.
    private func host(_ log: Log) -> ViewHost {
        let host = ViewHost()
        let view = Color.red.frame(width: 20, height: 10)
            .onPress { log.presses.append($0) }
            .onTapGesture { log.taps += 1 }
        _ = host.displayList(for: view, in: screen)
        return host
    }

    @Test("A press and a release over the view is a click")
    func pressAndReleaseIsAClick() {
        let log = Log()
        let host = host(log)
        host.pointerMoved(to: 50, y: 50)
        host.pointerButton(pressed: true)
        #expect(log.presses == [true])
        #expect(log.taps == 0, "the click comes when the button goes up")
        host.pointerButton(pressed: false)
        #expect(log.presses == [true, false])
        #expect(log.taps == 1)
    }

    @Test("A release outside the view is no click")
    func releaseOutsideIsNoClick() {
        let log = Log()
        let host = host(log)
        host.pointerMoved(to: 50, y: 50)
        host.pointerButton(pressed: true)
        host.pointerMoved(to: 5, y: 5)
        host.pointerButton(pressed: false)
        #expect(log.taps == 0)
        // The view stops looking pressed when the pointer leaves it.
        #expect(log.presses == [true, false])
    }

    @Test("The view looks pressed again when the pointer comes back")
    func pressedAgainWhenThePointerReturns() {
        let log = Log()
        let host = host(log)
        host.pointerMoved(to: 50, y: 50)
        host.pointerButton(pressed: true)
        host.pointerMoved(to: 5, y: 5)
        host.pointerMoved(to: 50, y: 50)
        #expect(log.presses == [true, false, true])
        host.pointerButton(pressed: false)
        #expect(log.taps == 1)
    }

    @Test("A press with the pointer on nothing does nothing")
    func pressOnNothing() {
        let log = Log()
        let host = host(log)
        host.pointerMoved(to: 5, y: 5)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(log.presses.isEmpty)
        #expect(log.taps == 0)
    }

    @Test("The view in front gets the click")
    func frontViewGetsTheClick() {
        final class Counter { var back = 0; var front = 0 }
        let counter = Counter()
        let host = ViewHost()
        let view = ZStack {
            Color.red.frame(width: 60, height: 60).onTapGesture { counter.back += 1 }
            Color.blue.frame(width: 20, height: 20).onTapGesture { counter.front += 1 }
        }
        _ = host.displayList(for: view, in: screen)
        host.pointerMoved(to: 50, y: 50)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect((counter.front, counter.back) == (1, 0))
    }

    @Test("A button calls its action, and it asks for one frame for each change")
    func buttonCallsItsAction() {
        final class Counter { var clicks = 0; var frames = 0 }
        let counter = Counter()
        let host = ViewHost()
        host.needsUpdate = { counter.frames += 1 }
        func draw() {
            _ = host.displayList(for: Button("Close") { counter.clicks += 1 }, in: screen)
        }
        host.needsUpdate = { counter.frames += 1; draw() }
        draw()

        // The button is in the middle of the screen.
        host.pointerMoved(to: 50, y: 50)
        #expect(counter.frames == 1, "the pointer over the button changes how it looks")
        host.pointerButton(pressed: true)
        #expect(counter.frames == 2, "the button looks pressed")
        host.pointerButton(pressed: false)
        #expect(counter.clicks == 1)
        #expect(counter.frames == 3)
    }
}
