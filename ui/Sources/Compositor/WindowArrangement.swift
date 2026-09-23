import Render
import Shell
import Toolkit

// How the compositor turns its window list into frames.
//
// A layout proposes a size to each window and reads an answer. A window is
// another process, so the compositor cannot call into it: it answers from
// what the protocol already carries. xdg_toplevel.set_min_size is the answer
// when the app sent one, and a tile when it did not. A person who changed the
// length of a tile with a resize gave the window a length of its own, and
// that length is the answer then.
//
// This is why a foreign app needs no code path of its own. It is a window
// that answers a proposal the layout cannot satisfy, and every layout must
// handle that anyway, because an app of the toolkit can answer badly too.

enum WindowAnswer {
    /// What a window wants for a proposed size.
    ///
    /// `preferred` is the length that a person gave the window with a
    /// resize, for the side that the proposal leaves free.
    static func size(minimum: (width: Double, height: Double)?, preferred: Double? = nil,
                     content: Bitmap?, to proposal: Proposal) -> Size {
        Size(width: length(proposal.width, minimum: minimum?.width, preferred: preferred,
                           committed: content.map { Double($0.width) }),
             height: length(proposal.height, minimum: minimum?.height, preferred: preferred,
                            committed: content.map { Double($0.height) }))
    }

    /// One side of the answer. A set side is taken, unless the app needs
    /// more.
    ///
    /// A free side is the length that a person gave the window, unless the
    /// app needs more. Without one it is the smallest size that the app
    /// accepts, and a tile when it named none. The size that the app last
    /// drew is deliberately not used here: an app that drew a large window
    /// would then answer a large length for a tile, and no app could ever
    /// take a tile after it drew once. The app answers the real question by drawing: the layout
    /// gives it the tile, and the app commits a buffer for that size.
    private static func length(_ proposed: Double?, minimum: Double?, preferred: Double?,
                               committed: Double?) -> Double {
        if let proposed, proposed.isFinite {
            return max(proposed, minimum ?? 0)
        }
        if let preferred { return max(preferred, minimum ?? 0) }
        return minimum ?? WindowMetrics.tile
    }
}
