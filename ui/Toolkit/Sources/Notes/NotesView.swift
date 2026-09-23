import Toolkit

// The window of Notes: the list of the notes on the left, and the one that
// is open in an editor. A tile is 256 points across and draws something
// else (NotesTile).

/// The whole window.
public struct NotesView: View {
    let store: NotesStore
    let sizeClass: SizeClass

    public init(store: NotesStore, sizeClass: SizeClass) {
        self.store = store
        self.sizeClass = sizeClass
    }

    public var body: some View {
        HStack(spacing: 0) {
            NoteList(store: store)
                .frame(width: sizeClass == .large ? Metrics.listWidth : Metrics.compactListWidth)
            EditorPane(store: store, padding: sizeClass == .large ? 28 : 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
        .onKey { store.key($0) }
    }
}

/// The notes, the newest first.
struct NoteList: View {
    let store: NotesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Ink.mark)
                    .frame(width: 8, height: 8)
                Text("Notes")
                    .font(Font(size: 13, weight: .bold))
                    .foregroundColor(Ink.text)
                Spacer()
                SmallButton(title: "New", style: .primary) { store.newNote() }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: Metrics.head)
            Text("\(store.folder.place) · \(store.notes.count == 1 ? "1 note" : "\(store.notes.count) notes")".uppercased())
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(Ink.faintText)
                .padding(.horizontal, 20)
                .frame(height: 26, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(store.notes.enumerated()), id: \.element.name) { item in
                        NoteRow(note: item.element, isSelected: item.offset == store.selection,
                                hasKeyboard: store.focus == .list,
                                isArmed: store.armed == item.element.name) {
                            store.select(item.offset)
                            store.focus(.list)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
            HStack(spacing: 14) {
                hint("Ctrl+N", "new")
                hint(store.focus == .list ? "Enter" : "Esc", store.focus == .list ? "write" : "list")
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

/// One note of the list: its title, and the line after it.
struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let hasKeyboard: Bool
    let isArmed: Bool
    let action: () -> Void
    @State private var glow = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(Font(size: 13, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? Ink.text : Ink.secondaryText)
            Text(isArmed ? "Press Delete again to remove it" : subtitle)
                .font(Font(size: 11))
                .foregroundColor(isArmed ? Ink.failure : Ink.dimText)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.row, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(background)
        )
        .overlay(
            // The line at the edge says that the keys go to this list.
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected && hasKeyboard ? Ink.accent : Color.clear)
                    .frame(width: 2, height: 20)
                Spacer()
            }
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .onHover { hovering in withAnimation(Moves.quick) { glow = hovering ? 1 : 0 } }
        .onTapGesture(perform: action)
    }

    private var subtitle: String {
        note.excerpt.isEmpty ? note.name : note.excerpt
    }

    private var background: Color {
        if isArmed { return Ink.failureSurface }
        if isSelected { return hasKeyboard ? Ink.accentSurface : Ink.card }
        return Ink.card.opacity(glow * 0.7)
    }
}

/// The note that is open, in the editor.
struct EditorPane: View {
    let store: NotesStore
    let padding: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let open = store.open {
                head(open)
                if let notice = store.notice {
                    NoticeLine(text: notice)
                        .padding(.bottom, 12)
                }
                // One editor for each note, so that each keeps how far it
                // is scrolled.
                ForEach([open], id: \.self) { _ in
                    TextEditor(store.editing, isFocused: store.focus == .editor,
                               font: .monospaced(size: 14), color: Ink.text,
                               caretColor: Ink.accent,
                               selectionColor: Ink.accent.opacity(0.28))
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Ink.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(store.focus == .editor ? Ink.accent.opacity(0.5) : Ink.divider,
                                        lineWidth: 1)
                        )
                        .onTapGesture { store.focus(.editor) }
                }
                HStack(spacing: 8) {
                    Text(store.summary)
                        .font(Font(size: 11))
                        .foregroundColor(Ink.dimText)
                    Spacer()
                    Text(open)
                        .font(Font(size: 11))
                        .foregroundColor(Ink.faintText)
                }
                .frame(height: 36)
            } else {
                empty
            }
        }
        .padding(.horizontal, padding)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func head(_ open: String) -> some View {
        HStack(spacing: 12) {
            Text(store.selected?.title ?? open)
                .font(Font(size: 20, weight: .bold))
                .foregroundColor(Ink.text)
            Spacer(minLength: 8)
            if store.isUnsaved {
                Text("NOT SAVED")
                    .font(Font(size: 9, weight: .bold))
                    .foregroundColor(Ink.failure)
            } else {
                Text("SAVED")
                    .font(Font(size: 9, weight: .bold))
                    .foregroundColor(Ink.dimText)
            }
            SmallButton(title: store.armed == open ? "Delete, really" : "Delete",
                        style: .danger) { store.delete() }
        }
        .frame(height: Metrics.head)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = store.notice {
                NoticeLine(text: notice)
                    .padding(.top, 20)
            }
            Text("No notes yet")
                .font(Font(size: 20, weight: .bold))
                .foregroundColor(Ink.text)
                .padding(.top, 40)
            Text("Press Control+N, or New, to write one. It is saved in \(store.folder.place) as you type.")
                .font(Font(size: 13))
                .foregroundColor(Ink.dimText)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A button with a short title.
struct SmallButton: View {
    enum Style { case normal, primary, danger }
    let title: String
    var style = Style.normal
    let action: () -> Void
    @State private var glow = 0.0
    @State private var isPressed = false

    var body: some View {
        Text(title)
            .font(Font(size: 12, weight: style == .normal ? .regular : .bold))
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(background))
            .onHover { hovering in withAnimation(Moves.quick) { glow = hovering ? 1 : 0 } }
            .onPress { isPressed = $0 }
            .onTapGesture(perform: action)
    }

    private var foreground: Color {
        switch style {
        case .normal: Ink.text
        case .primary: Ink.accent
        case .danger: Ink.failure
        }
    }

    private var background: Color {
        let base: Color = switch style {
        case .normal: Ink.control
        case .primary: Ink.accentSurface
        case .danger: Ink.failureSurface
        }
        return isPressed ? base.darkened(by: 0.25) : base.lightened(by: glow * 0.18)
    }
}

/// A failure, in words, over the editor.
struct NoticeLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Ink.failure)
                .frame(width: 8, height: 8)
            Text(text)
                .font(Font(size: 12))
                .foregroundColor(Ink.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(Ink.failure.opacity(0.1)))
    }
}
