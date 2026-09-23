import Render
@testable import Files
import Testing
import Toolkit

// What Files does with the keys and the clicks, and what it makes of the
// names in a folder. The disk is the one in Disk.swift.

@Suite("Files")
struct FilesTests {
    @Test("It opens in the home folder, with the folders first and the hidden files away")
    func firstFolder() {
        let store = FilesStore(system: Disk())
        #expect(store.path == "/root")
        #expect(store.entries.map(\.name)
                == ["Notes", "Pictures", "apus.img", "build.sh", "notes.txt", "old"])
        #expect(store.summary == "2 folders · 4 files · 1 hidden")
        store.toggleHidden()
        #expect(store.entries.first { $0.isHidden }?.name == ".bashrc")
        #expect(store.summary == "2 folders · 5 files")
    }

    @Test("Enter opens a folder, and Backspace goes up to the line it came from")
    func openAndUp() {
        let store = FilesStore(system: Disk())
        store.key(.down)
        #expect(store.selected?.name == "Pictures")
        store.key(.enter)
        #expect(store.path == "/root/Pictures")
        #expect(store.entries.isEmpty)
        store.key(.backspace)
        #expect(store.path == "/root")
        #expect(store.selected?.name == "Pictures", "the folder that it came from is selected")
        store.key(.left)
        #expect(store.path == "/")
        #expect(store.selected?.name == "root")
        store.key(.left)
        #expect(store.path == "/", "the top has nothing over it")
    }

    @Test("A file does not open yet, and the notice says so")
    func fileWaits() {
        let disk = Disk()
        let store = FilesStore(system: disk)
        store.key(.letter("n"))
        #expect(store.selected?.name == "notes.txt")
        store.key(.enter)
        #expect(store.path == "/root")
        #expect(store.notice?.contains("cannot open notes.txt yet") == true)
        store.key(.escape)
        #expect(store.notice == nil)
    }

    @Test("A folder that cannot be read says why, and Up still works")
    func unreadable() {
        let store = FilesStore(system: Disk(), path: "/usr")
        store.key(.end)
        store.key(.enter)
        #expect(store.path == "/usr/lib")
        #expect(store.failed)
        #expect(store.notice == "You may not read /usr/lib")
        store.key(.backspace)
        #expect(!store.failed && store.notice == nil)
        #expect(store.selected?.name == "lib")
    }

    @Test("A letter goes to the next name that starts with it")
    func typeToFind() {
        let store = FilesStore(system: Disk(), path: "/")
        store.key(.letter("t"))
        #expect(store.selected?.name == "tmp")
        store.key(.letter("u"))
        #expect(store.selected?.name == "usr")
        store.key(.letter("~"))
        #expect(store.path == "/root")
        store.key(.letter("/"))
        #expect(store.path == "/")
    }

    @Test("A click selects a line, and a click on the selected line opens it")
    func clicks() {
        let store = FilesStore(system: Disk())
        let host = ViewHost()
        let rect = Rect(x: 0, y: 0, width: 1000, height: 700)
        let view = { FilesView(store: store, sizeClass: .large, height: 700) }
        _ = host.displayList(for: view(), in: rect)
        // The list starts under the bar (52), the heads (26), the line (1)
        // and its own space (4). Pictures is its second row.
        let y = 52.0 + 26 + 1 + 4 + 32 + 16
        host.pointerMoved(to: 500, y: y)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(store.selected?.name == "Pictures")
        _ = host.displayList(for: view(), in: rect)
        host.pointerButton(pressed: true)
        host.pointerButton(pressed: false)
        #expect(store.path == "/root/Pictures")
    }

    @Test("A place in the sidebar opens its folder, and a place that is not there is left out")
    func places() {
        let disk = Disk()
        disk.folders["/tmp"] = nil
        let store = FilesStore(system: disk)
        #expect(store.places.map(\.title) == ["Home", "Notes", "Applications", "Computer"])
        store.open(store.places[2].path)
        #expect(store.path == "/Applications")
    }

    @Test("The folder is read again, and the selection stays on its name")
    func reread() {
        let disk = Disk()
        let store = FilesStore(system: disk)
        store.key(.down)
        store.key(.down)
        #expect(store.selected?.name == "apus.img")
        disk.folders["/root"]!.append(FileEntry(name: "Archive", kind: .folder))
        store.tick(now: 1)
        #expect(store.entries.count == 6, "not yet: the folder is read every two seconds")
        store.tick(now: 3)
        #expect(store.entries.first?.name == "Archive")
        #expect(store.selected?.name == "apus.img")
    }

    @Test("The way to a folder starts at Home inside the home folder")
    func trail() {
        #expect(Paths.trail(of: "/root/Notes/", home: "/root").map(\.title) == ["Home", "Notes"])
        #expect(Paths.trail(of: "/usr/bin", home: "/root").map(\.path) == ["/", "/usr", "/usr/bin"])
        #expect(Paths.trail(of: "/rootless", home: "/root").first?.title == "Computer")
        #expect(Paths.parent(of: "/usr/bin/") == "/usr")
        #expect(Paths.parent(of: "/usr") == "/")
        #expect(Paths.join("/", "tmp") == "/tmp")
    }

    @Test("A kind comes from the end of the name, and a size is in the words of a person")
    func kindsAndSizes() {
        #expect(FileEntry(name: "a.SWIFT", kind: .file).kindText == "Swift source")
        #expect(FileEntry(name: "Makefile", kind: .file).kindText == "File")
        #expect(FileEntry(name: ".bashrc", kind: .file).kindText == "File")
        #expect(FileEntry(name: "x.pkg", kind: .file).kindText == "PKG file")
        #expect(FileEntry(name: "bin", kind: .folder, isLink: true).kindText == "Link to folder")
        #expect(FileEntry(name: "d", kind: .folder).sizeText == "—")
        #expect(FileEntry.size(1) == "1 byte")
        #expect(FileEntry.size(812) == "812 bytes")
        #expect(FileEntry.size(4200) == "4.1 KB")
        #expect(FileEntry.size(10_230) == "10.0 KB" || FileEntry.size(10_230) == "10 KB")
        #expect(FileEntry.size(3 << 30) == "3.0 GB")
        #expect(FileEntry.size(38 << 20) == "38 MB")
    }

    @Test("A folder of thousands draws only the rows that can show")
    func longFolder() {
        let store = FilesStore(system: Disk(), path: "/usr/bin")
        let pass = ViewRenderer.render(FilesView(store: store, sizeClass: .large, height: 700),
                                       in: Rect(x: 0, y: 0, width: 1000, height: 700))
        #expect(pass.tapRegions.count < 100)
        store.key(.end)
        #expect(store.selected?.name == "tool999" || store.selection == 2999)
        let range = store.reveal()
        #expect(range?.lowerBound == 2999 * Metrics.row)
    }

    @Test("Every size draws, and the previews are written")
    func everySizeDraws() {
        let store = FilesStore(system: Disk())
        store.key(.down)
        let large = preview(FilesView(store: store, sizeClass: .large, height: 744),
                            width: 1184, height: 744, name: "files-large")
        #expect(large.contains { $0 != large[0] })
        preview(FilesView(store: store, sizeClass: .compact, height: 744),
                width: 560, height: 744, name: "files-compact")
        let tile = preview(FilesTile(store: store), width: 256, height: 256, name: "files-tile")
        #expect(tile.contains { $0 != tile[0] })
        let failed = FilesStore(system: Disk(), path: "/usr/lib")
        preview(FilesView(store: failed, sizeClass: .large, height: 500),
                width: 900, height: 500, name: "files-unreadable")
        let pass = ViewRenderer.render(FilesView(store: store, sizeClass: .large, height: 744),
                                       in: Rect(x: 0, y: 0, width: 1184, height: 744))
        #expect(pass.keyRegions.count == 1)
    }
}
