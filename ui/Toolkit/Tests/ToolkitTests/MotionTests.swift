import Render
import Testing
@testable import Toolkit

// Motion is the one part of the design that a screen can do without: every
// picture must be right with every move finished. So these tests check both
// that a value moves, and that it arrives.

@Suite("How a value moves")
struct AnimationTests {
    @Test("A move starts at the start and ends at the end")
    func aMoveGoesFromEndToEnd() {
        let animation = Animation(duration: 1, curve: .linear)
        #expect(animation.amount(after: 0) == 0)
        #expect(animation.amount(after: 1) == 1)
        #expect(animation.amount(after: 0.5) == 0.5)
    }

    @Test("A move never goes past its ends")
    func aMoveIsClamped() {
        let animation = Animation(duration: 1, curve: .easeOut)
        #expect(animation.amount(after: -5) == 0)
        #expect(animation.amount(after: 99) == 1)
    }

    @Test("Ease out is fast at the start")
    func easeOutStartsFast() {
        let out = Animation(duration: 1, curve: .easeOut)
        #expect(out.amount(after: 0.25) > 0.25)
    }

    @Test("Ease in and out is slow at both ends")
    func easeInOutIsSlowAtTheEnds() {
        let both = Animation(duration: 1, curve: .easeInOut)
        #expect(both.amount(after: 0.1) < 0.1)
        #expect(both.amount(after: 0.9) > 0.9)
        #expect(abs(both.amount(after: 0.5) - 0.5) < 0.001)
    }

    @Test("A move of no time arrives at once")
    func noTimeArrivesAtOnce() {
        #expect(Animation.none.amount(after: 0) == 1)
    }
}

@Suite("A value on its way")
struct MotionTests {
    @Test("It arrives at its target")
    func itArrives() {
        let motion = Motion(0)
        motion.move(to: 1, with: Animation(duration: 1, curve: .linear), now: 0)
        #expect(motion.value(now: 0) == 0)
        #expect(abs(motion.value(now: 0.5) - 0.5) < 0.001)
        #expect(motion.value(now: 1) == 1)
        #expect(motion.value(now: 5) == 1)
    }

    @Test("It says while it is moving, and stops saying it")
    func itKnowsWhenItMoves() {
        let motion = Motion(0)
        motion.move(to: 1, with: Animation(duration: 1, curve: .linear), now: 0)
        #expect(motion.isMoving(now: 0.5))
        #expect(!motion.isMoving(now: 1))
    }

    @Test("A move that turns around does not jump")
    func aTurnDoesNotJump() {
        let motion = Motion(0)
        let animation = Animation(duration: 1, curve: .linear)
        motion.move(to: 1, with: animation, now: 0)
        let half = motion.value(now: 0.5)
        // It turns back at the half way point, so it starts from there.
        motion.move(to: 0, with: animation, now: 0.5)
        #expect(abs(motion.value(now: 0.5) - half) < 0.001)
        #expect(motion.value(now: 1.5) == 0)
    }

    @Test("The same target again does not start the move over")
    func theSameTargetChangesNothing() {
        let motion = Motion(0)
        let animation = Animation(duration: 1, curve: .linear)
        motion.move(to: 1, with: animation, now: 0)
        motion.move(to: 1, with: animation, now: 0.5)
        // The move still ends one second after it started, not 1.5.
        #expect(motion.value(now: 1) == 1)
    }
}

@Suite("A view that moves")
struct AnimatedViewTests {
    /// A box whose width follows a value that the test sets.
    private struct Box: View {
        @Animated(Animation(duration: 1, curve: .linear)) var width = 10.0
        let target: Double

        var body: some View {
            // Setting it in the body is what a handler would do.
            width = target
            return Color.white.frame(width: width, height: 4)
        }
    }

    private func width(_ list: DisplayList) -> Int? {
        for item in list {
            if case .fill(let rect, _) = item { return rect.width }
        }
        return nil
    }

    @Test("A value moves over the frames, and the host asks for them")
    func theValueMovesOverFrames() {
        final class Count: @unchecked Sendable { var frames = 0 }
        let asked = Count()
        let host = ViewHost()
        host.needsUpdate = { asked.frames += 1 }
        let box = Rect(x: 0, y: 0, width: 100, height: 20)

        host.now = 0
        _ = host.displayList(for: Box(target: 100), in: box)
        // The value has not moved yet, and the host was asked for a frame.
        #expect(asked.frames > 0)

        host.now = 0.5
        let middle = width(host.displayList(for: Box(target: 100), in: box))
        #expect(middle != nil && middle! > 10 && middle! < 100)

        host.now = 1
        #expect(width(host.displayList(for: Box(target: 100), in: box)) == 100)
    }

    @Test("A value that has arrived asks for no more frames")
    func anArrivedValueRests() {
        final class Count: @unchecked Sendable { var frames = 0 }
        let asked = Count()
        let host = ViewHost()
        host.needsUpdate = { asked.frames += 1 }
        let box = Rect(x: 0, y: 0, width: 100, height: 20)

        host.now = 0
        _ = host.displayList(for: Box(target: 100), in: box)
        host.now = 2
        _ = host.displayList(for: Box(target: 100), in: box)
        asked.frames = 0
        host.now = 3
        _ = host.displayList(for: Box(target: 100), in: box)
        #expect(asked.frames == 0)
    }
}
