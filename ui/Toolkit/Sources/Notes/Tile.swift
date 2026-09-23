import Toolkit

// Notes in a tile of 256 points: the note that is open, as far as it fits.
// A tile is read from the corner of an eye, so it is a note to glance at,
// such as a list for the day.

public struct NotesTile: View {
    let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Ink.mark)
                    .frame(width: 8, height: 8)
                Text("Notes")
                    .font(Font(size: 13, weight: .bold))
                    .foregroundColor(Ink.text)
                Spacer()
                Text(store.notes.count == 1 ? "1 NOTE" : "\(store.notes.count) NOTES")
                    .font(Font(size: 10, weight: .bold))
                    .foregroundColor(Ink.dimText)
            }
            if store.open != nil {
                Text(store.selected?.title ?? "")
                    .font(Font(size: 17, weight: .bold))
                    .foregroundColor(Ink.text)
                    .padding(.top, 16)
                Divider(thickness: 1)
                    .foregroundColor(Ink.divider)
                    .padding(.top, 10)
                ForEach(Array(lines.enumerated()), id: \.offset) { line in
                    Text(line.element)
                        .font(Font(size: 12))
                        .foregroundColor(Ink.secondaryText)
                        .padding(.top, 7)
                }
            } else {
                Text("No notes yet")
                    .font(Font(size: 17, weight: .bold))
                    .foregroundColor(Ink.dimText)
                    .padding(.top, 16)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
    }

    /// The lines of the note after its title, as many as a tile holds.
    private var lines: [String] {
        let all = store.editing.text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingSpaces }
            .filter { !$0.isEmpty }
        return Array(all.dropFirst().prefix(7))
    }
}
