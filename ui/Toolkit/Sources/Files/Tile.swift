import Toolkit

// Files in a tile of 256 points. A tile is read from the corner of an eye,
// so it holds the folder that is open, how much is in it, and the first few
// names.

public struct FilesTile: View {
    let store: FilesStore

    public init(store: FilesStore) {
        self.store = store
    }

    public var body: some View {
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
            Text(store.trail.last?.title ?? "/")
                .font(Font(size: 24, weight: .bold))
                .foregroundColor(Ink.text)
                .padding(.top, 14)
            Text(store.failed ? "CANNOT BE READ" : store.summary.uppercased())
                .font(Font(size: 10, weight: .bold))
                .foregroundColor(store.failed ? Ink.failure : Ink.dimText)
                .padding(.top, 4)
            Divider(thickness: 1)
                .foregroundColor(Ink.divider)
                .padding(.top, 14)
            ForEach(Array(store.entries.prefix(5).enumerated()), id: \.offset) { item in
                HStack(spacing: 8) {
                    EntryMark(kind: item.element.kind)
                        .frame(width: 16, height: 16)
                    Text(item.element.name)
                        .font(Font(size: 12))
                        .foregroundColor(Ink.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .clipped()
    }
}
