import Toolkit

// What Files is doing: the folder that is open, the line that is selected,
// and what came of the last thing a person asked for. The views read it and
// call it; they keep only how the pointer lights them.
//
// Every key of the window goes through `key(_:)`. There is one list, so
// there is no focus to keep: the list always has the keys.

public final class FilesStore {
    let system: FileSystem
    /// Called after anything that the window shows changed.
    public var changed: () -> Void = {}

    /// The folder that is open.
    public private(set) var path: String
    /// What the list shows: the entries of the folder, without the hidden
    /// ones unless a person asked for them.
    public private(set) var entries: [FileEntry] = []
    /// Every entry of the folder, the hidden ones too.
    public private(set) var all: [FileEntry] = []
    public private(set) var selection = 0
    public private(set) var showsHidden = false
    /// Why the folder cannot be read, or what a key could not do.
    public private(set) var notice: String?
    /// The folder could not be read, so the list is empty for a reason.
    public private(set) var failed = false

    /// How far the list is scrolled.
    var offset = 0.0
    /// The keyboard moved the selection, so the list shows it in the next
    /// frame. See ScrollView(offset:reveal:).
    private var revealSelection = true
    /// Seconds, from the clock that `tick` gives.
    private var now = 0.0
    private var lastRead = 0.0

    /// How often the folder is read again: a program or a terminal can
    /// change it while the window is open.
    static let readInterval = 2.0

    public init(system: FileSystem, path: String? = nil) {
        self.system = system
        self.path = Paths.normal(path ?? system.home)
        read(keeping: nil)
    }

    /// The folders of the sidebar that are there on this machine.
    public var places: [Place] {
        let home = system.home
        let all = [
            Place(title: "Home", path: home, mark: Ink.mark),
            Place(title: "Notes", path: Paths.join(home, "Notes"), mark: Color(hex: 0xF2C94C)),
            Place(title: "Applications", path: "/Applications", mark: Color(hex: 0x3070F0)),
            Place(title: "Temporary", path: "/tmp", mark: Color(hex: 0x6C777D)),
            Place(title: "Computer", path: "/", mark: Color(hex: 0xA3AEB4)),
        ]
        return all.filter { $0.path == home || system.isFolder($0.path) }
    }

    /// The folders from the top down to the one that is open.
    public var trail: [(title: String, path: String)] {
        Paths.trail(of: path, home: system.home)
    }

    public var selected: FileEntry? {
        entries.indices.contains(selection) ? entries[selection] : nil
    }

    /// How many folders and how many other things the folder holds, as the
    /// foot of the list says it.
    public var summary: String {
        guard !failed else { return "" }
        let folders = entries.count { $0.kind == .folder }
        let files = entries.count - folders
        let hidden = all.count - entries.count
        var parts = [count(folders, "folder"), count(files, "file")]
        if hidden > 0 { parts.append("\(hidden) hidden") }
        return parts.joined(separator: " · ")
    }

    private func count(_ number: Int, _ word: String) -> String {
        number == 1 ? "1 \(word)" : "\(number) \(word)s"
    }

    // MARK: - Going places

    /// Opens a folder. A folder that cannot be read still opens, and the
    /// list says why it is empty, so that Up and the sidebar still work.
    public func open(_ path: String) {
        let from = self.path
        self.path = Paths.normal(path)
        offset = 0
        notice = nil
        // Going up selects the folder that the person came from.
        let keep = Paths.parent(of: from) == self.path ? Paths.name(of: from) : nil
        read(keeping: keep)
        changed()
    }

    /// Opens the folder that holds this one.
    public func goUp() {
        guard path != "/" else { return }
        open(Paths.parent(of: path))
    }

    /// Opens the line: a folder opens in the list. A file cannot open yet,
    /// and the notice says so.
    public func activate(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selection = index
        let entry = entries[index]
        switch entry.kind {
        case .folder:
            open(Paths.join(path, entry.name))
        case .brokenLink:
            notice = "\(entry.name) points to nothing"
            changed()
        default:
            notice = "Files cannot open \(entry.name) yet. Open it in the Terminal."
            changed()
        }
    }

    /// A click on a line selects it, and a click on the selected line opens
    /// it. The toolkit tells a view of no second click in a row.
    public func click(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        if index == selection {
            activate(index)
        } else {
            selection = index
            notice = failed ? notice : nil
            changed()
        }
    }

    public func toggleHidden() {
        showsHidden.toggle()
        let name = selected?.name
        filter()
        select(named: name)
        revealSelection = true
        changed()
    }

    // MARK: - Time

    /// About once a second. The folder is read again now and then, and the
    /// selection stays on the same name.
    public func tick(now: Double) {
        self.now = now
        guard now - lastRead >= FilesStore.readInterval else { return }
        let before = all
        read(keeping: selected?.name)
        if all != before { changed() }
    }

    private func read(keeping name: String?) {
        lastRead = now
        switch system.list(path) {
        case .entries(let list):
            all = sorted(list)
            if failed { notice = nil }
            failed = false
        case .failed(let reason):
            all = []
            failed = true
            notice = reason
        }
        filter()
        select(named: name)
    }

    private func filter() {
        entries = showsHidden ? all : all.filter { !$0.isHidden }
    }

    private func select(named name: String?) {
        if let name, let index = entries.firstIndex(where: { $0.name == name }) {
            if index != selection { revealSelection = true }
            selection = index
        } else {
            selection = min(selection, max(0, entries.count - 1))
            if name == nil {
                selection = 0
                revealSelection = true
            }
        }
    }

    // MARK: - The keys

    /// Every key of the window. It answers whether it used the key.
    @discardableResult
    public func key(_ key: KeyEvent) -> Bool {
        guard key.isPressed else { return true }
        let count = entries.count
        switch key.named {
        case .up where count > 0: move(to: selection - 1)
        case .down where count > 0: move(to: selection + 1)
        case .home: move(to: 0)
        case .end: move(to: count - 1)
        case .enter, .right: activate(selection)
        case .left, .backspace: goUp()
        case .escape:
            guard notice != nil, !failed else { return false }
            notice = nil
        default:
            // Control+H writes no character, so the keysym says which key.
            if key.control, key.keysym == 0x68 || key.keysym == 0x48 {
                toggleHidden()
            } else if !key.control, !key.alt, key.characters == "~" {
                open(system.home)
            } else if !key.control, !key.alt, key.characters == "/" {
                open("/")
            } else if !key.control, !key.alt, key.characters == "." {
                toggleHidden()
            } else if !key.control, !key.alt, let letter = key.characters.first,
                      letter.isLetter || letter.isNumber {
                jump(to: letter)
            } else {
                return false
            }
        }
        changed()
        return true
    }

    private func move(to index: Int) {
        guard !entries.isEmpty else { return }
        selection = min(max(0, index), entries.count - 1)
        revealSelection = true
    }

    /// A letter selects the next line whose name starts with it, so that a
    /// second press of the same letter goes on to the next one.
    private func jump(to letter: Character) {
        let wanted = String(letter).lowercased()
        let count = entries.count
        guard count > 0 else { return }
        for step in 1...count {
            let index = (selection + step) % count
            if entries[index].name.lowercased().hasPrefix(wanted) {
                move(to: index)
                return
            }
        }
    }

    // MARK: - Scrolling

    /// The row that the list shows once, in the frame after the keyboard
    /// moved the selection.
    func reveal() -> ClosedRange<Double>? {
        guard revealSelection, !entries.isEmpty else { return nil }
        revealSelection = false
        let top = Double(selection) * Metrics.row
        return top...(top + Metrics.row)
    }

    var offsetBinding: Binding<Double> {
        Binding(get: { [unowned self] in offset },
                set: { [unowned self] in
                    offset = $0
                    changed()
                })
    }
}
