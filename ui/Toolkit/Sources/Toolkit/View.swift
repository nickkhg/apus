import Render

// A declarative user interface layer, in the shape of SwiftUI: a view is a
// value, and its `body` describes what it contains. A view tree lowers to
// layout nodes, and the nodes lay out and draw themselves.
//
// A dependency graph holds what each view made (see Graph.swift). A body
// runs again only when the view value, the environment or a `@State` value
// that it read changed. A frame that changes one control therefore lowers
// that control, and keeps the rest of the tree as it is.

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
        guard let state = environment.viewState else {
            body.makeNodes(into: &nodes, environment: environment)
            return
        }
        // The position of this view in the tree is the name of its @State
        // values, and of what it made. See State.swift.
        state.enter(Self.self)
        defer { state.leave() }
        // The body runs only when something that it depends on changed. A
        // view that is the same value in the same place keeps the nodes
        // that it made before, and everything that hangs off them.
        nodes += state.nodes(for: self, environment: environment) { view, environment in
            state.connect(view, environment: environment)
            var made: [LayoutNode] = []
            view.body.makeNodes(into: &made, environment: environment)
            return made
        }
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
        // Each branch is a different place, so the two branches do not share
        // the state of the views in them.
        switch content {
        case .first(let view):
            environment.viewState?.enter(identity: 0)
            view.makeNodes(into: &nodes, environment: environment)
            environment.viewState?.leave()
        case .second(let view):
            environment.viewState?.enter(identity: 1)
            view.makeNodes(into: &nodes, environment: environment)
            environment.viewState?.leave()
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
///
/// The identity of an element says which views belong to it. Thus the state
/// of a row follows its element when the elements change order:
///
///     ForEach(apps, id: \.name) { app in AppIcon(app) }
///     ForEach(apps) { app in AppIcon(app) }          // apps are Identifiable
///     ForEach(0..<4) { index in Dot(index) }         // the number is the id
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public typealias Body = Never
    let data: Data
    let identity: (Data.Element) -> ID
    let content: (Data.Element) -> Content

    public init(_ data: Data, id: KeyPath<Data.Element, ID>,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.identity = { $0[keyPath: id] }
        self.content = content
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        for element in data {
            environment.viewState?.enter(identity: identity(element).hashValue)
            content(element).makeNodes(into: &nodes, environment: environment)
            environment.viewState?.leave()
        }
    }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    /// For elements that say what their identity is.
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: \.id, content: content)
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    /// For a range of numbers. The number is the identity.
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.init(data, id: \.self, content: content)
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
