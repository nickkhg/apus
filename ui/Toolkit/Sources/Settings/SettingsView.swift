import Toolkit

// The window of Settings: the panes on the left, and the one that is open.
//
// A window with room has the whole sidebar. A narrow one keeps it and gives
// the pane less padding. A tile is 256 points across and draws something
// else entirely (SettingsTile), because a tile is not a window made smaller.

/// The whole window.
public struct SettingsView: View {
    let store: SettingsStore
    let sizeClass: SizeClass
    /// The height of the window, in points. A long list draws only the
    /// rows that can show in it.
    let height: Double

    public init(store: SettingsStore, sizeClass: SizeClass, height: Double) {
        self.store = store
        self.sizeClass = sizeClass
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(store: store)
                .frame(width: sizeClass == .large ? Metrics.sidebarWidth
                                                  : Metrics.compactSidebarWidth)
            PaneView(store: store,
                     padding: sizeClass == .large ? Metrics.panePadding
                                                  : Metrics.compactPanePadding,
                     height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
        .onKey { store.key($0) }
    }
}

/// The list of the panes, in their groups.
struct Sidebar: View {
    let store: SettingsStore

    private static let groups: [(title: String, panes: [Pane])] = {
        var result: [(title: String, panes: [Pane])] = []
        for pane in Pane.allCases where !pane.group.isEmpty {
            if result.last?.title == pane.group {
                result[result.count - 1].panes.append(pane)
            } else {
                result.append((pane.group, [pane]))
            }
        }
        return result
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            ForEach(Sidebar.groups, id: \.title) { group in
                Text(group.title.uppercased())
                    .font(Font(size: 10, weight: .bold))
                    .foregroundColor(Ink.faintText)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .frame(height: 34, alignment: .bottomLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(group.panes, id: \.self) { pane in row(pane) }
            }
            Spacer()
            ForEach(Pane.allCases.filter { $0.group.isEmpty }, id: \.self) { pane in row(pane) }
            hints
        }
        .frame(maxHeight: .infinity)
        .background(Ink.sidebar)
    }

    private var head: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Ink.mark)
                .frame(width: 8, height: 8)
            Text("Settings")
                .font(Font(size: 13, weight: .bold))
                .foregroundColor(Ink.text)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private func row(_ pane: Pane) -> SidebarRow {
        SidebarRow(pane: pane, isSelected: store.pane == pane,
                   hasKeyboard: store.focus == .sidebar, badge: badge(for: pane)) {
            store.select(pane)
            store.focus(.sidebar)
        }
    }

    /// A dot that says a pane wants a look: root with no password, or a
    /// change that is not saved.
    private func badge(for pane: Pane) -> Color? {
        switch pane {
        case .password where store.snapshot.password == .none: Ink.warning
        case .display where store.displayIsChanged: Ink.accent
        case .keyboard where store.keyboardIsChanged: Ink.accent
        default: nil
        }
    }

    /// The keys, at the foot of the sidebar, as Summon names them.
    private var hints: some View {
        HStack(spacing: 14) {
            hint("↑↓", "move")
            hint(store.focus == .sidebar ? "Enter" : "Esc",
                 store.focus == .sidebar ? "open" : "back")
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.dimText)
            Text(what)
                .font(Font(size: 10))
                .foregroundColor(Ink.faintText)
        }
    }
}

/// One line of the sidebar.
struct SidebarRow: View {
    let pane: Pane
    let isSelected: Bool
    let hasKeyboard: Bool
    let badge: Color?
    let action: () -> Void
    @State private var glow = 0.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(pane.mark)
                    .frame(width: 8, height: 8)
                Text(pane.title)
                    .font(Font(size: 13, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Ink.text : Ink.secondaryText)
                Spacer(minLength: 4)
                if let badge {
                    Circle()
                        .fill(badge)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Metrics.sidebarRow)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(background)
            )
            .overlay(
                // The line at the edge says that the keys go to this list.
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected && hasKeyboard ? Ink.accent : Color.clear)
                        .frame(width: 2, height: 16)
                    Spacer()
                }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .onHover { hovering in withAnimation(Moves.quick) { glow = hovering ? 1 : 0 } }
        }
    }

    private var background: Color {
        if isSelected { return hasKeyboard ? Ink.accentSurface : Ink.card }
        return Ink.card.opacity(glow * 0.7)
    }
}

/// The pane that is open: its title, what came of the last change, and
/// what it holds.
struct PaneView: View {
    let store: SettingsStore
    let padding: Double
    let height: Double

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                // A click on nothing takes the keys from a field, and gives
                // them to the pane.
                Ink.background.onTapGesture {
                    store.endEditing()
                    store.focus(.pane)
                }
            )
    }

    /// A pane with a list keeps its head and gives the rest to the list,
    /// which scrolls. Every other pane scrolls as a whole.
    @ViewBuilder
    private var content: some View {
        switch store.pane {
        case .time:
            framed { TimePane(store: store, height: height) }
        case .keyboard:
            framed { KeyboardPane(store: store, height: height) }
        case .apps:
            framed { AppsPane(store: store, height: height) }
        default:
            ScrollView(offset: store.offset(store.pane)) {
                VStack(alignment: .leading, spacing: 0) {
                    head
                    scrolling
                }
                .padding(padding)
            }
        }
    }

    private func framed(@ViewBuilder _ pane: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            pane()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var scrolling: some View {
        switch store.pane {
        case .about: AboutPane(store: store)
        case .password: PasswordPane(store: store)
        case .display: DisplayPane(store: store)
        case .network: NetworkPane(store: store)
        case .sound: SoundPane(store: store)
        case .power: PowerPane(store: store)
        case .time, .keyboard, .apps: EmptyView()
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.pane.title)
                .font(Font(size: 22, weight: .bold))
                .foregroundColor(Ink.text)
            Text(store.pane.subtitle)
                .font(Font(size: 13))
                .foregroundColor(Ink.dimText)
                .padding(.top, 4)
            if let notice = store.notice(for: store.pane) {
                NoticeBar(notice: notice) { store.perform($0, from: store.pane) }
                    .padding(.top, 16)
            }
        }
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
