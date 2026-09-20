import Render

/// What one frame of a view tree gives: the items to draw, and the places
/// that react to the pointer.
public struct RenderPass {
    /// The drawing items, back to front.
    public var list: DisplayList = []
    /// How many pixels there are to the point. Every frame is in points, and
    /// a node makes its items in pixels with this.
    public var scale: Double = 1
    /// Where the views that watch the pointer are, in the order that they
    /// were drawn.
    public internal(set) var hoverRegions: [HoverRegion] = []
    /// Where the views that answer a click are, in the order that they were
    /// drawn. The last one is in front.
    public internal(set) var tapRegions: [TapRegion] = []
    /// The views that want the keys, in the order that they were drawn. The
    /// last one is in front, and it reads a key first.
    public internal(set) var keyRegions: [KeyRegion] = []

    public init() {}
}

/// A view that wants to know when the pointer is over it.
public struct HoverRegion {
    /// The place of the view in the tree. It is the same in the next frame,
    /// so the host knows that the pointer stays over the same view.
    let id: Int
    /// Where the view is, in points on the screen.
    public internal(set) var frame: Frame
    let action: (Bool) -> Void

    public func contains(x: Double, y: Double) -> Bool {
        x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
    }
}

/// A view that answers a click of the pointer.
public struct TapRegion {
    let id: Int
    /// Where the view is, in points on the screen.
    public internal(set) var frame: Frame
    /// The button went down over the view, or it went up, or the pointer
    /// left the view while the button was down.
    let onPress: (Bool) -> Void
    /// The button went down and up over the same view.
    let onTap: () -> Void

    public func contains(x: Double, y: Double) -> Bool {
        x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height
    }
}
