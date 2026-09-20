import Render

// A layout is the rule that puts a set of children in a space. It is the
// same shape as SwiftUI's Layout protocol: the layout proposes a size to
// each child, the child answers with the size that it wants, and the layout
// then places it. The frame that the layout gives can differ from the
// answer, because the layout owns the space and the child does not.
//
// The same protocol serves two kinds of children. A view answers through its
// layout node. A window answers through the Wayland protocol, where
// xdg_toplevel.configure proposes a size and the app commits a buffer. Both
// are "something that answers a proposal", so a layout does not know or care
// which kind it has.

/// One child of a layout: something that answers a proposal with a size, and
/// that the layout then puts somewhere.
public final class LayoutSubview {
    /// A name for the child, so that a layout can tell its children apart
    /// and keep a decision from one frame to the next.
    public let id: AnyHashable
    /// Which children a layout should keep at their size when space runs
    /// short. A larger number means "give this one its space first".
    public let priority: Double
    private let measure: (Proposal) -> Size

    /// Where the layout put this child. It is `nil` until the layout places
    /// it, and a child that the layout never places is not drawn.
    public private(set) var placement: Frame?

    public init(id: AnyHashable = 0, priority: Double = 0,
                measure: @escaping (Proposal) -> Size) {
        self.id = id
        self.priority = priority
        self.measure = measure
    }

    /// Asks the child what size it wants. A dimension of `nil` in the
    /// proposal asks for the child's ideal size in that dimension.
    public func sizeThatFits(_ proposal: Proposal) -> Size {
        measure(proposal)
    }

    /// Puts the child in `frame`.
    public func place(in frame: Frame) {
        placement = frame
    }

    /// Puts the child at a point, with `anchor` saying which part of the
    /// child goes there, at the size that it answers for `proposal`.
    public func place(at x: Double, _ y: Double, anchor: Alignment = .topLeading,
                      proposal: Proposal) {
        let size = sizeThatFits(proposal)
        let offset = anchor.offset(for: size, in: .zero)
        place(in: Frame(origin: (x + offset.x, y + offset.y), size: size))
    }

    /// Forgets the placement, before a layout runs again.
    public func reset() {
        placement = nil
    }
}

/// The children of a layout, in the order that they were written.
public struct LayoutSubviews: RandomAccessCollection {
    private let items: [LayoutSubview]

    public init(_ items: [LayoutSubview]) {
        self.items = items
    }

    public var startIndex: Int { items.startIndex }
    public var endIndex: Int { items.endIndex }
    public subscript(index: Int) -> LayoutSubview { items[index] }
}

/// A rule that sizes and places a set of children.
///
///     struct Row: Layout {
///         func sizeThatFits(proposal: Proposal, subviews: LayoutSubviews) -> Size {
///             ...
///         }
///         func placeSubviews(in bounds: Frame, proposal: Proposal,
///                            subviews: LayoutSubviews) {
///             ...
///         }
///     }
///
/// Use it in a view tree by calling it: `Row { Text("a"); Text("b") }`.
public protocol Layout {
    /// The size that this layout wants for the space that the parent offers.
    func sizeThatFits(proposal: Proposal, subviews: LayoutSubviews) -> Size

    /// Gives every child a frame inside `bounds`. A child that this function
    /// does not place is not drawn.
    func placeSubviews(in bounds: Frame, proposal: Proposal, subviews: LayoutSubviews)
}

extension Layout {
    /// Runs the layout over `subviews` in `bounds` and gives the frames back.
    /// The compositor uses this for windows, where there is no view tree.
    @discardableResult
    public func frames(in bounds: Frame, subviews: LayoutSubviews) -> [Frame?] {
        for subview in subviews { subview.reset() }
        placeSubviews(in: bounds, proposal: Proposal(bounds.size), subviews: subviews)
        return subviews.map(\.placement)
    }

    /// Uses this layout in a view tree.
    public func callAsFunction<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> LayoutView<Self, Content> {
        LayoutView(layout: self, content: content())
    }
}

/// A layout with the views that it arranges.
public struct LayoutView<L: Layout, Content: View>: View {
    public typealias Body = Never
    let layout: L
    let content: Content

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        nodes.append(CustomLayoutNode(layout: layout, children: children))
    }
}

/// A layout that another layout can replace. A person picks the layout of
/// the screen, so the shell keeps one of these and puts a different layout
/// in it.
public struct AnyLayout: Layout {
    private let base: any Layout

    public init(_ base: some Layout) {
        self.base = base
    }

    public func sizeThatFits(proposal: Proposal, subviews: LayoutSubviews) -> Size {
        base.sizeThatFits(proposal: proposal, subviews: subviews)
    }

    public func placeSubviews(in bounds: Frame, proposal: Proposal, subviews: LayoutSubviews) {
        base.placeSubviews(in: bounds, proposal: proposal, subviews: subviews)
    }
}

/// Draws the children of a Layout where the layout puts them.
final class CustomLayoutNode: LayoutNode {
    let layout: any Layout
    let children: [LayoutNode]
    let subviews: LayoutSubviews

    init(layout: any Layout, children: [LayoutNode]) {
        self.layout = layout
        self.children = children
        subviews = LayoutSubviews(children.enumerated().map { index, child in
            LayoutSubview(id: index) { child.size(fitting: $0) }
        })
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        layout.sizeThatFits(proposal: proposal, subviews: subviews)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        layout.frames(in: frame, subviews: subviews)
        for (child, subview) in zip(children, subviews) {
            guard let placement = subview.placement else { continue }
            child.render(in: placement, into: &pass)
        }
    }
}
