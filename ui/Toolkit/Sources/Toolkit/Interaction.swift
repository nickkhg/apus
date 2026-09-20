import Render

extension View {
    /// Calls `action` when the pointer comes over the view, and again when it
    /// leaves. `ViewHost` sends the pointer, so this works in the compositor.
    ///
    ///     @State private var isHovered = false
    ///     ...
    ///     RoundedRectangle(cornerRadius: 6)
    ///         .fill(isHovered ? .accent : .gray)
    ///         .onHover { isHovered = $0 }
    ///
    /// A view under another view also hears the pointer: the toolkit has no
    /// window order inside a view tree.
    public func onHover(perform action: @escaping (Bool) -> Void) -> HoverView<Self> {
        HoverView(content: self, action: action)
    }
}

/// A view that watches the pointer.
public struct HoverView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let action: (Bool) -> Void

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(HoverNode(child: content.node(environment: environment),
                               id: environment.viewState?.interactionIdentity() ?? 0,
                               action: action))
    }
}

final class HoverNode: LayoutNode {
    let child: LayoutNode
    let id: Int
    let action: (Bool) -> Void

    init(child: LayoutNode, id: Int, action: @escaping (Bool) -> Void) {
        self.child = child
        self.id = id
        self.action = action
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        child.render(in: frame, into: &pass)
        pass.hoverRegions.append(HoverRegion(id: id, frame: frame, action: action))
    }
}
