import Render

/// Views in a column, from top to bottom.
public struct VStack<Content: View>: View {
    public typealias Body = Never
    let alignment: HorizontalAlignment
    let spacing: Double
    let content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: Double = 0,
                @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        nodes.append(StackNode(axis: .vertical, spacing: spacing,
                               alignment: Alignment(horizontal: alignment, vertical: .top),
                               children: children))
    }
}

/// Views in a row, from left to right.
public struct HStack<Content: View>: View {
    public typealias Body = Never
    let alignment: VerticalAlignment
    let spacing: Double
    let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: Double = 0,
                @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        nodes.append(StackNode(axis: .horizontal, spacing: spacing,
                               alignment: Alignment(horizontal: .leading, vertical: alignment),
                               children: children))
    }
}

/// Views on top of each other, the first one at the back.
public struct ZStack<Content: View>: View {
    public typealias Body = Never
    let alignment: Alignment
    let content: Content

    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        nodes.append(ZStackNode(alignment: alignment, children: children))
    }
}
