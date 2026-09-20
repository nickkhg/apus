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
    let actions: ShellActions
    /// The name of the item that the pointer selected, if there is one.
    @State private var active: String?

    public init(items: [DockItem] = DockView.items, actions: ShellActions = ShellActions()) {
        self.items = items
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                DockIcon(item: item, active: $active, actions: actions)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(hex: 0x1B1626).opacity(0.85))
        )
    }
}

/// One icon. It becomes brighter when the pointer is over it, darker while
/// the pointer is down on it, and a dot under it says that it is active.
struct DockIcon: View {
    let item: DockItem
    @Binding var active: String?
    let actions: ShellActions

    @State private var isHovered = false
    @State private var isPressed = false

    private var isActive: Bool { active == item.name }

    /// A click selects the item, and the desktop takes its colour. A click
    /// on the item that is already active clears both.
    private func activate() {
        let wasActive = isActive
        active = wasActive ? nil : item.name
        actions.setDesktopColor(wasActive ? nil : item.color.darkened(by: 0.72))
    }

    var body: some View {
        Button(action: activate) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color)
                    Text(String(item.name.prefix(1)))
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .frame(width: 44, height: 44)
                .aspectRatio(1, contentMode: .fit)
                Circle()
                    .fill(isActive ? Color.white : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .onHover { isHovered = $0 }
            .onPress { isPressed = $0 }
        }
    }

    private var color: Color {
        if isPressed {
            item.color.opacity(0.5)
        } else if isHovered {
            item.color
        } else {
            item.color.opacity(0.7)
        }
    }
}
