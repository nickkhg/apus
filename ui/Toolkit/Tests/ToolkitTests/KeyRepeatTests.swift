import Testing
import Toolkit

// A held key waits for the delay, then goes at the rate, until it goes up,
// another key goes down, or the window loses the keys.

@Suite("Key repeat")
struct KeyRepeatTests {
    /// 25 a second after 600 ms: what the compositor of Apus sends. The
    /// tests look a millisecond either side of a time, because 0.04 of a
    /// second is not a number that a Double holds exactly.
    private func apus() -> KeyRepeat { KeyRepeat(rate: 25, delay: 600) }

    private let a: UInt32 = 30
    private let b: UInt32 = 48

    @Test("A key waits for the delay before it repeats")
    func theDelay() {
        var keys = apus()
        keys.pressed(a, repeats: true, at: 10)
        #expect((600...601).contains(keys.wait(at: 10) ?? 0))
        #expect(keys.due(at: 10.599) == nil)
        #expect(keys.due(at: 10.601) == a)
    }

    @Test("After the delay the key goes at the rate")
    func theRate() {
        var keys = apus()
        keys.pressed(a, repeats: true, at: 0)
        #expect(keys.due(at: 0.6) == a)
        #expect((40...41).contains(keys.wait(at: 0.6) ?? 0))
        #expect(keys.due(at: 0.639) == nil)
        #expect(keys.due(at: 0.641) == a)
        #expect(keys.due(at: 0.679) == nil)
        #expect(keys.due(at: 0.681) == a)
    }

    @Test("A late loop gets one repeat, not the ones it missed")
    func noBurst() {
        var keys = apus()
        keys.pressed(a, repeats: true, at: 0)
        #expect(keys.due(at: 2) == a)
        #expect(keys.due(at: 2) == nil)
        #expect((40...41).contains(keys.wait(at: 2) ?? 0))
    }

    @Test("The release of the key stops it, and of another key does not")
    func release() {
        var keys = apus()
        keys.pressed(a, repeats: true, at: 0)
        keys.released(b)
        #expect(keys.key == a)
        keys.released(a)
        #expect(keys.key == nil)
        #expect(keys.wait(at: 1) == nil)
        #expect(keys.due(at: 1) == nil)
    }

    @Test("Another key takes over, and one that does not repeat stops it")
    func anotherKey() {
        var keys = apus()
        keys.pressed(a, repeats: true, at: 0)
        keys.pressed(b, repeats: true, at: 1)
        #expect(keys.key == b)
        #expect(keys.due(at: 1.599) == nil)
        #expect(keys.due(at: 1.601) == b)
        // A modifier: the keymap says it does not repeat.
        keys.pressed(42, repeats: false, at: 2)
        #expect(keys.key == nil)
        #expect(keys.due(at: 5) == nil)
    }

    @Test("A key that the keymap says does not repeat never does")
    func aModifier() {
        var keys = apus()
        keys.pressed(42, repeats: false, at: 0)
        #expect(keys.key == nil)
        #expect(keys.wait(at: 0) == nil)
    }

    @Test("A rate of zero is no repeat")
    func rateZero() {
        var keys = KeyRepeat(rate: 0, delay: 600)
        keys.pressed(a, repeats: true, at: 0)
        #expect(keys.key == nil)
        #expect(keys.due(at: 5) == nil)

        // A repeat that is going stops when the rate becomes zero.
        keys = apus()
        keys.pressed(a, repeats: true, at: 0)
        keys.set(rate: 0, delay: 600)
        #expect(keys.key == nil)
    }

    @Test("Nothing repeats until the compositor says how")
    func noInfoYet() {
        var keys = KeyRepeat()
        keys.pressed(a, repeats: true, at: 0)
        #expect(keys.key == nil)
    }

    @Test("Losing the keys stops the repeat")
    func leave() {
        var keys = apus()
        keys.pressed(a, repeats: true, at: 0)
        keys.stop()
        #expect(keys.due(at: 1) == nil)
    }

    @Test("A wait never ends before the key is due")
    func waitRoundsUp() {
        var keys = apus()
        keys.pressed(a, repeats: true, at: 0)
        #expect(keys.wait(at: 0.5999) == 1)
        #expect(keys.wait(at: 0.7) == 0)
    }
}
