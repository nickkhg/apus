import Toolkit

// The dock at the bottom of the screen. It shows what the new parts of the
// toolkit do: a shape with round corners, one view for each element of a
// list, a value that the view owns, and the pointer.

/// One place in the dock.
public struct DockItem: Identifiable, Equatable, Sendable {
    /// The name. Its first letter is in the icon, and it is the identity.
    public let name: String
    public let color: Color

    public var id: String { name }

    public init(name: String, color: Color) {
        self.name = name
        self.color = color
    }
}

/// The row of icons at the bottom of the screen.
public struct DockView: View {
    /// The places in the dock. There are no apps to start yet.
    public static let items = [
        DockItem(name: "Files", color: Color(hex: 0x4C8DF6)),
        DockItem(name: "Terminal", color: Color(hex: 0x3BB273)),
        DockItem(name: "Settings", color: Color(hex: 0xE0A458)),
    ]

    let items: [DockItem]

    public init(items: [DockItem] = DockView.items) {
        self.items = items
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                DockIcon(item: item)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: 0x1B1626).opacity(0.85))
        )
    }
}

/// One icon. It becomes brighter when the pointer is over it.
struct DockIcon: View {
    let item: DockItem
    @State private var isHovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? item.color : item.color.opacity(0.7))
            Text(String(item.name.prefix(1)))
                .font(.headline)
                .foregroundColor(.white)
        }
        .frame(width: 44, height: 44)
        .aspectRatio(1, contentMode: .fit)
        .onHover { isHovered = $0 }
    }
}
