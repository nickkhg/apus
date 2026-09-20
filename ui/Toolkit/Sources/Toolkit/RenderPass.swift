import Render

/// What one frame of a view tree gives: the items to draw, and the places
/// that react to the pointer.
public struct RenderPass {
    /// The drawing items, back to front.
    public var list: DisplayList = []
    /// Where the views that watch the pointer are, in the order that they
    /// were drawn.
    public internal(set) var hoverRegions: [HoverRegion] = []

    public init() {}
}

/// A view that wants to know when the pointer is over it.
public struct HoverRegion {
    /// The place of the view in the tree. It is the same in the next frame,
    /// so the host knows that the pointer stays over the same view.
    let id: Int
    let frame: Frame
    let action: (Bool) -> Void

    public func contains(x: Double, y: Double) -> Bool {
        x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
    }
}
