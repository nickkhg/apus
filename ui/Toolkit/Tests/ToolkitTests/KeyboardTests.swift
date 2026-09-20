import Render
import Testing
@testable import Toolkit

// The keys follow the same rule as the pointer: the view in front reads a
// key first, and a key that no view used belongs to whatever is under the
// toolkit.

@Suite("The keyboard")
struct KeyboardTests {
    private let box = Rect(x: 0, y: 0, width: 100, height: 100)

    /// A view that writes down every key it is given, and says whether it
    /// used it.
    private struct Reader: View {
        let log: Log
        let uses: Bool

        final class Log: @unchecked Sendable {
            var keys: [KeyEvent] = []
        }

        var body: some View {
            Color.white.onKey { key in
                log.keys.append(key)
                return uses
            }
        }
    }

    private func letter(_ text: String) -> KeyEvent {
        KeyEvent(keysym: UInt32(text.unicodeScalars.first!.value), characters: text)
    }

    @Test("A view with no reader leaves the key alone")
    func nobodyTakesTheKey() {
        let host = ViewHost()
        _ = host.displayList(for: Color.white, in: box)
        #expect(!host.key(letter("a")))
    }

    @Test("A reader gets the key and can take it")
    func aReaderTakesTheKey() {
        let log = Reader.Log()
        let host = ViewHost()
        _ = host.displayList(for: Reader(log: log, uses: true), in: box)
        #expect(host.key(letter("a")))
        #expect(log.keys.count == 1)
        #expect(log.keys.first?.characters == "a")
    }

    @Test("A key that a reader does not use goes on")
    func anUnusedKeyGoesOn() {
        let log = Reader.Log()
        let host = ViewHost()
        _ = host.displayList(for: Reader(log: log, uses: false), in: box)
        #expect(!host.key(letter("a")))
        #expect(log.keys.count == 1)
    }

    @Test("The reader in front reads first, and stops the one behind")
    func theFrontReaderWins() {
        let back = Reader.Log()
        let front = Reader.Log()
        let host = ViewHost()
        let view = ZStack {
            Reader(log: back, uses: true)
            Reader(log: front, uses: true)
        }
        _ = host.displayList(for: view, in: box)
        #expect(host.key(letter("a")))
        #expect(front.keys.count == 1)
        #expect(back.keys.isEmpty)
    }

    @Test("A reader that does not use the key lets the one behind try")
    func theKeyFallsThrough() {
        let back = Reader.Log()
        let front = Reader.Log()
        let host = ViewHost()
        let view = ZStack {
            Reader(log: back, uses: true)
            Reader(log: front, uses: false)
        }
        _ = host.displayList(for: view, in: box)
        #expect(host.key(letter("a")))
        #expect(front.keys.count == 1)
        #expect(back.keys.count == 1)
    }

    @Test("A reader that left the tree reads nothing")
    func aReaderThatWentAwayIsSilent() {
        let log = Reader.Log()
        let host = ViewHost()
        _ = host.displayList(for: Reader(log: log, uses: true), in: box)
        _ = host.displayList(for: Color.white, in: box)
        #expect(!host.key(letter("a")))
        #expect(log.keys.isEmpty)
    }

    @Test("The named keys have the numbers of the keymap")
    func namedKeysAreRight() {
        #expect(KeyEvent(keysym: 0xFF1B).named == .escape)
        #expect(KeyEvent(keysym: 0xFF0D).named == .enter)
        #expect(KeyEvent(keysym: 0xFF09).named == .tab)
        #expect(KeyEvent(keysym: 0xFF08).named == .backspace)
        #expect(KeyEvent(keysym: 0xFF52).named == .up)
        #expect(KeyEvent(keysym: 0xFF54).named == .down)
        // A key that writes a character has no name of its own.
        #expect(KeyEvent(keysym: 0x61, characters: "a").named == .other)
    }
}
