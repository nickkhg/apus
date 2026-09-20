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
    /// The apps in /Applications, in the order that the dock shows them.
    public var apps: [AppEntry]
    /// The ids of the apps that have a window now. The dock puts a dot under
    /// each of them.
    public var runningApps: Set<String>
    /// The titles of the open windows, back to front.
    public var windowTitles: [String]
    /// The time, as "14:05".
    public var clock: String

    public init(apps: [AppEntry] = [], runningApps: Set<String> = [],
                windowTitles: [String] = [], clock: String = "") {
        self.apps = apps
        self.runningApps = runningApps
        self.windowTitles = windowTitles
        self.clock = clock
    }
}

/// What the shell can ask the compositor to do. The compositor fills these
/// in, because the shell knows nothing about windows, processes or Wayland.
public struct ShellActions {
    /// Starts the app with this id, or brings its window to the front if the
    /// app is open already.
    public var openApp: (String) -> Void
    /// Asks the front window to close (xdg_toplevel.close). The app decides
    /// what it does with that.
    public var closeFrontWindow: () -> Void

    public init(openApp: @escaping (String) -> Void = { _ in },
                closeFrontWindow: @escaping () -> Void = {}) {
        self.openApp = openApp
        self.closeFrontWindow = closeFrontWindow
    }
}

/// The screen: the panel at the top, the dock at the bottom, and the app area
/// between them. The window of an app fills the app area, behind the shell,
/// because the compositor draws the windows before the shell.
public struct RootView: View {
    /// The space between the app area and the dock.
    static let gap: Double = 8

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
            Spacer()            // the app area: the windows are behind it
            DockView(apps: state.apps, running: state.runningApps, actions: actions)
                .padding(.bottom, DockView.bottomMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The app area of `screen`: the space between the panel and the dock.
    /// The compositor gives it to the window of an app, and it keeps the
    /// space free even when the dock has no icon in it.
    public static func windowArea(screen: Rect) -> Rect {
        let top = Int(Panel.height)
        let bottom = Int((DockView.height + DockView.bottomMargin + gap).rounded(.up))
        return Rect(x: screen.x, y: screen.y + top,
                    width: screen.width, height: max(0, screen.height - top - bottom))
    }
}
