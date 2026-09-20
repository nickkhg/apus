import Toolkit

// The rail: the one piece of chrome that the shell always shows. It sits on
// the left edge and holds four things, from the top down.
//
//   Summon   starts an app and moves to a window
//   Layout   changes the layout of the canvas
//   Track    a bar for each open window, which says where that window is
//   Status   the network, the power and the time
//
// The track is a map of the session. A tall bar is the window in the large
// cell, a shorter bar is a window in a tile, and the shortest bars are the
// windows that wait in the rail because no cell could hold them.

/// One open window, as the rail shows it.
public struct WindowEntry: Identifiable, Equatable, Sendable {
    /// Where the layout put the window.
    public enum Place: Sendable, Equatable {
        /// The large cell.
        case principal
        /// A tile in the band.
        case widget
        /// No cell: the window waits, and the shell draws a stand-in.
        case rail
    }

    public let id: String
    public let title: String
    public let appID: String
    public let place: Place
    /// The window that has the keyboard.
    public let hasFocus: Bool

    public init(id: String, title: String, appID: String, place: Place, hasFocus: Bool = false) {
        self.id = id
        self.title = title
        self.appID = appID
        self.place = place
        self.hasFocus = hasFocus
    }
}

/// The time, as the rail stacks it: the hour over the minute over the day.
public struct Clock: Equatable, Sendable {
    public var hour: String
    public var minute: String
    public var weekday: String

    public init(hour: String = "", minute: String = "", weekday: String = "") {
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }
}

/// The strip of chrome on the left edge of the screen.
public struct RailView: View {
    let state: ShellState
    let actions: ShellActions

    public init(state: ShellState, actions: ShellActions = ShellActions()) {
        self.state = state
        self.actions = actions
    }

    private var appearance: Appearance { Appearance(state.mode) }

    public var body: some View {
        VStack(spacing: 0) {
            SummonButton(actions: actions)
                .padding(.top, 16)
            LayoutButton(kind: state.layout, actions: actions)
                .padding(.top, Metrics.gap)
            Divider(thickness: 1)
                .foregroundColor(Palette.divider)
                .frame(width: Metrics.dividerWidth)
                .padding(.top, 12)
            Track(windows: state.windows, actions: actions)
                .padding(.top, 13)
            Spacer()
            Status(clock: state.clock)
        }
        .frame(width: Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Metrics.railRadius)
                .fill(appearance.surfaceFace)
        )
        .shadow(appearance.surfaceShadow, cornerRadius: Metrics.railRadius)
    }
}

/// Opens Summon: the one surface that starts an app and moves to a window.
struct SummonButton: View {
    let actions: ShellActions
    /// How much the pointer has lit this control, from 0 to 1.
    @State private var glow = 0.0

    var body: some View {
        Button(action: { actions.toggleSummon() }) {
            VStack(alignment: .leading, spacing: 3) {
                bar(width: 22)
                bar(width: 16)
                bar(width: 10)
            }
            .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
            .background(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                    .fill(Palette.accentSurface.lightened(by: glow * 0.4))
            )
            .onHover { hovering in withAnimation(.quick) { glow = hovering ? 1 : 0 } }
        }
    }

    private func bar(width: Double) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Palette.accent)
            .frame(width: width, height: 2)
    }
}

/// Changes the layout of the canvas. The glyph shows the layout in use.
struct LayoutButton: View {
    let kind: WindowLayoutKind
    let actions: ShellActions
    /// How much the pointer has lit this control, from 0 to 1.
    @State private var glow = 0.0

    var body: some View {
        Button(action: { actions.nextLayout() }) {
            glyph
                .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                        .fill(Palette.control.lightened(by: glow * 0.5))
                )
                .onHover { hovering in withAnimation(.quick) { glow = hovering ? 1 : 0 } }
        }
    }

    /// A small picture of the layout: the large cell, and what is beside it.
    private var glyph: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.secondaryText)
                .frame(width: principalWidth, height: 20)
            VStack(spacing: 2) {
                ForEach(Array(0..<sideCount), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.dimText)
                        .frame(width: 8, height: sideHeight)
                }
            }
        }
    }

    private var principalWidth: Double {
        switch kind {
        case .principal: 12
        case .sideBySide: 11
        case .grid: 8
        case .full: 22
        }
    }

    private var sideCount: Int {
        switch kind {
        case .principal: 2
        case .sideBySide: 1
        case .grid: 2
        case .full: 0
        }
    }

    private var sideHeight: Double {
        switch kind {
        case .principal: 9
        case .sideBySide: 20
        case .grid: 9
        case .full: 0
        }
    }
}

/// The map of the session: one bar for each open window.
struct Track: View {
    let windows: [WindowEntry]
    let actions: ShellActions

    var body: some View {
        VStack(spacing: Metrics.barSpacing) {
            ForEach(onScreen) { window in
                TrackBar(window: window, actions: actions)
            }
            if !waiting.isEmpty {
                Divider(thickness: 1)
                    .foregroundColor(Palette.divider)
                    .frame(width: Metrics.dividerWidth)
                    .padding(.vertical, 2)
                ForEach(waiting) { window in
                    TrackBar(window: window, actions: actions)
                }
            }
        }
    }

    /// The windows that have a cell, in the order that the canvas shows them.
    private var onScreen: [WindowEntry] {
        windows.filter { $0.place != .rail }
    }

    /// The windows that wait for a cell, under a line of their own.
    private var waiting: [WindowEntry] {
        windows.filter { $0.place == .rail }
    }
}

/// One window in the track. Its height says how much of the canvas the
/// window holds, and a ring says that it has the keyboard.
struct TrackBar: View {
    let window: WindowEntry
    let actions: ShellActions
    /// How much the pointer has lit this control, from 0 to 1.
    @State private var glow = 0.0

    var body: some View {
        Button(action: { actions.raiseWindow(window.id) }) {
            bar
                .frame(width: Metrics.trackWidth, height: height)
                .overlay(ring)
                .padding(Metrics.ringWidth)
                .onHover { hovering in withAnimation(.quick) { glow = hovering ? 1 : 0 } }
        }
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(color)
    }

    /// The ring sits outside the bar, in the padding around it.
    private var ring: some View {
        RoundedRectangle(cornerRadius: radius + Metrics.ringWidth)
            .stroke(window.hasFocus ? Palette.accent : Color.clear,
                    lineWidth: Metrics.ringWidth)
            .padding(-Metrics.ringWidth)
    }

    private var height: Double {
        switch window.place {
        case .principal: Metrics.principalBar
        case .widget: Metrics.widgetBar
        case .rail: Metrics.railBar
        }
    }

    private var radius: Double {
        switch window.place {
        case .principal: 8
        case .widget: 7
        case .rail: 6
        }
    }

    private var color: Color {
        let base: Color = switch window.place {
        case .principal: Palette.principal
        case .widget: Palette.widget.opacity(0.6)
        case .rail: Palette.dimText.opacity(0.5)
        }
        // A bar under the pointer comes forward.
        return base.opacity(base.alpha + (1 - base.alpha) * glow)
    }
}

/// The bottom of the rail: the network, the power and the time.
struct Status: View {
    let clock: Clock

    var body: some View {
        VStack(spacing: 0) {
            Divider(thickness: 1)
                .foregroundColor(Palette.divider)
                .frame(width: Metrics.dividerWidth)
            network
                .padding(.top, 21)
            power
                .padding(.top, 14)
            time
                .padding(.top, 13)
        }
        .padding(.bottom, 22)
    }

    /// Three bars that grow: the strength of the network.
    private var network: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([4.0, 8, 12], id: \.self) { height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(height == 12 ? Palette.secondaryText : Palette.dimText)
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 12)
    }

    /// A battery, with what is left of it.
    private var power: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Palette.secondaryText)
            .frame(width: 9, height: 5)
            .padding(2)
            .frame(width: 16, height: 9, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Palette.dimText, lineWidth: 1)
            )
    }

    /// The hour over the minute over the day.
    private var time: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(clock.hour)
                .font(Font(size: 16, weight: .bold))
                .foregroundColor(Palette.text)
            Text(clock.minute)
                .font(Font(size: 16))
                .foregroundColor(Palette.dimText)
            Text(clock.weekday)
                .font(Font(size: 9, weight: .bold))
                .foregroundColor(Palette.faintText)
                .padding(.top, 6)
        }
        .frame(width: Metrics.dividerWidth, alignment: .leading)
    }
}
