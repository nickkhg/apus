import Render
import Toolkit

// This is the user interface of mydistro: what the system draws itself, over
// the windows of the apps. RootView is the whole screen. The compositor draws
// it for each frame and gives it the state.
//
// Write your UI here. A new part of the interface is a View in this
// directory, and RootView puts it on the screen.

/// What the shell shows. The compositor fills it in for each frame.
public struct ShellState: Equatable, Sendable {
    /// The titles of the open windows, back to front.
    public var windowTitles: [String]
    /// The time, as "14:05".
    public var clock: String

    public init(windowTitles: [String] = [], clock: String = "") {
        self.windowTitles = windowTitles
        self.clock = clock
    }
}

/// The screen: the panel at the top, and the free space under it. The windows
/// of the apps are behind the free space, because the compositor draws them
/// before the shell.
public struct RootView: View {
    let state: ShellState

    public init(state: ShellState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            Panel(state: state)
                .frame(height: Panel.height)
            Spacer()
            DockView()
                .frame(height: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The part of `screen` that the windows of the apps use. The compositor
    /// puts new windows there.
    public static func windowArea(screen: Rect) -> Rect {
        let top = Int(Panel.height)
        return Rect(x: screen.x, y: screen.y + top,
                    width: screen.width, height: max(0, screen.height - top))
    }
}
