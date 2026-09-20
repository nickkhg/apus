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

/// What the shell can ask the compositor to do. The compositor fills these
/// in, because the shell knows nothing about windows or Wayland.
public struct ShellActions {
    /// Asks the front window to close (xdg_toplevel.close). The app decides
    /// what it does with that.
    public var closeFrontWindow: () -> Void
    /// Sets the colour of the desktop behind the windows. A dock item does
    /// this when the pointer clicks it.
    public var setDesktopColor: (Color?) -> Void

    public init(closeFrontWindow: @escaping () -> Void = {},
                setDesktopColor: @escaping (Color?) -> Void = { _ in }) {
        self.closeFrontWindow = closeFrontWindow
        self.setDesktopColor = setDesktopColor
    }
}

/// The screen: the panel at the top, the dock at the bottom, and the free
/// space between them. The windows of the apps are behind the free space,
/// because the compositor draws them before the shell.
public struct RootView: View {
    let state: ShellState
    let actions: ShellActions

    public init(state: ShellState, actions: ShellActions = ShellActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            Panel(state: state, actions: actions)
                .frame(height: Panel.height)
            Spacer()            // the windows are behind this space
            DockView(actions: actions)
                .padding(.bottom, 16)
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
