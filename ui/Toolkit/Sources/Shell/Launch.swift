import Render
import Toolkit

// A launch: an app between the moment a person chose it and the moment its
// window appears.
//
// A launch holds a cell from the start. A person who chose an app sees it
// appear at once, in the place where its window will be, instead of looking
// at an unchanged screen and wondering whether the key worked. An app that
// never opens a window leaves its reason in that cell, which is where a
// person is already looking.

/// An app that is starting, or one that failed to start.
public struct Launch: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The program is running and no window has come yet.
        case starting
        /// The program stopped, or it never opened a window.
        case failed(String)
    }

    public let id: String
    public let appName: String
    public let mark: Color
    /// The program that the bundle names.
    public let command: String
    public let state: State
    /// Where the cell is, in points on the screen.
    public let frame: Rect

    public init(id: String, appName: String, mark: Color, command: String,
                state: State, frame: Rect) {
        self.id = id
        self.appName = appName
        self.mark = mark
        self.command = command
        self.state = state
        self.frame = frame
    }

    var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var reason: String {
        if case .failed(let reason) = state { return reason }
        return ""
    }
}

/// The cell of an app that is starting, or of one that did not start.
public struct LaunchCard: View {
    let launch: Launch
    let actions: ShellActions

    public init(launch: Launch, actions: ShellActions = ShellActions()) {
        self.launch = launch
        self.actions = actions
    }

    private var accent: Color {
        launch.hasFailed ? Palette.error : Palette.dimText
    }

    public var body: some View {
        VStack(spacing: 0) {
            head
            Spacer()
            middle
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cellRadius)
                .fill(Palette.slot)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cellRadius)
                .stroke(accent.opacity(launch.hasFailed ? 1 : 0.4), lineWidth: 1)
        )
        .clipped()
    }

    /// The head of the cell, in the colour of the state.
    private var head: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(launch.hasFailed ? Palette.error : launch.mark)
                .frame(width: 8, height: 8)
            Text(launch.appName)
                .font(Font(size: 13, weight: .bold))
                .foregroundColor(Palette.text)
            Spacer()
            Text(launch.hasFailed ? "DID NOT START" : "STARTING")
                .font(Font(size: 9, weight: .bold))
                .foregroundColor(accent)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.headHeight)
        .frame(maxWidth: .infinity)
        .background(launch.hasFailed ? Palette.error.opacity(0.12) : Palette.surface)
    }

    /// What the cell says in the middle of itself.
    private var middle: some View {
        VStack(spacing: 0) {
            Text(launch.hasFailed
                ? "\(launch.appName) did not start"
                : "Starting \(launch.appName)")
                .font(Font(size: 15, weight: .bold))
                .foregroundColor(Palette.text)
            if launch.hasFailed {
                Text(launch.reason)
                    .font(Font(size: 12))
                    .foregroundColor(Palette.secondaryText)
                    .padding(.top, 8)
                Text(launch.command)
                    .font(.monospaced(size: 11))
                    .foregroundColor(Palette.dimText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Palette.control)
                    )
                    .padding(.top, 12)
                HStack(spacing: 8) {
                    CardButton(name: "Try again", accent: true) {
                        actions.retryLaunch(launch.id)
                    }
                    CardButton(name: "Close", accent: false) {
                        actions.dismissLaunch(launch.id)
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// One control of a card.
struct CardButton: View {
    let name: String
    let accent: Bool
    let action: () -> Void
    @Animated(.quick) private var glow = 0.0

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(Font(size: 11, weight: .bold))
                .foregroundColor(accent ? Palette.text : Palette.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(background)
                )
                .onHover { glow = $0 ? 1 : 0 }
        }
    }

    private var background: Color {
        let base = accent ? Palette.error.opacity(0.8) : Palette.control
        return base.lightened(by: glow * 0.25)
    }
}
