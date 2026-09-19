import Render

// A declarative user interface layer, in the shape of SwiftUI: a view is a
// value, and its `body` describes what it contains. There is no dependency
// graph behind it (see docs/decisions.md). Each frame lowers the view tree to
// layout nodes, and the nodes lay out and draw themselves. A shell UI is
// small enough that a complete rebuild costs less than tracking changes.

/// A piece of user interface.
public protocol View {
    associatedtype Body: View

    @ViewBuilder var body: Body { get }

    /// Adds this view's layout nodes to `nodes`. The default lowers `body`,
    /// so only a view whose `Body` is `Never` implements it.
    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues)
}

extension View {
    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        body.makeNodes(into: &nodes, environment: environment)
    }

    /// The one node for this view. Several nodes go in a stack, and no node
    /// becomes an empty one, so that a modifier always has one child.
    func node(environment: EnvironmentValues) -> LayoutNode {
        var nodes: [LayoutNode] = []
        makeNodes(into: &nodes, environment: environment)
        switch nodes.count {
        case 0: return EmptyNode()
        case 1: return nodes[0]
        default: return ZStackNode(alignment: .center, children: nodes)
        }
    }
}

/// `Never` is the `Body` of a view that draws itself: it makes layout nodes
/// in `makeNodes(into:environment:)` and never asks for a `body`.
extension Never: View {
    public typealias Body = Never
}

extension View where Body == Never {
    public var body: Never { fatalError("a primitive view has no body") }
}

// MARK: - The builder

/// Collects the views in a `body` or in a container.
@resultBuilder
public enum ViewBuilder {
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView {
        var views: [any View] = []
        repeat views.append(each content)
        return TupleView(views)
    }

    public static func buildOptional<Content: View>(_ content: Content?) -> OptionalView<Content> {
        OptionalView(content)
    }

    public static func buildEither<First: View, Second: View>(first: First) -> ConditionalView<First, Second> {
        ConditionalView(first: first)
    }

    public static func buildEither<First: View, Second: View>(second: Second) -> ConditionalView<First, Second> {
        ConditionalView(second: second)
    }

    public static func buildArray<Content: View>(_ content: [Content]) -> ArrayView<Content> {
        ArrayView(content)
    }

    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> Content {
        content
    }
}

// MARK: - The views that the builder makes

/// A view that draws nothing.
public struct EmptyView: View {
    public typealias Body = Never
    public init() {}
    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {}
}

/// Several views in the order that they were written.
public struct TupleView: View {
    public typealias Body = Never
    let views: [any View]

    init(_ views: [any View]) { self.views = views }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        for view in views { view.makeNodes(into: &nodes, environment: environment) }
    }
}

/// The result of an `if` without an `else`.
public struct OptionalView<Content: View>: View {
    public typealias Body = Never
    let content: Content?

    init(_ content: Content?) { self.content = content }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        content?.makeNodes(into: &nodes, environment: environment)
    }
}

/// The result of an `if`/`else` or a `switch`.
public struct ConditionalView<First: View, Second: View>: View {
    public typealias Body = Never
    enum Content {
        case first(First)
        case second(Second)
    }

    let content: Content

    init(first: First) { content = .first(first) }
    init(second: Second) { content = .second(second) }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        switch content {
        case .first(let view): view.makeNodes(into: &nodes, environment: environment)
        case .second(let view): view.makeNodes(into: &nodes, environment: environment)
        }
    }
}

/// The result of a `for` loop in a builder.
public struct ArrayView<Content: View>: View {
    public typealias Body = Never
    let views: [Content]

    init(_ views: [Content]) { self.views = views }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        for view in views { view.makeNodes(into: &nodes, environment: environment) }
    }
}

/// One view for each element of a collection.
public struct ForEach<Data: RandomAccessCollection, Content: View>: View {
    public typealias Body = Never
    let data: Data
    let content: (Data.Element) -> Content

    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        for element in data { content(element).makeNodes(into: &nodes, environment: environment) }
    }
}

/// Views together, so that a modifier applies to all of them.
public struct Group<Content: View>: View {
    public typealias Body = Never
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        content.makeNodes(into: &nodes, environment: environment)
    }
}

/// A view of any type, for a stored or a returned view.
public struct AnyView: View {
    public typealias Body = Never
    let content: any View

    public init(_ content: any View) { self.content = content }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        content.makeNodes(into: &nodes, environment: environment)
    }
}
