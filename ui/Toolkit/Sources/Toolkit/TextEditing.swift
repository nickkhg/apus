// Text that a person types into: the characters, where the caret is, and
// what is selected.
//
// This is a value, as a view is. An app keeps one, gives it the keys with
// `apply(_:)`, and gives it to a `TextEditor` to draw. The toolkit has no
// focus, so the app decides which editor the keys go to.
//
//     var note = TextEditing("Shopping\nMilk")
//     note.apply(key)            // .edited, .moved or .unused
//     TextEditor(note, isFocused: true)
//
// The caret is an index into the characters, from 0 to the count. The
// selection is the characters between the caret and the anchor, which stays
// where a Shift+arrow started.

public struct TextEditing: Equatable, Sendable {
    public private(set) var characters: [Character]
    /// Where the caret is: before the character with this index.
    public private(set) var caret: Int
    /// The other end of the selection. It is the caret when nothing is
    /// selected.
    public private(set) var anchor: Int
    /// The column that Up and Down keep while they move over shorter lines.
    private var goalColumn: Int?

    /// What a key did.
    public enum Change: Equatable, Sendable {
        /// The key is not one that edits text. It goes on.
        case unused
        /// The caret or the selection moved.
        case moved
        /// The text changed.
        case edited
    }

    public enum Motion: Sendable {
        case left, right, up, down
        case wordLeft, wordRight
        case lineStart, lineEnd
        case start, end
    }

    /// The caret goes at the end.
    public init(_ text: String = "") {
        characters = Array(text)
        caret = characters.count
        anchor = caret
    }

    public var text: String { String(characters) }

    /// The characters that are selected, or nil.
    public var selection: Range<Int>? {
        caret == anchor ? nil : min(caret, anchor)..<max(caret, anchor)
    }

    public var selectedText: String {
        selection.map { String(characters[$0]) } ?? ""
    }

    // MARK: - The keys

    /// Does what a key means in a text: it writes, removes, or moves.
    @discardableResult
    public mutating func apply(_ key: KeyEvent) -> Change {
        guard key.isPressed else { return .unused }
        let extend = key.shift
        // Control or Alt with an arrow moves by a word, and with Home or
        // End goes to the start or the end of the whole text.
        let chord = key.control || key.alt
        switch key.named {
        case .left: move(chord ? .wordLeft : .left, extend: extend)
        case .right: move(chord ? .wordRight : .right, extend: extend)
        case .up: move(.up, extend: extend)
        case .down: move(.down, extend: extend)
        case .home: move(chord ? .start : .lineStart, extend: extend)
        case .end: move(chord ? .end : .lineEnd, extend: extend)
        case .backspace:
            deleteBackward()
            return .edited
        case .delete:
            deleteForward()
            return .edited
        case .enter:
            insert("\n")
            return .edited
        case .escape, .tab:
            return .unused
        case .other:
            // Control+A writes no character, so the keysym says which key.
            if key.control, key.keysym == 0x61 || key.keysym == 0x41 {
                selectAll()
                return .moved
            }
            guard !key.characters.isEmpty, !key.control, !key.alt else { return .unused }
            insert(key.characters)
            return .edited
        }
        return .moved
    }

    // MARK: - Changes

    /// Writes text at the caret, over the selection if there is one.
    public mutating func insert(_ text: String) {
        let range = selection ?? caret..<caret
        characters.replaceSubrange(range, with: Array(text))
        caret = range.lowerBound + text.count
        anchor = caret
        goalColumn = nil
    }

    /// Backspace: the selection, or the character before the caret.
    public mutating func deleteBackward() {
        if let range = selection { return remove(range) }
        guard caret > 0 else { return }
        remove((caret - 1)..<caret)
    }

    /// Delete: the selection, or the character after the caret.
    public mutating func deleteForward() {
        if let range = selection { return remove(range) }
        guard caret < characters.count else { return }
        remove(caret..<(caret + 1))
    }

    private mutating func remove(_ range: Range<Int>) {
        characters.removeSubrange(range)
        caret = range.lowerBound
        anchor = caret
        goalColumn = nil
    }

    public mutating func selectAll() {
        anchor = 0
        caret = characters.count
        goalColumn = nil
    }

    /// Puts the caret at an index, with nothing selected.
    public mutating func place(at index: Int) {
        caret = min(max(0, index), characters.count)
        anchor = caret
        goalColumn = nil
    }

    // MARK: - Moves

    /// Moves the caret. With `extend`, the selection grows or shrinks with
    /// it. Without, a selection ends: Left and Right go to its edge.
    public mutating func move(_ motion: Motion, extend: Bool = false) {
        if !extend, let range = selection, motion == .left || motion == .right {
            place(at: motion == .left ? range.lowerBound : range.upperBound)
            return
        }
        let vertical = motion == .up || motion == .down
        let target: Int
        switch motion {
        case .left: target = caret - 1
        case .right: target = caret + 1
        case .wordLeft: target = wordStart(before: caret)
        case .wordRight: target = wordEnd(after: caret)
        case .lineStart: target = lineStart(of: caret)
        case .lineEnd: target = lineEnd(of: caret)
        case .start: target = 0
        case .end: target = characters.count
        case .up, .down:
            let start = lineStart(of: caret)
            let column = goalColumn ?? (caret - start)
            goalColumn = column
            if motion == .up {
                guard start > 0 else {
                    target = 0
                    break
                }
                let previous = lineStart(of: start - 1)
                target = min(previous + column, start - 1)
            } else {
                let end = lineEnd(of: caret)
                guard end < characters.count else {
                    target = characters.count
                    break
                }
                let next = end + 1
                target = min(next + column, lineEnd(of: next))
            }
        }
        caret = min(max(0, target), characters.count)
        if !extend { anchor = caret }
        if !vertical { goalColumn = nil }
    }

    /// The index of the first character of the line that holds `index`.
    public func lineStart(of index: Int) -> Int {
        var position = min(index, characters.count)
        while position > 0, characters[position - 1] != "\n" { position -= 1 }
        return position
    }

    /// The index of the newline that ends the line that holds `index`, or
    /// the count for the last line.
    public func lineEnd(of index: Int) -> Int {
        var position = min(index, characters.count)
        while position < characters.count, characters[position] != "\n" { position += 1 }
        return position
    }

    /// The line of the caret and its column, from 0, in characters.
    public var caretPosition: (line: Int, column: Int) {
        let line = characters[..<caret].count { $0 == "\n" }
        return (line, caret - lineStart(of: caret))
    }

    private func isWord(_ index: Int) -> Bool {
        let character = characters[index]
        return character.isLetter || character.isNumber || character == "_"
    }

    private func wordStart(before index: Int) -> Int {
        var position = index
        while position > 0, !isWord(position - 1) { position -= 1 }
        while position > 0, isWord(position - 1) { position -= 1 }
        return position
    }

    private func wordEnd(after index: Int) -> Int {
        var position = index
        while position < characters.count, !isWord(position) { position += 1 }
        while position < characters.count, isWord(position) { position += 1 }
        return position
    }
}
