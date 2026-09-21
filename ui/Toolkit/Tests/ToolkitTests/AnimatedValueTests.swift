import Render
import Testing
@testable import Toolkit

// The move is in the view, not in the value.
//
// A value goes to its new value at once, as it does in SwiftUI. The view
// that draws it is the thing that is part of the way there, and the toolkit
// keeps that move for the place of the view in the tree.

private let box = Rect(x: 0, y: 0, width: 200, height: 40)

private func width(_ list: DisplayList) -> Int? {
    for item in list {
        if case .fill(let rect, _) = item { return rect.width }
    }
    return nil
}

private func colour(_ list: DisplayList) -> UInt32? {
    for item in list {
        if case .path(_, let color) = item { return color }
    }
    return nil
}

@Suite("A view that moves when a value changes")
struct AnimationValueTests {
    /// The width of this row moves when `wide` changes.
    private struct Row: View {
        let wide: Bool

        var body: some View {
            Color.white.frame(width: wide ? 100 : 10, height: 4)
                .animation(.linear(duration: 1), value: wide)
        }
    }

    @Test("The view arrives as it is: the first value is not a change")
    func theFirstValueIsNotAMove() {
        let host = ViewHost()
        host.needsUpdate = {}
        host.now = 0
        #expect(width(host.displayList(for: Row(wide: true), in: box)) == 100)
    }

    @Test("A change of the value moves the views inside")
    func aChangeMoves() {
        let host = ViewHost()
        host.needsUpdate = {}
        host.now = 0
        #expect(width(host.displayList(for: Row(wide: false), in: box)) == 10)

        // The move starts on the frame that the value changed.
        host.now = 0
        #expect(width(host.displayList(for: Row(wide: true), in: box)) == 10)
        host.now = 0.5
        let middle = width(host.displayList(for: Row(wide: true), in: box))
        #expect(middle != nil && middle! > 10 && middle! < 100, "got \(middle ?? -1)")
        host.now = 1
        #expect(width(host.displayList(for: Row(wide: true), in: box)) == 100)
    }

    @Test("A change that the view does not watch moves nothing")
    func anotherChangeDoesNotMove() {
        /// The width changes, and the modifier watches the label.
        struct Watching: View {
            let wide: Bool
            let label: String

            var body: some View {
                Color.white.frame(width: wide ? 100 : 10, height: 4)
                    .animation(.linear(duration: 1), value: label)
            }
        }
        let host = ViewHost()
        host.needsUpdate = {}
        host.now = 0
        _ = host.displayList(for: Watching(wide: false, label: "a"), in: box)
        host.now = 0
        // Nothing that the modifier watches changed, so the width is there
        // at once.
        #expect(width(host.displayList(for: Watching(wide: true, label: "a"), in: box)) == 100)
    }

    @Test("A colour moves as a number does")
    func aColourMoves() {
        struct Glow: View {
            let on: Bool

            var body: some View {
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? Color(white: 1) : Color(white: 0))
                    .frame(width: 10, height: 10)
                    .animation(.linear(duration: 1), value: on)
            }
        }
        let host = ViewHost()
        host.needsUpdate = {}
        host.now = 0
        _ = host.displayList(for: Glow(on: false), in: box)
        host.now = 0
        _ = host.displayList(for: Glow(on: true), in: box)
        host.now = 0.5
        let middle = colour(host.displayList(for: Glow(on: true), in: box))
        guard let middle else {
            Issue.record("the shape drew nothing")
            return
        }
        let red = (middle >> 16) & 0xFF
        #expect(red > 100 && red < 160, "the colour is not half way: \(red)")
        host.now = 1
        #expect(colour(host.displayList(for: Glow(on: true), in: box)) == 0xFFFF_FFFF)
    }

    @Test("A move asks for the frames that it needs, and then stops")
    func itAsksForFrames() {
        final class Count: @unchecked Sendable { var frames = 0 }
        let asked = Count()
        let host = ViewHost()
        host.needsUpdate = { asked.frames += 1 }
        host.now = 0
        _ = host.displayList(for: Row(wide: false), in: box)
        asked.frames = 0

        host.now = 0
        _ = host.displayList(for: Row(wide: true), in: box)
        #expect(asked.frames > 0, "a view on its way asked for no frame")

        host.now = 2
        _ = host.displayList(for: Row(wide: true), in: box)
        asked.frames = 0
        host.now = 3
        _ = host.displayList(for: Row(wide: true), in: box)
        #expect(asked.frames == 0, "a view that arrived asked for a frame")
    }

    @Test("A move of nothing puts the view there at once")
    func nilAnimationJumps() {
        struct Plain: View {
            let wide: Bool

            var body: some View {
                Color.white.frame(width: wide ? 100 : 10, height: 4)
                    .animation(nil, value: wide)
            }
        }
        let host = ViewHost()
        host.needsUpdate = {}
        host.now = 0
        _ = host.displayList(for: Plain(wide: false), in: box)
        host.now = 0
        #expect(width(host.displayList(for: Plain(wide: true), in: box)) == 100)
    }
}
