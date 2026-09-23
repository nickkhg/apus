import Toolkit

// What Notes is doing: the notes of the folder, the one that is open, where
// the caret is in it, and which part of the window has the keys.
//
// A note is saved on every change. There is no Save and nothing to lose:
// the file is the note, and each key that changes the text writes the file
// again, in one step.

public final class NotesStore {
    /// Which part of the window reads the keys. The toolkit has no focus,
    /// so the app keeps its own, and the accent marks the part that has it.
    public enum Focus: Sendable { case list, editor }

    let folder: NotesFolder
    /// Called after anything that the window shows changed.
    public var changed: () -> Void = {}

    /// The notes, the newest first.
    public private(set) var notes: [Note] = []
    public private(set) var selection = 0
    /// The name of the note in the editor, or nil when there is none.
    public private(set) var open: String?
    public private(set) var editing = TextEditing()
    public private(set) var focus = Focus.list
    /// A failure, in words: the folder, a read or a write.
    public private(set) var notice: String?
    /// The last write failed, so the text on the screen is not the file.
    public private(set) var isUnsaved = false
    /// The note that a second Delete takes away, and when the first came.
    public private(set) var armed: String?
    private var armedAt = 0.0

    private var now = 0.0
    private var lastRead = 0.0

    static let readInterval = 3.0
    static let confirmTime = 5.0

    public init(folder: NotesFolder) {
        self.folder = folder
        notice = folder.prepare()
        reload()
        if let first = notes.first { show(first.name) }
    }

    public var selected: Note? {
        notes.indices.contains(selection) ? notes[selection] : nil
    }

    /// The words and the characters of the open note.
    public var summary: String { count(of: editing.text) }

    // MARK: - The notes

    /// Opens a note in the editor. The keys stay where they were.
    public func select(_ index: Int) {
        guard notes.indices.contains(index) else { return }
        selection = index
        armed = nil
        if notes[index].name != open { show(notes[index].name) }
        changed()
    }

    private func show(_ name: String) {
        guard let text = folder.read(name) else {
            notice = "\(name) cannot be read"
            return
        }
        open = name
        editing = TextEditing(text)
        // A note opens at its start, where its title is.
        editing.place(at: 0)
        isUnsaved = false
    }

    /// Makes a note with nothing in it, and gives it the keys.
    public func newNote() {
        let names = Set(folder.list().map(\.name))
        var name = "Untitled.txt"
        var number = 2
        while names.contains(name) {
            name = "Untitled \(number).txt"
            number += 1
        }
        switch folder.write(name, "") {
        case .failed(let reason):
            notice = reason
        case .saved(let modified):
            notice = nil
            notes.insert(Note(file: NoteFile(name: name, modified: modified), text: ""), at: 0)
            selection = 0
            open = name
            editing = TextEditing()
            isUnsaved = false
            focus = .editor
        }
        armed = nil
        changed()
    }

    /// The first press of Delete asks, and the second takes the note away.
    public func delete() {
        guard let note = selected else { return }
        guard armed == note.name, now - armedAt <= NotesStore.confirmTime else {
            armed = note.name
            armedAt = now
            changed()
            return
        }
        armed = nil
        if let problem = folder.remove(note.name) {
            notice = problem
        } else {
            notice = nil
            notes.remove(at: selection)
            selection = min(selection, max(0, notes.count - 1))
            if let next = selected {
                show(next.name)
            } else {
                open = nil
                editing = TextEditing()
            }
        }
        changed()
    }

    public func focus(_ focus: Focus) {
        guard focus != self.focus else { return }
        // The editor needs a note to take the keys.
        guard focus == .list || open != nil else { return }
        self.focus = focus
        armed = nil
        changed()
    }

    // MARK: - Saving

    /// Writes the open note. It runs after every change of the text.
    private func save() {
        guard let open else { return }
        switch folder.write(open, editing.text) {
        case .failed(let reason):
            notice = reason
            isUnsaved = true
        case .saved(let modified):
            if isUnsaved { notice = nil }
            isUnsaved = false
            let note = Note(file: NoteFile(name: open, modified: modified), text: editing.text)
            if let index = notes.firstIndex(where: { $0.name == open }) {
                notes.remove(at: index)
            }
            // The note that changed is the newest, so it goes to the top.
            notes.insert(note, at: 0)
            selection = 0
        }
    }

    // MARK: - Time

    /// About once a second. The folder is read again now and then: a note
    /// can come from the terminal, or change there.
    public func tick(now: Double) {
        self.now = now
        if armed != nil, now - armedAt > NotesStore.confirmTime {
            armed = nil
            changed()
        }
        guard now - lastRead >= NotesStore.readInterval else { return }
        let before = notes
        reload()
        // A note that changed on the disk comes into the editor, unless a
        // person is typing in it, or the last write failed.
        if let open, focus == .list, !isUnsaved, let text = folder.read(open),
           text != editing.text {
            editing = TextEditing(text)
            editing.place(at: 0)
        }
        if notes != before { changed() }
    }

    /// Reads the list again. The selection stays on the note that is open.
    func reload() {
        lastRead = now
        notes = folder.list()
            .filter { Note.isNote($0.name) }
            .map { Note(file: $0, text: folder.read($0.name) ?? "") }
            .sorted { $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified }
        guard let name = open else { return }
        if let index = notes.firstIndex(where: { $0.name == name }) {
            selection = index
        } else {
            // The file went away under the editor.
            open = nil
            editing = TextEditing()
            focus = .list
            selection = min(selection, max(0, notes.count - 1))
            if let next = selected { show(next.name) }
        }
    }

    // MARK: - The keys

    /// Every key of the window. It answers whether it used the key.
    @discardableResult
    public func key(_ key: KeyEvent) -> Bool {
        guard key.isPressed else { return true }
        // Control+N writes no character, so the keysym says which key.
        if key.control, key.keysym == 0x6E || key.keysym == 0x4E {
            newNote()
            return true
        }
        switch focus {
        case .list: return listKey(key)
        case .editor: return editorKey(key)
        }
    }

    private func listKey(_ key: KeyEvent) -> Bool {
        switch key.named {
        case .up: select(max(0, selection - 1))
        case .down: select(min(max(0, notes.count - 1), selection + 1))
        case .home: select(0)
        case .end: select(max(0, notes.count - 1))
        case .enter, .right, .tab: focus(.editor)
        case .delete, .backspace: delete()
        case .escape:
            guard armed != nil else { return false }
            armed = nil
            changed()
        default:
            // A letter starts to type in the open note.
            guard open != nil, !key.characters.isEmpty, !key.control, !key.alt else {
                return false
            }
            focus(.editor)
            return editorKey(key)
        }
        return true
    }

    private func editorKey(_ key: KeyEvent) -> Bool {
        switch key.named {
        case .escape, .tab:
            focus(.list)
            return true
        default:
            switch editing.apply(key) {
            case .unused: return false
            case .moved: break
            case .edited: save()
            }
            changed()
            return true
        }
    }
}
