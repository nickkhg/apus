/// The values that flow down the view tree: the colour and the font that a
/// view uses if it does not set its own. A modifier such as
/// `.foregroundColor(_:)` changes them for the views inside it.
public struct EnvironmentValues: Sendable {
    public var foregroundColor: Color = .white
    public var font: Font = .body

    public init() {}
}

/// A view that changes the environment for the views inside it.
public struct EnvironmentView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let transform: (inout EnvironmentValues) -> Void

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var inner = environment
        transform(&inner)
        content.makeNodes(into: &nodes, environment: inner)
    }
}

extension View {
    /// The colour of the text and the shapes inside this view.
    public func foregroundColor(_ color: Color) -> EnvironmentView<Self> {
        EnvironmentView(content: self) { $0.foregroundColor = color }
    }

    /// The font of the text inside this view.
    public func font(_ font: Font) -> EnvironmentView<Self> {
        EnvironmentView(content: self) { $0.font = font }
    }
}
