import Render

// Each modifier is a view that wraps another view. It makes one layout node
// with the child's node inside it.

/// A view with a fixed or a limited size.
public struct FrameView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let width: Double?
    let height: Double?
    let minWidth: Double?
    let minHeight: Double?
    let maxWidth: Double?
    let maxHeight: Double?
    let alignment: Alignment

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(FrameNode(child: content.node(environment: environment),
                               width: width, height: height,
                               minWidth: minWidth, minHeight: minHeight,
                               maxWidth: maxWidth, maxHeight: maxHeight,
                               alignment: alignment))
    }
}

/// A view with space around it.
public struct PaddingView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let insets: EdgeInsets

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(PaddingNode(child: content.node(environment: environment), insets: insets))
    }
}

/// A view with another view behind it.
public struct BackgroundView<Content: View, Background: View>: View {
    public typealias Body = Never
    let content: Content
    let background: Background

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(BackgroundNode(child: content.node(environment: environment),
                                    background: background.node(environment: environment)))
    }
}

/// A view moved from where the layout put it.
public struct OffsetView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let dx: Double
    let dy: Double

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(OffsetNode(child: content.node(environment: environment), dx: dx, dy: dy))
    }
}

extension View {
    /// A fixed size. A `nil` length keeps the view's own size on that axis.
    public func frame(width: Double? = nil, height: Double? = nil,
                      alignment: Alignment = .center) -> FrameView<Self> {
        FrameView(content: self, width: width, height: height,
                  minWidth: nil, minHeight: nil, maxWidth: nil, maxHeight: nil,
                  alignment: alignment)
    }

    /// Limits on the size. Use `.infinity` for a view that takes the space
    /// that it gets.
    public func frame(minWidth: Double? = nil, maxWidth: Double? = nil,
                      minHeight: Double? = nil, maxHeight: Double? = nil,
                      alignment: Alignment = .center) -> FrameView<Self> {
        FrameView(content: self, width: nil, height: nil,
                  minWidth: minWidth, minHeight: minHeight,
                  maxWidth: maxWidth, maxHeight: maxHeight,
                  alignment: alignment)
    }

    /// The same space on all four sides.
    public func padding(_ length: Double = 8) -> PaddingView<Self> {
        PaddingView(content: self, insets: EdgeInsets(all: length))
    }

    /// Space on some sides.
    public func padding(_ edges: Edge, _ length: Double = 8) -> PaddingView<Self> {
        PaddingView(content: self, insets: edges.insets(length))
    }

    public func padding(_ insets: EdgeInsets) -> PaddingView<Self> {
        PaddingView(content: self, insets: insets)
    }

    /// A view behind this one, with the same frame.
    public func background<Background: View>(_ background: Background) -> BackgroundView<Self, Background> {
        BackgroundView(content: self, background: background)
    }

    public func offset(x: Double = 0, y: Double = 0) -> OffsetView<Self> {
        OffsetView(content: self, dx: x, dy: y)
    }
}

/// A view drawn over another view, with the same frame. A ring around a
/// control is an overlay.
public struct OverlayView<Content: View, Over: View>: View {
    public typealias Body = Never
    let content: Content
    let over: Over

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        var above: [LayoutNode] = []
        over.makeNodes(into: &above, environment: environment)
        nodes.append(OverlayNode(child: children.count == 1 ? children[0]
                                     : ZStackNode(alignment: .center, children: children),
                                 over: above.count == 1 ? above[0]
                                     : ZStackNode(alignment: .center, children: above)))
    }
}

extension View {
    /// Draws `over` on top of this view, in the same frame.
    public func overlay<Over: View>(_ over: Over) -> OverlayView<Self, Over> {
        OverlayView(content: self, over: over)
    }
}

/// A view cut to its frame.
public struct ClippedView<Content: View>: View {
    public typealias Body = Never
    let content: Content

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        nodes.append(ClipNode(child: children.count == 1 ? children[0]
                                                         : ZStackNode(alignment: .center, children: children)))
    }
}

extension View {
    /// Draws nothing outside the frame of this view. A list that is longer
    /// than its space, or a window in a cell, needs it.
    public func clipped() -> ClippedView<Self> {
        ClippedView(content: self)
    }
}
