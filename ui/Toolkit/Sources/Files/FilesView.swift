import Toolkit

// The window of Files: the places on the left, and the folder that is open,
// as a list of its names, kinds and sizes.
//
// A window with room has the sidebar. A narrow one drops it, since the bar
// over the list goes to every folder above this one anyway. A tile is 256
// points across and draws something else (FilesTile).

/// The whole window.
public struct FilesView: View {
    let store: FilesStore
    let sizeClass: SizeClass
    /// The height of the window, in points. A long folder draws only the
    /// rows that can show in it.
    let height: Double

    public init(store: FilesStore, sizeClass: SizeClass, height: Double) {
        self.store = store
        self.sizeClass = sizeClass
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 0) {
            if sizeClass == .large {
                PlacesSidebar(store: store)
                    .frame(width: Metrics.sidebarWidth)
            }
            FolderView(store: store, isCompact: sizeClass != .large, height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
        .onKey { store.key($0) }
    }
}

/// The folders that a person goes to often.
struct PlacesSidebar: View {
    let store: FilesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Ink.mark)
                    .frame(width: 8, height: 8)
                Text("Files")
                    .font(Font(size: 13, weight: .bold))
                    .foregroundColor(Ink.text)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: Metrics.head)
            Text("PLACES")
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.faintText)
                .padding(.horizontal, 20)
                .frame(height: 30, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(store.places, id: \.path) { place in
                PlaceRow(place: place, isSelected: place.path == store.path) {
                    store.open(place.path)
                }
            }
            Spacer()
            HStack(spacing: 14) {
                hint("Enter", "open")
                hint("Back", "up")
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
        }
        .frame(maxHeight: .infinity)
        .background(Ink.sidebar)
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

struct PlaceRow: View {
    let place: Place
    let isSelected: Bool
    let action: () -> Void
    @State private var glow = 0.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(place.mark)
                    .frame(width: 8, height: 8)
                Text(place.title)
                    .font(Font(size: 13, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Ink.text : Ink.secondaryText)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Ink.card : Ink.card.opacity(glow * 0.7))
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .onHover { hovering in withAnimation(Moves.quick) { glow = hovering ? 1 : 0 } }
        }
    }
}

/// The folder that is open: the way to it, the list, and a line about it.
struct FolderView: View {
    let store: FilesStore
    let isCompact: Bool
    let height: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PathBar(store: store)
                .padding(.horizontal, isCompact ? 12 : 20)
                .frame(height: Metrics.head)
            if let notice = store.notice {
                NoticeLine(text: notice, isFailure: store.failed)
                    .padding(.horizontal, isCompact ? 12 : 20)
                    .padding(.bottom, 10)
            }
            ColumnHeads(isCompact: isCompact)
                .padding(.horizontal, isCompact ? 12 : 20)
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
                .padding(.horizontal, isCompact ? 12 : 20)
            list
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
            HStack(spacing: 8) {
                Text(store.summary)
                    .font(Font(size: 11))
                    .foregroundColor(Ink.dimText)
                Spacer()
                if let selected = store.selected {
                    Text(selected.name)
                        .font(Font(size: 11))
                        .foregroundColor(Ink.faintText)
                }
            }
            .padding(.horizontal, isCompact ? 12 : 20)
            .frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var list: some View {
        if store.entries.isEmpty {
            VStack(spacing: 0) {
                Text(emptyText)
                    .font(Font(size: 13))
                    .foregroundColor(Ink.dimText)
                    .padding(.top, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(offset: store.offsetBinding, reveal: store.reveal()) {
                VisibleRows(count: store.entries.count, offset: store.offset,
                            viewport: height) { index in
                    EntryRow(entry: store.entries[index], isSelected: index == store.selection,
                             isCompact: isCompact) {
                        store.click(index)
                    }
                }
                .padding(.horizontal, isCompact ? 4 : 12)
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyText: String {
        if store.failed { return "This folder cannot be read" }
        if !store.all.isEmpty { return "Only hidden files. Press . to show them." }
        return "This folder is empty"
    }
}

/// The way to the folder: a button for each folder above it, and Up.
struct PathBar: View {
    let store: FilesStore

    var body: some View {
        let trail = store.trail
        return HStack(spacing: 4) {
            SmallButton(title: "↑", isEnabled: store.path != "/") { store.goUp() }
                .padding(.trailing, 8)
            ForEach(Array(trail.enumerated()), id: \.offset) { step in
                if step.offset > 0 {
                    Text("›")
                        .font(Font(size: 13))
                        .foregroundColor(Ink.faintText)
                }
                TrailButton(title: step.element.title,
                            isLast: step.offset == trail.count - 1) {
                    store.open(step.element.path)
                }
            }
            Spacer(minLength: 8)
            SmallButton(title: store.showsHidden ? "Hide hidden" : "Show hidden",
                        isEnabled: true) { store.toggleHidden() }
        }
    }
}

/// One folder of the way to this one.
struct TrailButton: View {
    let title: String
    let isLast: Bool
    let action: () -> Void
    @State private var glow = 0.0

    var body: some View {
        Text(title)
            .font(Font(size: isLast ? 15 : 13, weight: isLast ? .bold : .regular))
            .foregroundColor(isLast ? Ink.text : Ink.secondaryText.lightened(by: glow * 0.3))
            .padding(.horizontal, 4)
            .frame(height: 28)
            .onHover { hovering in withAnimation(Moves.quick) { glow = hovering ? 1 : 0 } }
            .onTapGesture(perform: action)
    }
}

/// A button with a short title.
struct SmallButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var glow = 0.0
    @State private var isPressed = false

    var body: some View {
        Text(title)
            .font(Font(size: 12))
            .foregroundColor(isEnabled ? Ink.text : Ink.faintText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(background))
            .onHover { hovering in withAnimation(Moves.quick) { glow = hovering && isEnabled ? 1 : 0 } }
            .onPress { isPressed = $0 && isEnabled }
            .onTapGesture { if isEnabled { action() } }
    }

    private var background: Color {
        let base = isEnabled ? Ink.control : Ink.control.opacity(0.5)
        return isPressed ? base.darkened(by: 0.25) : base.lightened(by: glow * 0.18)
    }
}

/// What came of the last thing a person asked for.
struct NoticeLine: View {
    let text: String
    let isFailure: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(Font(size: 12))
                .foregroundColor(Ink.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.1)))
    }

    private var color: Color { isFailure ? Ink.failure : Ink.secondaryText }
}

/// The names of the columns.
struct ColumnHeads: View {
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 0) {
            head("NAME")
                .padding(.leading, 30)
            Spacer()
            head("KIND")
                .frame(width: isCompact ? Metrics.compactKindWidth : Metrics.kindWidth,
                       alignment: .leading)
            head("SIZE")
                .frame(width: Metrics.sizeWidth, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .frame(height: 26)
    }

    private func head(_ title: String) -> some View {
        Text(title)
            .font(Font(size: 10, weight: .bold))
            .foregroundColor(Ink.faintText)
    }
}

/// One line of the list: a mark, the name, the kind and the size.
struct EntryRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let isCompact: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            EntryMark(kind: entry.kind)
                .frame(width: 16, height: 16)
                .padding(.trailing, 10)
            Text(entry.name)
                .font(Font(size: 13))
                .foregroundColor(entry.isHidden ? Ink.secondaryText : Ink.text)
            Spacer(minLength: 12)
            Text(entry.kindText)
                .font(Font(size: 12))
                .foregroundColor(Ink.dimText)
                .frame(width: isCompact ? Metrics.compactKindWidth : Metrics.kindWidth,
                       alignment: .leading)
            Text(entry.sizeText)
                .font(Font(size: 12))
                .foregroundColor(Ink.secondaryText)
                .frame(width: Metrics.sizeWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.row)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(background)
                .padding(.vertical, 1)
        )
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
    }

    private var background: Color {
        if isSelected { return Ink.accentSurface }
        return isHovered ? Ink.control.opacity(0.6) : .clear
    }
}

/// The mark in front of a name: a folder, a page, or a program.
struct EntryMark: View {
    let kind: FileEntry.Kind

    var body: some View {
        switch kind {
        case .folder:
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Ink.mark)
                    .frame(width: 6, height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Ink.mark)
                    .frame(width: 15, height: 10)
            }
        case .program:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: 0x3BB273))
                .frame(width: 12, height: 12)
        case .special:
            Circle()
                .stroke(Ink.dimText, lineWidth: 1.5)
                .frame(width: 10, height: 10)
        case .brokenLink:
            RoundedRectangle(cornerRadius: 2)
                .stroke(Ink.failure, lineWidth: 1.5)
                .frame(width: 11, height: 14)
        case .file:
            RoundedRectangle(cornerRadius: 2)
                .stroke(Ink.secondaryText, lineWidth: 1.5)
                .frame(width: 11, height: 14)
        }
    }
}

/// The rows of a long list that can show, with room above and below for
/// the others. Every row is `Metrics.row` tall, so the list knows where
/// each one is without laying it out. /usr/bin holds thousands.
struct VisibleRows<Row: View>: View {
    let count: Int
    let offset: Double
    let viewport: Double
    let row: (Int) -> Row

    init(count: Int, offset: Double, viewport: Double, @ViewBuilder row: @escaping (Int) -> Row) {
        self.count = count
        self.offset = offset
        self.viewport = viewport
        self.row = row
    }

    var body: some View {
        // A few rows more at each end, so that a scroll between two frames
        // never shows a gap.
        let first = max(0, min(count, Int(offset / Metrics.row) - 4))
        let last = max(first, min(count, Int((offset + viewport) / Metrics.row) + 4))
        return VStack(spacing: 0) {
            Color.clear.frame(height: Double(first) * Metrics.row)
            ForEach(first..<last) { index in row(index) }
            Color.clear.frame(height: Double(count - last) * Metrics.row)
        }
    }
}
