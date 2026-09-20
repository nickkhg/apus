import Render
import Toolkit

// The layouts of the screen. A window never floats and never covers another
// window: a layout gives every window its frame, and that is the only way a
// window gets one.
//
// A layout is a Layout (see Toolkit/Layout.swift), so it proposes a size to
// each window, reads the answer, and then places it. A window that the
// layout does not place waits in the rail, and the shell draws a stand-in
// where it would have been. This is how a window that cannot fit a tile is
// handled, and it is the same rule for an app of the toolkit and for an app
// that knows nothing about mydistro.

/// How much space a window has, which says which user interface it draws.
/// The class comes from the proposal, not from the frame, so that a window
/// knows what to draw while it is still answering.
public enum SizeClass: String, Sendable {
    /// A tile in the band. The app draws a user interface made for it.
    case widget
    /// A narrow window: half of the screen, or a cell of a large grid.
    case compact
    /// A window with room, such as the principal cell.
    case large

    /// The class for a proposed size. The shorter side decides.
    public static func of(_ proposal: Proposal) -> SizeClass {
        let sides = [proposal.width, proposal.height].compactMap { $0 }.filter(\.isFinite)
        guard let shortest = sides.min() else { return .large }
        if shortest <= WindowMetrics.widgetLimit { return .widget }
        if shortest <= WindowMetrics.compactLimit { return .compact }
        return .large
    }
}

/// The sizes that the layouts share, in pixels.
public enum WindowMetrics {
    /// The width of the rail on the edge of the screen.
    public static let rail: Double = 56
    /// The space between two cells, and around the canvas.
    public static let gap: Double = 8
    /// A tile is this long across. Only its other side changes, so an app
    /// draws one widget user interface for one width.
    public static let tile: Double = 256
    /// A tile length is a whole number of these.
    public static let tileStep: Double = 64
    /// The shortest and the longest tile. A window that answers less gets
    /// this much. A window that answers more does not fit a tile at all.
    public static let shortestTile: Double = 192
    public static let longestTile: Double = 384
    /// The large cell never goes below this, so the band stops growing.
    public static let principalMinimum: Double = 720
    /// The most windows that the grid layout shows.
    public static let gridMaximum = 9
    /// A proposal this short or shorter makes a window draw its widget UI.
    public static let widgetLimit: Double = 320
    /// Above this a window is `large`.
    public static let compactLimit: Double = 640

    /// The length of a tile for the length that a window answered. A window
    /// that wants more than the longest tile gets no tile, so the answer is
    /// `nil` and the window waits in the rail.
    public static func tileLength(for answer: Double) -> Double? {
        // A window that asks for very little still gets a usable tile.
        guard answer > shortestTile else { return shortestTile }
        let stepped = (answer / tileStep).rounded(.up) * tileStep
        return stepped <= longestTile ? stepped : nil
    }
}

/// Which layout owns the screen. A person picks one, and later one for each
/// desktop.
public enum WindowLayoutKind: String, CaseIterable, Sendable {
    case principal, sideBySide, grid, full

    /// The name that the shell shows.
    public var name: String {
        switch self {
        case .principal: "Principal and widgets"
        case .sideBySide: "Side by side"
        case .grid: "Grid"
        case .full: "Full"
        }
    }

    /// The key that chooses it, after Super.
    public var key: String {
        switch self {
        case .principal: "1"
        case .sideBySide: "2"
        case .grid: "3"
        case .full: "4"
        }
    }

    public var layout: AnyLayout {
        switch self {
        case .principal: AnyLayout(PrincipalAndWidgets())
        case .sideBySide: AnyLayout(SideBySide())
        case .grid: AnyLayout(GridLayout())
        case .full: AnyLayout(FullScreen())
        }
    }
}

// MARK: - Principal and widgets

/// The default layout. The first window takes the large cell. The others
/// become tiles in a band along the long edge. A window that the band has no
/// room for, and a window that answers more than a tile can hold, waits in
/// the rail.
public struct PrincipalAndWidgets: Layout {
    public init() {}

    public func sizeThatFits(proposal: Proposal, subviews: LayoutSubviews) -> Size {
        Size(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    public func placeSubviews(in bounds: Frame, proposal: Proposal, subviews: LayoutSubviews) {
        guard let principal = subviews.first else { return }

        // The tiles stack along the shorter side of the canvas, so the band
        // sits on the long edge: a column on the right of a wide screen, a
        // row along the bottom of a tall one.
        let stack: Axis = bounds.width >= bounds.height ? .vertical : .horizontal
        let across = stack.other
        let others = subviews.dropFirst()

        let columns = others.isEmpty ? 0 : bandColumns(in: bounds, across: across)
        let bandThickness = columns == 0
            ? 0
            : Double(columns) * WindowMetrics.tile + Double(columns - 1) * WindowMetrics.gap

        // The large cell takes what the band leaves.
        let cellAcross = bandThickness == 0
            ? bounds.size.length(across)
            : bounds.size.length(across) - bandThickness - WindowMetrics.gap
        let cellSize = Size.along(stack, bounds.size.length(stack), across: max(0, cellAcross))
        principal.place(in: Frame(origin: (bounds.x, bounds.y), size: cellSize))

        guard columns > 0 else { return }

        // The band starts after the large cell.
        let bandStart = bounds.size.length(across) - bandThickness
        var column = 0
        var used = 0.0
        let room = bounds.size.length(stack)

        for window in others {
            guard column < columns else { break }
            // The tile is fixed across and free along the stack, so the
            // window says how long it wants to be.
            let answer = window.sizeThatFits(
                Proposal.unspecified
                    .replacing(across, with: WindowMetrics.tile)
                    .replacing(stack, with: nil))
            // A window that needs more room across than a tile gives cannot
            // use one, however long the tile is.
            guard answer.length(across) <= WindowMetrics.tile,
                  let length = WindowMetrics.tileLength(for: answer.length(stack)) else {
                // The window cannot use a tile. It waits in the rail, and the
                // shell draws a stand-in where it would have been.
                continue
            }
            if used + length > room {
                // This column is full. Start the next one.
                column += 1
                used = 0
                guard column < columns else { break }
            }
            let offsetAcross = bandStart + Double(column) * (WindowMetrics.tile + WindowMetrics.gap)
            let origin: (x: Double, y: Double) = across == .horizontal
                ? (bounds.x + offsetAcross, bounds.y + used)
                : (bounds.x + used, bounds.y + offsetAcross)
            window.place(in: Frame(origin: origin,
                                   size: .along(stack, length, across: WindowMetrics.tile)))
            used += length + WindowMetrics.gap
        }
    }

    /// How many columns of tiles the band has. A column is added only while
    /// the large cell keeps its smallest size and the band stays inside a
    /// third of the canvas. That gives one column at 1280, two at 1920 and
    /// three at 2560.
    private func bandColumns(in bounds: Frame, across: Axis) -> Int {
        let available = bounds.size.length(across)
        var columns = 1
        while true {
            let next = columns + 1
            let thickness = Double(next) * WindowMetrics.tile + Double(next - 1) * WindowMetrics.gap
            let cell = available - thickness - WindowMetrics.gap
            guard cell >= WindowMetrics.principalMinimum, thickness <= available / 3 else {
                return columns
            }
            columns = next
        }
    }
}

// MARK: - Side by side

/// Two windows, each with half of the canvas. Every other window waits in
/// the rail.
public struct SideBySide: Layout {
    public init() {}

    public func sizeThatFits(proposal: Proposal, subviews: LayoutSubviews) -> Size {
        Size(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    public func placeSubviews(in bounds: Frame, proposal: Proposal, subviews: LayoutSubviews) {
        let half = (bounds.width - WindowMetrics.gap) / 2
        guard half > 0 else { return }
        for (index, window) in subviews.prefix(2).enumerated() {
            window.place(in: Frame(x: bounds.x + Double(index) * (half + WindowMetrics.gap),
                                   y: bounds.y, width: half, height: bounds.height))
        }
    }
}

// MARK: - Grid

/// Every window in a cell of a grid, up to nine. The cells are as square as
/// the count allows. A cell that is small enough carries the widget class,
/// so a window draws its widget user interface in it.
public struct GridLayout: Layout {
    public init() {}

    public init(maximum: Int) {
        self.maximum = maximum
    }

    var maximum = WindowMetrics.gridMaximum

    public func sizeThatFits(proposal: Proposal, subviews: LayoutSubviews) -> Size {
        Size(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    /// The columns and the rows for a number of windows.
    public static func shape(for count: Int) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (0, 0) }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        return (columns, Int((Double(count) / Double(columns)).rounded(.up)))
    }

    public func placeSubviews(in bounds: Frame, proposal: Proposal, subviews: LayoutSubviews) {
        let shown = Array(subviews.prefix(maximum))
        let (columns, rows) = GridLayout.shape(for: shown.count)
        guard columns > 0, rows > 0 else { return }
        let width = (bounds.width - Double(columns - 1) * WindowMetrics.gap) / Double(columns)
        let height = (bounds.height - Double(rows - 1) * WindowMetrics.gap) / Double(rows)
        guard width > 0, height > 0 else { return }
        for (index, window) in shown.enumerated() {
            let column = index % columns
            let row = index / columns
            window.place(in: Frame(x: bounds.x + Double(column) * (width + WindowMetrics.gap),
                                   y: bounds.y + Double(row) * (height + WindowMetrics.gap),
                                   width: width, height: height))
        }
    }
}

// MARK: - Full

/// One window with the whole canvas. Every other window waits in the rail.
public struct FullScreen: Layout {
    public init() {}

    public func sizeThatFits(proposal: Proposal, subviews: LayoutSubviews) -> Size {
        Size(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    public func placeSubviews(in bounds: Frame, proposal: Proposal, subviews: LayoutSubviews) {
        subviews.first?.place(in: bounds)
    }
}
