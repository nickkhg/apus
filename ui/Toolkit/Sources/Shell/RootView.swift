import Render
import Toolkit

// This is the user interface of mydistro: what the system draws itself, over
// the windows of the apps. RootView is the whole screen. The compositor draws
// it for each frame and gives it the state.
//
// The rail on the left edge is the only chrome that is always there. The rest
// of the screen is the canvas, and a layout owns every point of it: a window
// never floats and never covers another window.

/// What the shell shows. The compositor fills it in for each frame.
public struct ShellState: Equatable, Sendable {
    /// The apps in /Applications.
    public var apps: [AppEntry]
    /// The open windows, in the order that the canvas shows them.
    public var windows: [WindowEntry]
    /// The layout that owns the canvas.
    public var layout: WindowLayoutKind
    /// The time, as the rail stacks it.
    public var clock: Clock
    /// How the shell draws depth. The compositor picks it from the hardware.
    public var mode: RenderMode
    /// Summon is over the canvas.
    public var summonIsOpen: Bool
    /// The windows that wait for a cell, and the cells that the band holds
    /// for them.
    public var standIns: [StandIn]
    /// The bar over each window that has room for one.
    public var heads: [WindowHead]
    /// The messages that wait to be read.
    public var notices: [Notice]
    /// The part of the screen that the layout owns, in points. The shell
    /// puts a notice and the empty message inside it.
    public var canvas: Rect

    public init(apps: [AppEntry] = [], windows: [WindowEntry] = [],
                layout: WindowLayoutKind = .principal, clock: Clock = Clock(),
                mode: RenderMode = .cpu, summonIsOpen: Bool = false,
                standIns: [StandIn] = [], heads: [WindowHead] = [],
                notices: [Notice] = [], canvas: Rect = Rect(x: 0, y: 0, width: 0, height: 0)) {
        self.apps = apps
        self.windows = windows
        self.layout = layout
        self.clock = clock
        self.mode = mode
        self.summonIsOpen = summonIsOpen
        self.standIns = standIns
        self.heads = heads
        self.notices = notices
        self.canvas = canvas
    }

    /// The ids of the apps that have a window now.
    public var runningApps: Set<String> {
        Set(windows.map(\.appID))
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
    /// Brings a window to the front, which makes it the principal.
    public var raiseWindow: (String) -> Void
    /// Opens Summon, or closes it when it is open.
    public var toggleSummon: () -> Void
    /// Moves to the next layout.
    public var nextLayout: () -> Void
    /// Gives the canvas to one layout.
    public var setLayout: (WindowLayoutKind) -> Void
    /// Asks one window to close.
    public var closeWindow: (String) -> Void
    /// Takes a window out of the large cell, so that it becomes a tile.
    public var makeWidget: (String) -> Void
    /// Takes a message away.
    public var dismissNotice: (String) -> Void

    public init(openApp: @escaping (String) -> Void = { _ in },
                closeFrontWindow: @escaping () -> Void = {},
                raiseWindow: @escaping (String) -> Void = { _ in },
                toggleSummon: @escaping () -> Void = {},
                nextLayout: @escaping () -> Void = {},
                setLayout: @escaping (WindowLayoutKind) -> Void = { _ in },
                closeWindow: @escaping (String) -> Void = { _ in },
                makeWidget: @escaping (String) -> Void = { _ in },
                dismissNotice: @escaping (String) -> Void = { _ in }) {
        self.openApp = openApp
        self.closeFrontWindow = closeFrontWindow
        self.raiseWindow = raiseWindow
        self.toggleSummon = toggleSummon
        self.nextLayout = nextLayout
        self.setLayout = setLayout
        self.closeWindow = closeWindow
        self.makeWidget = makeWidget
        self.dismissNotice = dismissNotice
    }
}

/// The screen: the rail on the left, and the canvas beside it.
public struct RootView: View {
    let state: ShellState
    let actions: ShellActions

    public init(state: ShellState, actions: ShellActions = ShellActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Nothing is open: the canvas says how to open something.
            if state.windows.isEmpty, state.canvas.width > 0 {
                EmptyCanvas()
                    .frame(width: Double(state.canvas.width),
                           height: Double(state.canvas.height))
                    .offset(x: Double(state.canvas.x), y: Double(state.canvas.y))
            }
            // The bar over each window that has room for one.
            ForEach(state.heads) { head in
                WindowHeadView(head: head, actions: actions)
                    .frame(width: Double(head.cell.width), height: Metrics.headHeight)
                    .offset(x: Double(head.cell.x), y: Double(head.cell.y))
            }
            // The cells that the band holds for windows with no place. They
            // are in the canvas, so they go under the rail and under Summon.
            ForEach(state.standIns) { card in
                StandInCard(card: card, actions: actions)
                    .frame(width: Double(card.frame.width), height: Double(card.frame.height))
                    .offset(x: Double(card.frame.x), y: Double(card.frame.y))
            }
            HStack(spacing: 0) {
                RailView(state: state, actions: actions)
                    .padding(Metrics.gap)
                Spacer()        // the canvas: the windows are behind it
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The messages, at the end of the band, so that none of them
            // covers the window in the large cell.
            ForEach(Array(noticePlaces.enumerated()), id: \.offset) { place in
                NoticeView(notice: place.element.notice, actions: actions)
                    .frame(width: Double(place.element.frame.width),
                           height: Double(place.element.frame.height))
                    .offset(x: Double(place.element.frame.x), y: Double(place.element.frame.y))
            }
            if state.summonIsOpen {
                SummonView(state: state, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Where each message goes: a column at the end of the band, from the
    /// bottom of the canvas upwards, so that the newest one is lowest.
    var noticePlaces: [(notice: Notice, frame: Rect)] {
        guard state.canvas.width > Int(WindowMetrics.tile) else { return [] }
        let x = state.canvas.x + state.canvas.width - Int(WindowMetrics.tile)
        var bottom = state.canvas.y + state.canvas.height
        var places: [(Notice, Rect)] = []
        for notice in state.notices.reversed() {
            let height = Int(NoticeView.height(of: notice))
            bottom -= height
            guard bottom > state.canvas.y else { break }
            places.append((notice, Rect(x: x, y: bottom,
                                        width: Int(WindowMetrics.tile), height: height)))
            bottom -= Int(Metrics.gap)
        }
        return places
    }

    /// The canvas of `screen`: everything that is not the rail. A layout
    /// owns it, and it stays free even when no window is open.
    public static func windowArea(screen: Rect) -> Rect {
        let left = Int((Metrics.gap + Metrics.railWidth + Metrics.gap).rounded())
        let margin = Int(Metrics.gap)
        return Rect(x: screen.x + left, y: screen.y + margin,
                    width: max(0, screen.width - left - margin),
                    height: max(0, screen.height - 2 * margin))
    }
}
