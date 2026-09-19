import Toolkit

// The panel is the first part of the shell UI. It is a view, so it says what
// it contains and the toolkit lays it out. See RootView.swift.

/// The bar at the top of the screen: the name of the system, the title of the
/// front window, and the time.
public struct Panel: View {
    /// The height of the bar, in pixels. The compositor keeps this space free.
    public static let height: Double = 28

    static let background = Color(hex: 0x1B1626)
    static let nameColor = Color(hex: 0xC8A8F0)
    static let titleColor = Color(white: 0.8)

    let state: ShellState

    public init(state: ShellState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text("mydistro")
                .font(.headline)
                .foregroundColor(Panel.nameColor)
            if let title = state.windowTitles.last, !title.isEmpty {
                Text(title)
                    .font(.body)
                    .foregroundColor(Panel.titleColor)
            }
            Spacer()
            Text(state.clock)
                .font(.body)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Panel.background)
    }
}
