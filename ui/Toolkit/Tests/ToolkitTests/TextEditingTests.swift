import Render
import Testing
@testable import Toolkit

// The text that a person types into, and the editor that draws it.

private func key(_ keysym: UInt32, _ characters: String = "", shift: Bool = false,
                 control: Bool = false) -> KeyEvent {
    KeyEvent(keysym: keysym, characters: characters, control: control, shift: shift)
}

private let left: UInt32 = 0xFF51, right: UInt32 = 0xFF53, up: UInt32 = 0xFF52
private let down: UInt32 = 0xFF54, home: UInt32 = 0xFF50, end: UInt32 = 0xFF57

private func typed(_ text: String, into editing: inout TextEditing) {
    for character in text {
        let keysym: UInt32 = character == "\n" ? 0xFF0D : 0x61
        editing.apply(key(keysym, character == "\n" ? "" : String(character)))
    }
}

@Suite("Text editing")
struct TextEditingTests {
    @Test("Typing writes at the caret, and Backspace and Delete take away")
    func typing() {
        var editing = TextEditing()
        typed("Milk\nEggs", into: &editing)
        #expect(editing.text == "Milk\nEggs")
        #expect(editing.caretPosition == (1, 4))
        editing.apply(key(0xFF08))
        #expect(editing.text == "Milk\nEgg")
        editing.apply(key(home))
        editing.apply(key(0xFFFF))
        #expect(editing.text == "Milk\ngg")
        #expect(editing.apply(key(0xFF1B)) == .unused, "Escape is for the app")
    }

    @Test("Up and Down keep the column over a shorter line")
    func upAndDown() {
        var editing = TextEditing("abcdef\nab\nabcdef")
        editing.move(.start)
        editing.move(.lineEnd)
        #expect(editing.caret == 6)
        editing.apply(key(down))
        #expect(editing.caretPosition == (1, 2), "the short line has two columns")
        editing.apply(key(down))
        #expect(editing.caretPosition == (2, 6), "the column comes back")
        editing.apply(key(up))
        editing.apply(key(up))
        #expect(editing.caretPosition == (0, 6))
        editing.apply(key(up))
        #expect(editing.caret == 0, "up from the first line goes to the start")
    }

    @Test("Shift with an arrow selects, and typing replaces the selection")
    func selecting() {
        var editing = TextEditing("one two three")
        editing.move(.start)
        editing.apply(key(right, control: true))
        #expect(editing.caret == 3)
        editing.apply(key(right, shift: true, control: true))
        #expect(editing.selectedText == " two")
        typed("!", into: &editing)
        #expect(editing.text == "one! three")
        #expect(editing.selection == nil)
        editing.apply(key(end, shift: true))
        editing.apply(key(left))
        #expect(editing.caret == 4, "Left ends a selection at its start")
    }

    @Test("Control+A selects everything, and Backspace takes it all")
    func selectAll() {
        var editing = TextEditing("a\nb")
        #expect(editing.apply(key(0x61, control: true)) == .moved)
        #expect(editing.selectedText == "a\nb")
        editing.apply(key(0xFF08))
        #expect(editing.text.isEmpty)
    }

    @Test("A long line wraps at a space, and a long word where it must")
    func wrapping() {
        let editing = TextEditing("the quick brown fox\n\nabcdefghij")
        let rows = editing.rows(columns: 10)
        let texts = rows.map { String(editing.characters[$0.range]) }
        #expect(texts == ["the quick ", "brown fox", "", "abcdefghij"])
        #expect(rows.map(\.endsLine) == [false, true, true, true])
        let narrow = TextEditing("abcdefghij").rows(columns: 4)
        #expect(narrow.map(\.range) == [0..<4, 4..<8, 8..<10])
    }

    @Test("The caret at a wrap is at the start of the next row")
    func caretAtAWrap() {
        var editing = TextEditing("the quick brown")
        let rows = editing.rows(columns: 10)
        editing.place(at: 10)
        #expect(editing.caretRow(in: rows) == (row: 1, column: 0))
        editing.place(at: 15)
        #expect(editing.caretRow(in: rows) == (row: 1, column: 5))
    }

    @Test("The editor draws its rows, the selection and the caret, and scrolls to the caret")
    func editorDraws() {
        var editing = TextEditing((1...60).map { "Line \($0)" }.joined(separator: "\n"))
        editing.move(.start)
        editing.move(.down, extend: true)
        let state = ViewState()
        let pass = ViewRenderer.render(TextEditor(editing, isFocused: true),
                                       in: Rect(x: 0, y: 0, width: 300, height: 200),
                                       state: state)
        let bitmaps = pass.list.count { if case .bitmap = $0 { true } else { false } }
        #expect(bitmaps > 5 && bitmaps < 15, "only the rows that show are drawn")
        #expect(pass.scrollRegions.count == 1)
        // The caret goes to the end, and the editor follows it.
        editing.move(.end)
        let after = ViewRenderer.render(TextEditor(editing, isFocused: true),
                                        in: Rect(x: 0, y: 0, width: 300, height: 200),
                                        state: state)
        let texts = after.list.compactMap { item -> Int? in
            if case .bitmap(_, _, let y) = item { return y } else { return nil }
        }
        #expect(texts.contains { $0 > 150 }, "the last lines are at the bottom")
        #expect(!after.scrollRegions.isEmpty)
    }
}
