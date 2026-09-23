import Render
@testable import Notes
import Testing
import Toolkit

// What Notes does with the keys, and what it writes. The folder is the one
// in Folder.swift.

@Suite("Notes")
struct NotesTests {
    @Test("The notes are the text files of the folder, the newest first, with the first note open")
    func list() {
        let store = NotesStore(folder: Folder())
        #expect(store.notes.map(\.name) == ["Plans.md", "Shopping.txt"])
        #expect(store.notes.map(\.title) == ["Plans for the week", "Shopping"])
        #expect(store.notes[0].excerpt == "Finish the notes app")
        #expect(store.open == "Plans.md")
        #expect(store.editing.caret == 0, "a note opens at its start")
        #expect(store.focus == .list)
    }

    @Test("Down opens the next note, and Enter gives the keys to the editor")
    func walkTheList() {
        let store = NotesStore(folder: Folder())
        store.key(.down)
        #expect(store.open == "Shopping.txt")
        #expect(store.editing.text.hasPrefix("Shopping\nMilk"))
        store.key(.enter)
        #expect(store.focus == .editor)
        store.key(.escape)
        #expect(store.focus == .list)
    }

    @Test("Each change is saved at once, and the note goes to the top")
    func saveOnChange() {
        let folder = Folder()
        let store = NotesStore(folder: folder)
        store.key(.down)
        store.key(.enter)
        store.key(KeyEvent(keysym: 0xFF57, control: true))   // Control+End
        store.type("\nButter")
        #expect(folder.files["Shopping.txt"]?.text == "Shopping\nMilk\nEggs\nBread\nButter")
        #expect(folder.writes.count == 7, "one write for each key that changed the text")
        #expect(store.notes.first?.name == "Shopping.txt")
        #expect(store.selection == 0)
        #expect(store.editing.caretPosition == (4, 6))
        #expect(!store.isUnsaved)
    }

    @Test("A letter in the list starts to type in the open note")
    func typeFromTheList() {
        let folder = Folder()
        let store = NotesStore(folder: folder)
        store.type("A")
        #expect(store.focus == .editor)
        #expect(folder.files["Plans.md"]?.text.hasPrefix("A# Plans") == true)
    }

    @Test("Control+N makes a note, and a second one gets a number")
    func newNotes() {
        let folder = Folder()
        let store = NotesStore(folder: folder)
        store.key(.newNote)
        #expect(store.open == "Untitled.txt")
        #expect(store.focus == .editor)
        #expect(folder.files["Untitled.txt"]?.text == "")
        store.type("Ideas")
        #expect(store.notes.first?.title == "Ideas")
        store.key(.newNote)
        #expect(store.open == "Untitled 2.txt")
        #expect(store.notes.count == 4)
    }

    @Test("Selection and a change over it")
    func selection() {
        let folder = Folder()
        let store = NotesStore(folder: folder)
        store.key(.down)
        store.key(.enter)
        store.key(.selectAll)
        #expect(store.editing.selectedText == folder.files["Shopping.txt"]?.text)
        store.type("Nothing")
        #expect(folder.files["Shopping.txt"]?.text == "Nothing")
    }

    @Test("Delete asks twice in the list, and forgets after five seconds")
    func delete() {
        let folder = Folder()
        let store = NotesStore(folder: folder)
        store.tick(now: 10)
        store.key(.delete)
        #expect(store.armed == "Plans.md")
        #expect(folder.files["Plans.md"] != nil)
        store.tick(now: 16)
        #expect(store.armed == nil)
        store.key(.delete)
        store.key(.delete)
        #expect(folder.files["Plans.md"] == nil)
        #expect(store.open == "Shopping.txt")
        #expect(store.notes.map(\.name) == ["Shopping.txt"])
    }

    @Test("A write that fails says so, and the text stays on the screen")
    func failedWrite() {
        let folder = Folder()
        folder.failWrites = true
        let store = NotesStore(folder: folder)
        store.key(.enter)
        store.type("x")
        #expect(store.isUnsaved)
        #expect(store.notice == "~/Notes/Plans.md cannot be written")
        #expect(store.editing.text.hasPrefix("x"))
        folder.failWrites = false
        store.type("y")
        #expect(!store.isUnsaved && store.notice == nil)
        #expect(folder.files["Plans.md"]?.text.hasPrefix("xy") == true)
    }

    @Test("A note that changed on the disk comes in, unless someone is typing in it")
    func changedOnDisk() {
        let folder = Folder()
        let store = NotesStore(folder: folder)
        folder.files["Plans.md"] = ("Plans, from the terminal", 900)
        store.tick(now: 5)
        #expect(store.editing.text == "Plans, from the terminal")
        store.key(.enter)
        folder.files["Plans.md"] = ("From somewhere else", 950)
        store.tick(now: 10)
        #expect(store.editing.text == "Plans, from the terminal", "the editor has the keys")
        folder.files["Notes.txt"] = ("New from the terminal", 2000)
        store.tick(now: 15)
        #expect(store.notes.first?.name == "Notes.txt")
        #expect(store.open == "Plans.md", "the open note stays open")
    }

    @Test("An empty folder says how to start")
    func empty() {
        let folder = Folder()
        folder.files = [:]
        let store = NotesStore(folder: folder)
        #expect(store.open == nil)
        store.key(.enter)
        #expect(store.focus == .list, "there is no note to type in")
        preview(NotesView(store: store, sizeClass: .large), width: 1000, height: 600,
                name: "notes-empty")
    }

    @Test("Every size draws, and the previews are written")
    func everySizeDraws() {
        let store = NotesStore(folder: Folder())
        store.key(.down)
        store.key(.enter)
        store.key(.down)
        store.key(.shiftUp)
        let large = preview(NotesView(store: store, sizeClass: .large), width: 1184, height: 744,
                            name: "notes-large")
        #expect(large.contains { $0 != large[0] })
        preview(NotesView(store: store, sizeClass: .compact), width: 560, height: 744,
                name: "notes-compact")
        let tile = preview(NotesTile(store: store), width: 256, height: 256, name: "notes-tile")
        #expect(tile.contains { $0 != tile[0] })
        let pass = ViewRenderer.render(NotesView(store: store, sizeClass: .large),
                                       in: Rect(x: 0, y: 0, width: 1184, height: 744))
        #expect(pass.keyRegions.count == 1)
        store.tick(now: 0)
        store.key(.escape)
        store.key(.delete)
        preview(NotesView(store: store, sizeClass: .large), width: 1184, height: 744,
                name: "notes-delete")
    }

    @Test("A click on a note opens it, and a click on the editor gives it the keys")
    func clicks() {
        let store = NotesStore(folder: Folder())
        let host = ViewHost()
        let rect = Rect(x: 0, y: 0, width: 1000, height: 600)
        let view = { NotesView(store: store, sizeClass: .large) }
        _ = host.displayList(for: view(), in: rect)
        // The rows start under the head (52) and the place (26); the second
        // is 54 further on.
        host.pointerMoved(to: 100, y: 52 + 26 + 54 + 27)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(store.open == "Shopping.txt")
        _ = host.displayList(for: view(), in: rect)
        host.pointerMoved(to: 600, y: 300)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(store.focus == .editor)
    }
}
