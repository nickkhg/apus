import Render
import Testing
@testable import Toolkit

// The scroll view: a window onto a taller view, and the wheel that moves it.

@Suite("Scroll")
struct ScrollTests {
    /// Ten rows of 20 points, each one a button.
    final class Log { var tapped: [Int] = [] }

    func rows(_ log: Log) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<10) { index in
                Color.red.frame(height: 20).onTapGesture { log.tapped.append(index) }
            }
        }
    }

    @Test("The content keeps its own height, and the frame shows the top of it")
    func contentKeepsItsHeight() {
        let log = Log()
        let view = ScrollView { rows(log) }.frame(height: 50)
        let pass = ViewRenderer.render(view, in: Rect(x: 0, y: 0, width: 100, height: 50))
        #expect(pass.tapRegions.count == 10)
        #expect(pass.tapRegions[0].frame == Frame(x: 0, y: 0, width: 100, height: 20))
        // A row below the frame is cut away, so it cannot be clicked.
        #expect(pass.tapRegions[3].frame.height == 0)
        #expect(pass.scrollRegions.count == 1)
    }

    @Test("The wheel moves the content, and stops at its end")
    func wheelMovesAndStops() {
        let log = Log()
        let host = ViewHost()
        let view = ScrollView { rows(log) }
        let rect = Rect(x: 0, y: 0, width: 100, height: 50)
        _ = host.displayList(for: view, in: rect)
        host.pointerMoved(to: 10, y: 10)

        #expect(host.pointerScrolled(by: 40))
        _ = host.displayList(for: view, in: rect)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(log.tapped == [2], "40 points down, the third row is at the top")

        // 200 points of rows in 50 points of frame: 150 is the end.
        #expect(host.pointerScrolled(by: 1000))
        _ = host.displayList(for: view, in: rect)
        #expect(!host.pointerScrolled(by: 10), "a view at its end does not use the wheel")
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(log.tapped == [2, 8], "at 150 points down, the ninth row is under the pointer")

        #expect(host.pointerScrolled(by: -1000))
        _ = host.displayList(for: view, in: rect)
        #expect(!host.pointerScrolled(by: -10), "nor does a view at its top")
    }

    @Test("A view that fits does not scroll")
    func fittingViewDoesNotScroll() {
        let host = ViewHost()
        let view = ScrollView { Color.red.frame(height: 20) }
        _ = host.displayList(for: view, in: Rect(x: 0, y: 0, width: 100, height: 50))
        host.pointerMoved(to: 10, y: 10)
        #expect(!host.pointerScrolled(by: 30))
    }

    @Test("The owner can keep the offset, and move the view itself")
    func ownerKeepsTheOffset() {
        final class Box { var offset = 60.0 }
        let box = Box()
        let log = Log()
        let view = ScrollView(offset: Binding(get: { box.offset }, set: { box.offset = $0 })) {
            rows(log)
        }
        let host = ViewHost()
        let rect = Rect(x: 0, y: 0, width: 100, height: 50)
        _ = host.displayList(for: view, in: rect)
        host.pointerMoved(to: 10, y: 1)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(log.tapped == [3])
        host.pointerScrolled(by: 20)
        #expect(box.offset == 80)
    }

    @Test("The wheel goes to the inner view first, and to the outer one at its end")
    func innerViewFirst() {
        final class Box { var outer = 0.0, inner = 0.0 }
        let box = Box()
        let log = Log()
        let view = ScrollView(offset: Binding(get: { box.outer }, set: { box.outer = $0 })) {
            VStack(spacing: 0) {
                ScrollView(offset: Binding(get: { box.inner }, set: { box.inner = $0 })) {
                    rows(log)
                }
                .frame(height: 40)
                Color.blue.frame(height: 100)
            }
        }
        let host = ViewHost()
        let rect = Rect(x: 0, y: 0, width: 100, height: 60)
        _ = host.displayList(for: view, in: rect)
        host.pointerMoved(to: 10, y: 10)
        host.pointerScrolled(by: 100)
        #expect(box.inner == 100 && box.outer == 0)
        _ = host.displayList(for: view, in: rect)
        host.pointerScrolled(by: 100)
        #expect(box.inner == 160 && box.outer == 0)
        _ = host.displayList(for: view, in: rect)
        host.pointerScrolled(by: 30)
        #expect(box.outer == 30)
    }

    @Test("A part that the owner names comes into sight with the least move")
    func revealMovesTheLeast() {
        final class Box { var offset = 0.0 }
        let box = Box()
        let log = Log()
        func view(_ reveal: ClosedRange<Double>?) -> some View {
            ScrollView(offset: Binding(get: { box.offset }, set: { box.offset = $0 }),
                       reveal: reveal) { rows(log) }
        }
        let rect = Rect(x: 0, y: 0, width: 100, height: 50)
        // The fifth row, from 80 to 100: its bottom goes to the bottom.
        _ = ViewRenderer.render(view(80...100), in: rect)
        #expect(box.offset == 50)
        // A row that shows already moves nothing.
        _ = ViewRenderer.render(view(60...80), in: rect)
        #expect(box.offset == 50)
        // A row above: its top goes to the top.
        _ = ViewRenderer.render(view(20...40), in: rect)
        #expect(box.offset == 20)
    }
}
