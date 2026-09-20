import Render
import Testing
@testable import Toolkit

// Motion is the one part of the design that a screen can do without: every
// picture must be right with every move finished. So these tests check both
// that a value moves, and that it arrives.
//
// The API is SwiftUI's: `withAnimation` names the move, and the `@State`
// that changes inside it moves to its new value.

@Suite("How a value moves")
struct AnimationTests {
    @Test("A move starts at the start and ends at the end")
    func aMoveGoesFromEndToEnd() {
        let animation = Animation.linear(duration: 1)
        #expect(animation.amount(after: 0) == 0)
        #expect(animation.amount(after: 1) == 1)
        #expect(animation.amount(after: 0.5) == 0.5)
    }

    @Test("A move never goes past its ends")
    func aMoveIsClamped() {
        let animation = Animation.easeOut(duration: 1)
        #expect(animation.amount(after: -5) == 0)
        #expect(animation.amount(after: 99) == 1)
    }

    @Test("Ease out is fast at the start, ease in is slow at it")
    func theEasesGoTheirOwnWay() {
        #expect(Animation.easeOut(duration: 1).amount(after: 0.25) > 0.25)
        #expect(Animation.easeIn(duration: 1).amount(after: 0.25) < 0.25)
    }

    @Test("Ease in and out is slow at both ends")
    func easeInOutIsSlowAtTheEnds() {
        let both = Animation.easeInOut(duration: 1)
        #expect(both.amount(after: 0.1) < 0.1)
        #expect(both.amount(after: 0.9) > 0.9)
        #expect(abs(both.amount(after: 0.5) - 0.5) < 0.001)
    }

    @Test("A move of no time arrives at once")
    func noTimeArrivesAtOnce() {
        #expect(Animation.instant.amount(after: 0) == 1)
    }

    @Test("A wait holds the move at its start, and it still arrives")
    func aDelayWaits() {
        let animation = Animation.linear(duration: 1).delay(0.5)
        #expect(animation.amount(after: 0.25) == 0)
        #expect(abs(animation.amount(after: 1) - 0.5) < 0.001)
        #expect(animation.amount(after: 1.5) == 1)
        #expect(animation.length == 1.5)
    }

    @Test("Twice the speed is half the time")
    func speedShortensTheMove() {
        let animation = Animation.linear(duration: 1).speed(2)
        #expect(animation.amount(after: 0.5) == 1)
        #expect(animation.length == 0.5)
    }
}

@Suite("A move with some weight")
struct SpringTests {
    private let spring = Animation.spring(duration: 1, bounce: 0.3)

    @Test("It goes past its target and comes back to it")
    func itOvershoots() {
        var most = 0.0
        for step in 0...100 { most = max(most, spring.amount(after: Double(step) / 100)) }
        #expect(most > 1, "a spring must go past its target, the most was \(most)")
    }

    @Test("It ends exactly at its target")
    func itArrives() {
        #expect(abs(spring.amount(after: 1) - 1) < 0.000_001)
        #expect(spring.amount(after: 5) == 1)
    }

    @Test("No bounce is an arrival with no overshoot")
    func noBounce() {
        let plain = Animation.spring(duration: 1, bounce: 0)
        for step in 0...100 {
            #expect(plain.amount(after: Double(step) / 100) <= 1.000_001)
        }
    }
}

@Suite("The things that can move")
struct AnimatableTests {
    @Test("A number moves as itself")
    func aNumberMoves() {
        #expect(0.0.moved(to: 10, amount: 0.25) == 2.5)
        #expect(4.0.arrived(at: 4))
    }

    @Test("A colour moves part by part")
    func aColourMoves() {
        let middle = Color.black.moved(to: .white, amount: 0.5)
        #expect(abs(middle.red - 0.5) < 0.001)
        #expect(abs(middle.alpha - 1) < 0.001)
    }

    @Test("A frame moves, so a cell can go to another place")
    func aFrameMoves() {
        let start = Frame(x: 0, y: 0, width: 10, height: 10)
        let end = Frame(x: 100, y: 50, width: 20, height: 20)
        let middle = start.moved(to: end, amount: 0.5)
        #expect(middle.x == 50 && middle.y == 25)
        #expect(middle.width == 15 && middle.height == 15)
    }

    @Test("A pair holds two values that move together")
    func aPairMoves() {
        var pair = AnimatablePair(4.0, 8.0) - AnimatablePair(1.0, 2.0)
        pair.scale(by: 0.5)
        #expect(pair.first == 1.5 && pair.second == 3)
        #expect(AnimatablePair(3.0, 4.0).magnitudeSquared == 25)
    }
}

@Suite("A value on its way")
struct MotionTests {
    @Test("It arrives at its target")
    func itArrives() {
        let motion = Motion(0.0)
        motion.move(to: 1, with: .linear(duration: 1), now: 0)
        #expect(motion.value(now: 0) == 0)
        #expect(abs(motion.value(now: 0.5) - 0.5) < 0.001)
        #expect(motion.value(now: 1) == 1)
        #expect(motion.value(now: 5) == 1)
    }

    @Test("It says while it is moving, and stops saying it")
    func itKnowsWhenItMoves() {
        let motion = Motion(0.0)
        motion.move(to: 1, with: .linear(duration: 1), now: 0)
        #expect(motion.isMoving(now: 0.5))
        #expect(!motion.isMoving(now: 1))
    }

    @Test("A move that turns around does not jump")
    func aTurnDoesNotJump() {
        let motion = Motion(0.0)
        motion.move(to: 1, with: .linear(duration: 1), now: 0)
        let half = motion.value(now: 0.5)
        motion.move(to: 0, with: .linear(duration: 1), now: 0.5)
        #expect(abs(motion.value(now: 0.5) - half) < 0.001)
        #expect(motion.value(now: 1.5) == 0)
    }

    @Test("The same target again does not start the move over")
    func theSameTargetChangesNothing() {
        let motion = Motion(0.0)
        motion.move(to: 1, with: .linear(duration: 1), now: 0)
        motion.move(to: 1, with: .linear(duration: 1), now: 0.5)
        // The move still ends one second after it started, not 1.5.
        #expect(motion.value(now: 1) == 1)
    }

    @Test("A colour arrives at the colour it was given")
    func aColourArrives() {
        let motion = Motion(Color.black)
        motion.move(to: .white, with: .linear(duration: 1), now: 0)
        #expect(motion.value(now: 2) == Color.white)
    }
}

@Suite("A view that moves")
struct AnimatedViewTests {
    /// A box whose width follows a value that the test sets.
    private struct Box: View {
        @State private var width = 10.0
        let target: Double
        /// Nil sets the value with no move at all.
        let animation: Animation?

        var body: some View {
            // Setting it in the body is what a handler would do.
            if width != target {
                withAnimation(animation) { width = target }
            }
            return Color.white.frame(width: width, height: 4)
        }
    }

    private func width(_ list: DisplayList) -> Int? {
        for item in list {
            if case .fill(let rect, _) = item { return rect.width }
        }
        return nil
    }

    private let box = Rect(x: 0, y: 0, width: 200, height: 20)

    @Test("A value moves over the frames, and the host asks for them")
    func theValueMovesOverFrames() {
        final class Count: @unchecked Sendable { var frames = 0 }
        let asked = Count()
        let host = ViewHost()
        host.needsUpdate = { asked.frames += 1 }
        let view = Box(target: 100, animation: .linear(duration: 1))

        host.now = 0
        _ = host.displayList(for: view, in: box)
        // The value has not moved yet, and the host was asked for a frame.
        #expect(asked.frames > 0)

        host.now = 0.5
        let middle = width(host.displayList(for: view, in: box))
        #expect(middle != nil && middle! > 10 && middle! < 100)

        host.now = 1
        #expect(width(host.displayList(for: view, in: box)) == 100)
    }

    @Test("A value that has arrived asks for no more frames")
    func anArrivedValueRests() {
        final class Count: @unchecked Sendable { var frames = 0 }
        let asked = Count()
        let host = ViewHost()
        host.needsUpdate = { asked.frames += 1 }
        let view = Box(target: 100, animation: .linear(duration: 1))

        host.now = 0
        _ = host.displayList(for: view, in: box)
        host.now = 2
        _ = host.displayList(for: view, in: box)
        asked.frames = 0
        host.now = 3
        _ = host.displayList(for: view, in: box)
        #expect(asked.frames == 0)
    }

    @Test("A change outside a move takes effect at once")
    func noAnimationJumps() {
        let host = ViewHost()
        host.needsUpdate = {}
        host.now = 0
        let view = Box(target: 100, animation: nil)
        #expect(width(host.displayList(for: view, in: box)) == 100)
    }

    @Test("A move inside another move takes the inner one")
    func theInnerMoveWins() {
        // withAnimation(nil) inside a move is how a change says that it
        // must not move.
        var inside: Animation?
        withAnimation(.linear(duration: 1)) {
            withAnimation(nil) { inside = Transaction.animation }
        }
        #expect(inside == nil)
        #expect(Transaction.animation == nil, "the move must not outlast its closure")
    }
}

@Suite("A value that changes while the tree is laid out")
struct LayoutTimeChangeTests {
    /// A view that gives a value a target in its body, which is what an
    /// animation that starts on its own does.
    private struct Arriving: View {
        @State private var amount = 0.0

        var body: some View {
            if amount == 0 {
                withAnimation(.linear(duration: 1)) { amount = 1 }
            }
            return Color.white.frame(width: 10 + amount * 10, height: 4)
        }
    }

    private func width(_ list: DisplayList) -> Int? {
        for item in list {
            if case .fill(let rect, _) = item { return rect.width }
        }
        return nil
    }

    @Test("The tree survives a value that changes while it is laid out")
    func theTreeSurvives() {
        // Setting a value during layout asks for a frame. The renderer must
        // finish its pass first: it keeps the path to the view it is in, and
        // starting again in the middle of that loses the place.
        let host = ViewHost()
        let box = Rect(x: 0, y: 0, width: 100, height: 20)
        host.needsUpdate = {}
        host.now = 0
        _ = host.displayList(for: Arriving(), in: box)
        host.now = 0.5
        let middle = host.displayList(for: Arriving(), in: box)
        host.now = 1
        let end = host.displayList(for: Arriving(), in: box)
        // The value went from 10 to 20 over the second, and the state of the
        // view carried it across the frames.
        #expect(width(middle) == 15)
        #expect(width(end) == 20)
    }

    @Test("A value that changed during layout still gets its frame")
    func theFrameStillComes() {
        final class Count: @unchecked Sendable { var frames = 0 }
        let asked = Count()
        let host = ViewHost()
        host.needsUpdate = { asked.frames += 1 }
        host.now = 0
        _ = host.displayList(for: Arriving(), in: Rect(x: 0, y: 0, width: 100, height: 20))
        #expect(asked.frames == 1)
    }
}
