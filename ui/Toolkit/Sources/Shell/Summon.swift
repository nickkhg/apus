import Toolkit

// Summon: the one surface that starts an app and moves to a window.
//
// There is no dock and no window switcher. Starting an app and moving to a
// window give the same result — that app is in front — so they are the same
// act. Summon also carries the commands of the system, so a person learns
// one thing instead of three.
//
// The list is in groups, and the order inside a group is the order of use.
// A window comes before an app, because a window that is already open is the
// nearer thing.

/// One line of Summon.
public struct SummonItem: Identifiable, Equatable, Sendable {
    /// What the item does when a person chooses it.
    public enum Kind: Equatable, Sendable {
        /// A window that is open: put it in front.
        case window(String)
        /// An app that is not open: start it.
        case app(String)
        /// An act of the system.
        case command(Command)
    }

    public enum Command: Equatable, Sendable {
        case closeFrontWindow
        case layout(WindowLayoutKind)
    }

    public let id: String
    /// The name, in the first line.
    public let name: String
    /// What it is, under the name.
    public let detail: String
    /// A word at the right, such as WINDOW.
    public let tag: String
    public let mark: Color
    public let kind: Kind

    public init(id: String, name: String, detail: String, tag: String = "",
                mark: Color = Palette.dimText, kind: Kind) {
        self.id = id
        self.name = name
        self.detail = detail
        self.tag = tag
        self.mark = mark
        self.kind = kind
    }
}

/// A named set of lines.
public struct SummonGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [SummonItem]
}

/// The sizes of Summon, in points.
enum SummonMetrics {
    static let width: Double = 720
    static let topMargin: Double = 96
    static let radius: Double = 16
    static let queryHeight: Double = 56
    static let rowHeight: Double = 44
    static let groupHeader: Double = 28
    static let footerHeight: Double = 36
    static let padding: Double = 12
}

/// What Summon lists, for a shell state.
public enum SummonList {
    /// Every line that the query leaves, in the order that they are shown.
    /// The selected line is an index into this.
    public static func items(for state: ShellState, query: String = "") -> [SummonItem] {
        groups(for: state, query: query).flatMap(\.items)
    }

    /// The line that Enter chooses.
    public static func selected(in state: ShellState, query: String = "",
                                at selection: Int = 0) -> SummonItem? {
        let all = items(for: state, query: query)
        guard !all.isEmpty else { return nil }
        return all[min(max(0, selection), all.count - 1)]
    }

    /// Does the query pick this line? A query matches when every word of it
    /// is somewhere in the name or in what the line says it is.
    static func matches(_ item: SummonItem, query: String) -> Bool {
        let text = "\(item.name) \(item.detail)".lowercased()
        let words = query.lowercased().split(separator: " ")
        return words.allSatisfy { text.contains($0) }
    }

    public static func groups(for state: ShellState, query: String = "") -> [SummonGroup] {
        // A query of spaces alone has no words, so it narrows nothing.
        let all = allGroups(for: state)
        guard !query.isEmpty else { return all }
        return all.compactMap { group in
            let left = group.items.filter { matches($0, query: query) }
            return left.isEmpty ? nil : SummonGroup(id: group.id, title: group.title, items: left)
        }
    }

    private static func allGroups(for state: ShellState) -> [SummonGroup] {
        var groups: [SummonGroup] = []

        let onScreen = state.windows.filter { $0.place != .rail }
        if !onScreen.isEmpty {
            groups.append(SummonGroup(id: "screen", title: "On the screen",
                                      items: onScreen.map { item(for: $0, in: state) }))
        }
        let waiting = state.windows.filter { $0.place == .rail }
        if !waiting.isEmpty {
            groups.append(SummonGroup(id: "rail", title: "In the rail",
                                      items: waiting.map { item(for: $0, in: state) }))
        }
        let running = state.runningApps
        let closed = state.apps.filter { !running.contains($0.id) }
        if !closed.isEmpty {
            groups.append(SummonGroup(id: "apps", title: "Not open", items: closed.map {
                SummonItem(id: "app:\($0.id)", name: $0.name, detail: $0.id,
                           mark: $0.color, kind: .app($0.id))
            }))
        }
        groups.append(SummonGroup(id: "commands", title: "Commands", items: commands(for: state)))
        return groups
    }

    private static func item(for window: WindowEntry, in state: ShellState) -> SummonItem {
        let app = state.apps.first { $0.id == window.appID }
        let place = switch window.place {
        case .principal: "in the large cell"
        case .widget: "in a tile"
        case .rail: "waiting for a cell"
        }
        return SummonItem(id: "window:\(window.id)", name: app?.name ?? window.appID,
                          detail: window.title.isEmpty ? place : "\(window.title) — \(place)",
                          tag: "WINDOW", mark: app?.color ?? Palette.dimText,
                          kind: .window(window.id))
    }

    private static func commands(for state: ShellState) -> [SummonItem] {
        var items: [SummonItem] = []
        if !state.windows.isEmpty {
            items.append(SummonItem(id: "command:close", name: "Close the window in front",
                                    detail: "The app decides what it does with that",
                                    kind: .command(.closeFrontWindow)))
        }
        for kind in WindowLayoutKind.allCases where kind != state.layout {
            items.append(SummonItem(id: "command:layout:\(kind.rawValue)",
                                    name: "Layout: \(kind.name.lowercased())",
                                    detail: "Super \(kind.key)",
                                    kind: .command(.layout(kind))))
        }
        return items
    }
}

/// The surface itself. It draws over the canvas, and the canvas is dimmed
/// under it, so that nothing behind it asks to be read.
public struct SummonView: View {
    let state: ShellState
    let actions: ShellActions
    /// What a person typed. It belongs to this view: it starts again every
    /// time Summon opens, because the view leaves the tree when it closes.
    @State private var query = ""
    /// Which line Enter takes.
    @State private var selection = 0
    /// How far Summon has arrived, from 0 to 1. It starts at 0 and the body
    /// gives it 1, so the surface comes in rather than appearing at once.
    @Animated(.surface) private var appeared = 0.0

    public init(state: ShellState, actions: ShellActions = ShellActions()) {
        self.state = state
        self.actions = actions
    }

    private var groups: [SummonGroup] { SummonList.groups(for: state, query: query) }

    private var count: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    private var chosen: SummonItem? {
        SummonList.selected(in: state, query: query, at: selection)
    }

    public var body: some View {
        // The first frame gives the move somewhere to go. Every frame after
        // it names the same target, which starts nothing.
        appeared = 1
        return VStack(spacing: 0) {
            surface
                .frame(width: SummonMetrics.width)
                .padding(.top, SummonMetrics.topMargin)
                // It comes down a little as it arrives.
                .offset(y: (appeared - 1) * 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0, alpha: Appearance(state.mode).dim * appeared))
        // Summon is the surface in front, so it reads every key. Nothing
        // under it may read the keyboard while it is open.
        .onKey { key in
            guard key.isPressed else { return true }
            switch key.named {
            case .escape:
                actions.toggleSummon()
            case .enter:
                if let chosen { choose(chosen) }
                actions.toggleSummon()
            case .tab, .down:
                move(by: 1)
            case .up:
                move(by: -1)
            case .backspace:
                if !query.isEmpty {
                    query.removeLast()
                    selection = 0
                }
            default:
                guard !key.characters.isEmpty, !key.control, !key.alt else { return true }
                query += key.characters
                selection = 0
            }
            return true
        }
    }

    /// Moves the line that Enter takes, and goes round at the ends.
    private func move(by step: Int) {
        let count = SummonList.items(for: state, query: query).count
        guard count > 0 else { return }
        selection = (selection + step + count) % count
    }

    /// Does what a line says.
    private func choose(_ item: SummonItem) {
        switch item.kind {
        case .window(let id): actions.raiseWindow(id)
        case .app(let id): actions.openApp(id)
        case .command(.closeFrontWindow): actions.closeFrontWindow()
        case .command(.layout(let kind)): actions.setLayout(kind)
        }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            queryLine
            Divider(thickness: 1).foregroundColor(Palette.divider)
            list
            Divider(thickness: 1).foregroundColor(Palette.divider)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: SummonMetrics.radius)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SummonMetrics.radius)
                .stroke(Palette.divider, lineWidth: Appearance(state.mode).surfaceLine)
        )
    }

    /// The line where the query is shown, with a caret after it.
    private var queryLine: some View {
        HStack(spacing: 10) {
            Circle()
                .stroke(Palette.dimText, lineWidth: 1.5)
                .frame(width: 12, height: 12)
            if query.isEmpty {
                Text("Type to narrow the list")
                    .font(Font(size: 14))
                    .foregroundColor(Palette.dimText)
            } else {
                Text(query)
                    .font(Font(size: 14))
                    .foregroundColor(Palette.text)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.accent)
                .frame(width: 2, height: 18)
            Spacer()
            Text("\(count) items")
                .font(Font(size: 11))
                .foregroundColor(Palette.faintText)
        }
        .padding(.horizontal, 16)
        .frame(height: SummonMetrics.queryHeight)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text("No item matches \(query)")
                    .font(Font(size: 13))
                    .foregroundColor(Palette.dimText)
                    .padding(.horizontal, 16)
                    .frame(height: SummonMetrics.rowHeight * 2)
            }
            ForEach(groups) { group in
                GroupHeader(title: group.title)
                ForEach(group.items) { item in
                    SummonRow(item: item, actions: actions,
                              isSelected: item.id == chosen?.id)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            hint("Enter", "put it in front")
            hint("Tab", "next")
            hint("Esc", "cancel")
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: SummonMetrics.footerHeight)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Palette.dimText)
            Text(what)
                .font(Font(size: 10))
                .foregroundColor(Palette.faintText)
        }
    }
}

/// The name of a group, over its lines.
struct GroupHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(Font(size: 10, weight: .bold))
            .foregroundColor(Palette.faintText)
            .padding(.horizontal, 16)
            .frame(height: SummonMetrics.groupHeader, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line. The pointer chooses it; the keyboard will choose it later.
struct SummonRow: View {
    let item: SummonItem
    let actions: ShellActions
    var isSelected = false
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(item.mark)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(Font(size: 13))
                        .foregroundColor(Palette.text)
                    Text(item.detail)
                        .font(Font(size: 11))
                        .foregroundColor(Palette.dimText)
                }
                Spacer()
                if !item.tag.isEmpty {
                    Text(item.tag)
                        .font(Font(size: 9, weight: .bold))
                        .foregroundColor(Palette.faintText)
                }
                if isSelected {
                    Text("Enter")
                        .font(Font(size: 10, weight: .bold))
                        .foregroundColor(Palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: SummonMetrics.rowHeight)
            .frame(maxWidth: .infinity)
            .background(background)
            .onHover { isHovered = $0 }
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Palette.accentSurface
                             : (isHovered ? Palette.control : Color.clear))
            .padding(.horizontal, 6)
    }

    private func choose() {
        switch item.kind {
        case .window(let id):
            actions.raiseWindow(id)
        case .app(let id):
            actions.openApp(id)
        case .command(.closeFrontWindow):
            actions.closeFrontWindow()
        case .command(.layout(let kind)):
            actions.setLayout(kind)
        }
        actions.toggleSummon()
    }
}
