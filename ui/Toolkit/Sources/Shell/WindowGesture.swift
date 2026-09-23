import Render
import Toolkit

// What a move and a resize mean on a canvas that a layout owns.
//
// An app asks for both with the pointer: xdg_toplevel.move and
// xdg_toplevel.resize, after a press on its own title bar or its own edge. On
// a desktop where windows float, the window then follows the pointer. Here a
// window never floats, so each request is read as a change to the
// arrangement, and the layout still gives every window its frame:
//
// - A move takes a window to another cell. The window follows the pointer
//   while the button is down, and on release it changes places with the
//   window whose cell is under the pointer.
// - A resize moves an edge that the layout lets a person move: the edge
//   between two windows side by side, and the length of a tile in the band.
//   Every other size belongs to the layout, and the resize is refused.
//
// This is the part without Wayland, so the Mac tests it.

/// The edges of a window that a resize moves. The values are the bits of
/// xdg_toplevel's resize_edge: a corner is two edges.
public struct WindowEdges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let top = WindowEdges(rawValue: 1)
    public static let bottom = WindowEdges(rawValue: 2)
    public static let left = WindowEdges(rawValue: 4)
    public static let right = WindowEdges(rawValue: 8)
}

/// What a resize changes in the layout that owns the canvas.
public enum WindowResize: Equatable, Sendable {
    /// Side by side: the edge between the two windows follows the pointer,
    /// and both windows change width.
    case split
    /// Principal and widgets: the length of a tile along the band. The width
    /// across the band stays 256, so that an app draws one widget user
    /// interface. `sign` is 1 when the edge that follows the pointer is the
    /// far one (bottom or right), and -1 for the near one.
    case tileLength(axis: Axis, sign: Double)

    /// What a resize of one window does, or nil when the layout owns that
    /// size and the resize is refused.
    ///
    /// `index` is the place of the window in the layout, front first, and
    /// `placed` says whether the layout gave it a cell. A window that waits
    /// in the rail has no edge to move.
    public static func of(layout: WindowLayoutKind, index: Int, placed: Bool,
                          edges: WindowEdges, canvas: Frame) -> WindowResize? {
        guard placed else { return nil }
        switch layout {
        case .principal:
            // The large cell takes what the band leaves, and the band is a
            // whole number of tiles across. Only a tile has an edge to move.
            guard index > 0 else { return nil }
            let stack: Axis = canvas.width >= canvas.height ? .vertical : .horizontal
            let (near, far): (WindowEdges, WindowEdges) = stack == .vertical
                ? (.top, .bottom)
                : (.left, .right)
            if edges.contains(far) { return .tileLength(axis: stack, sign: 1) }
            if edges.contains(near) { return .tileLength(axis: stack, sign: -1) }
            return nil
        case .sideBySide:
            // Only the edge between the two windows moves. The outer edges
            // are the edges of the canvas.
            if index == 0, edges.contains(.right) { return .split }
            if index == 1, edges.contains(.left) { return .split }
            return nil
        case .grid, .full:
            // Every cell of a grid has the size of the others, and a full
            // window has the whole canvas. Neither has an edge of its own.
            return nil
        }
    }

    /// The length of a tile after the pointer moved `delta` points along
    /// the band from where it pressed. The length snaps to a whole tile
    /// step, and stays between the shortest and the longest tile, so a
    /// resize never takes a window out of the band.
    public static func tileLength(from start: Double, moved delta: Double,
                                  sign: Double) -> Double {
        let wanted = start + sign * delta
        let stepped = (wanted / WindowMetrics.tileStep).rounded() * WindowMetrics.tileStep
        return min(max(stepped, WindowMetrics.shortestTile), WindowMetrics.longestTile)
    }
}

/// Where a window goes when a person drops it.
public enum WindowMove {
    /// Whether a window can go anywhere else in this layout. Full shows one
    /// window, so there is no other cell to take.
    public static func isPossible(in layout: WindowLayoutKind) -> Bool {
        layout != .full
    }

    /// The place, among `cells` (front first), whose cell holds the point,
    /// when it is not the place of the window that moves. A window dropped on
    /// its own cell, on the rail or on an empty part of the canvas stays
    /// where it was, and the answer is nil.
    public static func target(at point: (x: Double, y: Double), cells: [Rect?],
                              moving: Int) -> Int? {
        for (index, cell) in cells.enumerated() {
            guard let cell, index != moving else { continue }
            if point.x >= Double(cell.x), point.x < Double(cell.x + cell.width),
               point.y >= Double(cell.y), point.y < Double(cell.y + cell.height) {
                return index
            }
        }
        return nil
    }
}

extension WindowLayoutKind {
    /// Whether the keys always belong to the window in the first place.
    ///
    /// In the principal layout the large cell and the keys never belong to
    /// two different windows: a tile is a widget, and it has no head to show
    /// that it has the keys. A click on a tile brings it into the large cell.
    /// Full shows the first window alone. Side by side and the grid give
    /// cells of the same rank, so a click there gives the window the keys
    /// and moves nothing.
    public var keysFollowFirstPlace: Bool {
        self == .principal || self == .full
    }
}
