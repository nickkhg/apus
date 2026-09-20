import Render

// The view tree is a value tree that the app rebuilds for each frame. It
// lowers to a tree of layout nodes, and the nodes do the work: each one
// answers what size it wants for a proposed size, then draws itself into a
// frame. This is the same two-step model as SwiftUI (propose a size, get a
// size back), without an incremental dependency graph: a frame is cheap
// enough to lay out completely.

/// One element of a laid-out view tree.
open class LayoutNode {
    private var cache: (proposal: Proposal, size: Size)?

    public init() {}

    /// The size that this node wants, for the space that the parent offers.
    public final func size(fitting proposal: Proposal) -> Size {
        if let cache, cache.proposal == proposal { return cache.size }
        let size = computeSize(fitting: proposal)
        cache = (proposal, size)
        return size
    }

    /// Subclasses answer the parent's proposal here.
    open func computeSize(fitting proposal: Proposal) -> Size {
        .zero
    }

    /// Subclasses add their drawing items here. `frame` is in screen points.
    open func render(in frame: Frame, into pass: inout RenderPass) {}
}

/// A node that draws nothing and takes no space.
final class EmptyNode: LayoutNode {}

/// A rectangle of one colour. A shape or a Color lowers to this.
final class FillNode: LayoutNode {
    let color: Color
    /// The size for an unspecified proposal, as SwiftUI gives shapes 10 × 10.
    private static let idealLength: Double = 10

    init(color: Color) {
        self.color = color
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        Size(width: length(proposal.width), height: length(proposal.height))
    }

    /// No proposal means the ideal size. An infinite proposal is a stack
    /// asking how much this view can grow: a shape has no limit.
    private func length(_ proposed: Double?) -> Double {
        guard let proposed else { return FillNode.idealLength }
        return max(0, proposed)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        guard color.alpha > 0 else { return }
        let rect = frame.pixels(scale: pass.scale)
        guard rect.width > 0, rect.height > 0 else { return }
        pass.list.append(.fill(rect, color: color.premultiplied))
    }
}

/// Empty space that grows. A Spacer lowers to this.
final class SpacerNode: LayoutNode {
    let axis: Axis?
    let minLength: Double

    init(axis: Axis?, minLength: Double) {
        self.axis = axis
        self.minLength = minLength
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        Size(width: length(proposal.width, grows: axis != .vertical),
             height: length(proposal.height, grows: axis != .horizontal))
    }

    private func length(_ proposed: Double?, grows: Bool) -> Double {
        guard grows else { return 0 }
        guard let proposed else { return minLength }
        return max(minLength, proposed)
    }
}

/// A stack: children in a row or in a column.
final class StackNode: LayoutNode {
    let axis: Axis
    let spacing: Double
    let alignment: Alignment
    let children: [LayoutNode]

    init(axis: Axis, spacing: Double, alignment: Alignment, children: [LayoutNode]) {
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
        self.children = children
    }

    private var totalSpacing: Double {
        spacing * Double(max(0, children.count - 1))
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        let sizes = childSizes(fitting: proposal)
        let main = sizes.reduce(0) { $0 + $1.length(axis) } + totalSpacing
        let across = sizes.map { $0.length(axis.other) }.max() ?? 0
        return .along(axis, main, across: across)
    }

    /// Shares the space along the axis between the children. Each child gets
    /// an equal share of what is left, least flexible child first, so that
    /// fixed-size children keep their size and spacers take the remainder.
    private func childSizes(fitting proposal: Proposal) -> [Size] {
        let across = proposal.length(axis.other)
        guard let available = proposal.length(axis), available.isFinite else {
            // No length given: every child gets its ideal length.
            let childProposal = Proposal.unspecified
                .replacing(axis.other, with: across)
            return children.map { $0.size(fitting: childProposal) }
        }

        var sizes = [Size](repeating: .zero, count: children.count)
        var remaining = available - totalSpacing
        var count = children.count
        for index in orderByFlexibility(across: across) {
            let share = count > 0 ? max(0, remaining / Double(count)) : 0
            let size = children[index].size(fitting: Proposal(width: 0, height: 0)
                .replacing(axis, with: share)
                .replacing(axis.other, with: across))
            sizes[index] = size
            remaining -= size.length(axis)
            count -= 1
        }
        return sizes
    }

    /// The children, least flexible first. A child's flexibility is the
    /// difference between its largest and its smallest length.
    private func orderByFlexibility(across: Double?) -> [Int] {
        let smallest = Proposal(width: 0, height: 0).replacing(axis.other, with: across)
        let largest = Proposal(width: .infinity, height: .infinity).replacing(axis.other, with: across)
        let flexibility = children.map { child in
            child.size(fitting: largest).length(axis) - child.size(fitting: smallest).length(axis)
        }
        return children.indices.sorted { left, right in
            flexibility[left] == flexibility[right] ? left < right : flexibility[left] < flexibility[right]
        }
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let sizes = childSizes(fitting: Proposal(frame.size))
        var main = frame.size.length(axis) == 0 ? 0.0 : startOffset(sizes: sizes, in: frame)
        for (child, size) in zip(children, sizes) {
            let across = crossOffset(for: size, in: frame.size)
            let origin: (x: Double, y: Double) = axis == .horizontal
                ? (frame.x + main, frame.y + across)
                : (frame.x + across, frame.y + main)
            child.render(in: Frame(origin: origin, size: size), into: &pass)
            main += size.length(axis) + spacing
        }
    }

    /// The children can be smaller than the stack. Then the whole row or
    /// column sits at the start, the centre or the end.
    private func startOffset(sizes: [Size], in frame: Frame) -> Double {
        let used = sizes.reduce(0) { $0 + $1.length(axis) } + totalSpacing
        let free = max(0, frame.size.length(axis) - used)
        switch axis {
        case .horizontal:
            return switch alignment.horizontal {
            case .leading: 0
            case .center: free / 2
            case .trailing: free
            }
        case .vertical:
            return switch alignment.vertical {
            case .top: 0
            case .center: free / 2
            case .bottom: free
            }
        }
    }

    private func crossOffset(for size: Size, in space: Size) -> Double {
        let free = space.length(axis.other) - size.length(axis.other)
        switch axis {
        case .horizontal:
            return switch alignment.vertical {
            case .top: 0
            case .center: free / 2
            case .bottom: free
            }
        case .vertical:
            return switch alignment.horizontal {
            case .leading: 0
            case .center: free / 2
            case .trailing: free
            }
        }
    }
}

/// Children on top of each other, the first one at the back.
final class ZStackNode: LayoutNode {
    let alignment: Alignment
    let children: [LayoutNode]

    init(alignment: Alignment, children: [LayoutNode]) {
        self.alignment = alignment
        self.children = children
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        let sizes = children.map { $0.size(fitting: proposal) }
        return Size(width: sizes.map(\.width).max() ?? 0,
                    height: sizes.map(\.height).max() ?? 0)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        for child in children {
            let size = child.size(fitting: Proposal(frame.size))
            let offset = alignment.offset(for: size, in: frame.size)
            child.render(in: Frame(origin: (frame.x + offset.x, frame.y + offset.y), size: size),
                         into: &pass)
        }
    }
}

/// A fixed or limited size around a child.
final class FrameNode: LayoutNode {
    let child: LayoutNode
    let width: Double?
    let height: Double?
    let minWidth: Double?
    let minHeight: Double?
    let maxWidth: Double?
    let maxHeight: Double?
    let alignment: Alignment

    init(child: LayoutNode, width: Double? = nil, height: Double? = nil,
         minWidth: Double? = nil, minHeight: Double? = nil,
         maxWidth: Double? = nil, maxHeight: Double? = nil,
         alignment: Alignment = .center) {
        self.child = child
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.alignment = alignment
    }

    private var fixesWidth: Bool { width != nil || minWidth != nil || maxWidth != nil }
    private var fixesHeight: Bool { height != nil || minHeight != nil || maxHeight != nil }

    override func computeSize(fitting proposal: Proposal) -> Size {
        let outer = Size(width: length(width, min: minWidth, max: maxWidth, proposed: proposal.width),
                         height: length(height, min: minHeight, max: maxHeight, proposed: proposal.height))
        // The child gets this frame's length where the frame has one, and the
        // parent's proposal on the other axis.
        let inner = child.size(fitting: Proposal(width: fixesWidth ? outer.width : proposal.width,
                                                 height: fixesHeight ? outer.height : proposal.height))
        return Size(width: fixesWidth ? outer.width : inner.width,
                    height: fixesHeight ? outer.height : inner.height)
    }

    private func length(_ exact: Double?, min minimum: Double?, max maximum: Double?,
                        proposed: Double?) -> Double {
        if let exact { return exact }
        var value = proposed ?? maximum ?? minimum ?? 0
        if let maximum { value = Swift.min(value, maximum) }
        if let minimum { value = Swift.max(value, minimum) }
        return Swift.max(0, value)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        // Usually the parent gives this node the size that it asked for. If
        // the space is larger, the node keeps its size and goes in the middle
        // of it, and the child goes where the alignment says.
        let mine = size(fitting: Proposal(frame.size))
        let space = Alignment.center.offset(for: mine, in: frame.size)
        let inner = child.size(fitting: Proposal(mine))
        let offset = alignment.offset(for: inner, in: mine)
        child.render(in: Frame(origin: (frame.x + space.x + offset.x, frame.y + space.y + offset.y),
                               size: inner),
                     into: &pass)
    }
}

/// Space on the sides of a child.
final class PaddingNode: LayoutNode {
    let child: LayoutNode
    let insets: EdgeInsets

    init(child: LayoutNode, insets: EdgeInsets) {
        self.child = child
        self.insets = insets
    }

    private func inner(_ proposal: Proposal) -> Proposal {
        Proposal(width: proposal.width.map { max(0, $0 - insets.horizontal) },
                 height: proposal.height.map { max(0, $0 - insets.vertical) })
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        let size = child.size(fitting: inner(proposal))
        return Size(width: size.width + insets.horizontal, height: size.height + insets.vertical)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let size = Size(width: max(0, frame.width - insets.horizontal),
                        height: max(0, frame.height - insets.vertical))
        child.render(in: Frame(origin: (frame.x + insets.leading, frame.y + insets.top), size: size),
                     into: &pass)
    }
}

/// A view behind another view. The back view gets the front view's frame.
final class BackgroundNode: LayoutNode {
    let child: LayoutNode
    let background: LayoutNode

    init(child: LayoutNode, background: LayoutNode) {
        self.child = child
        self.background = background
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        background.render(in: frame, into: &pass)
        child.render(in: frame, into: &pass)
    }
}

/// A fixed offset. The child keeps its size.
final class OffsetNode: LayoutNode {
    let child: LayoutNode
    let dx: Double
    let dy: Double

    init(child: LayoutNode, dx: Double, dy: Double) {
        self.child = child
        self.dx = dx
        self.dy = dy
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        child.render(in: Frame(x: frame.x + dx, y: frame.y + dy, width: frame.width, height: frame.height),
                     into: &pass)
    }
}

/// Cuts a child to its frame. The renderer draws nothing outside it, and a
/// view that the clip hides does not answer the pointer either.
final class ClipNode: LayoutNode {
    let child: LayoutNode

    init(child: LayoutNode) {
        self.child = child
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        let rect = frame.pixels(scale: pass.scale)
        guard rect.width > 0, rect.height > 0 else { return }
        // The regions that the child adds are cut to the same frame, so a
        // button that the clip hides cannot be hovered or clicked.
        let hovers = pass.hoverRegions.count
        let taps = pass.tapRegions.count

        pass.list.append(.pushClip(rect))
        child.render(in: frame, into: &pass)
        pass.list.append(.popClip)

        for index in hovers..<pass.hoverRegions.count {
            pass.hoverRegions[index].frame = pass.hoverRegions[index].frame.intersection(frame)
        }
        for index in taps..<pass.tapRegions.count {
            pass.tapRegions[index].frame = pass.tapRegions[index].frame.intersection(frame)
        }
    }
}


/// Draws one view over another. The child says how big the pair is, and the
/// view above gets the same frame.
final class OverlayNode: LayoutNode {
    let child: LayoutNode
    let over: LayoutNode

    init(child: LayoutNode, over: LayoutNode) {
        self.child = child
        self.over = over
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        child.render(in: frame, into: &pass)
        over.render(in: frame, into: &pass)
    }
}
