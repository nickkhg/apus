import Toolkit

// The dock at the bottom of the screen. It shows one icon for each app
// bundle in /Applications. A click on an icon starts the app, and the app
// gets the area between the panel and the dock.

/// The row of icons at the bottom of the screen.
public struct DockView: View {
    /// The sizes of the dock, in pixels. RootView keeps `height` plus
    /// `bottomMargin` free at the bottom of the screen, so that no window
    /// goes under the dock.
    static let iconSize: Double = 44
    static let dotSize: Double = 5
    static let dotSpacing: Double = 4
    static let padding: Double = 10
    /// The height of the dock: the padding, an icon, and the dot under it.
    public static let height = 2 * padding + iconSize + dotSpacing + dotSize
    /// The space between the dock and the bottom of the screen.
    public static let bottomMargin: Double = 16

    let apps: [AppEntry]
    let running: Set<String>
    let actions: ShellActions

    public init(apps: [AppEntry], running: Set<String> = [],
                actions: ShellActions = ShellActions()) {
        self.apps = apps
        self.running = running
        self.actions = actions
    }

    public var body: some View {
        if !apps.isEmpty {
            HStack(spacing: 10) {
                ForEach(apps) { app in
                    DockIcon(app: app, isRunning: running.contains(app.id), actions: actions)
                }
            }
            .padding(DockView.padding)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(hex: 0x1B1626).opacity(0.85))
            )
        }
    }
}

/// One icon. It becomes brighter when the pointer is over it, darker while
/// the pointer is down on it, and a dot under it says that the app is open.
struct DockIcon: View {
    let app: AppEntry
    let isRunning: Bool
    let actions: ShellActions

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: { actions.openApp(app.id) }) {
            VStack(spacing: DockView.dotSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color)
                    Text(String(app.name.prefix(1)))
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .frame(width: DockView.iconSize, height: DockView.iconSize)
                .aspectRatio(1, contentMode: .fit)
                Circle()
                    .fill(isRunning ? Color.white : Color.clear)
                    .frame(width: DockView.dotSize, height: DockView.dotSize)
            }
            .onHover { isHovered = $0 }
            .onPress { isPressed = $0 }
        }
    }

    private var color: Color {
        if isPressed {
            app.color.opacity(0.5)
        } else if isHovered {
            app.color
        } else {
            app.color.opacity(0.7)
        }
    }
}
