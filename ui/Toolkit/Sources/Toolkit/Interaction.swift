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

extension View {
    /// Calls `action` when the pointer goes down and up again over the view.
    ///
    ///     Text("Close").onTapGesture { close() }
    public func onTapGesture(perform action: @escaping () -> Void) -> TapView<Self> {
        TapView(content: self, onPress: { _ in }, onTap: action)
    }

    /// Calls `action` with `true` while the pointer is down over the view,
    /// for a view that must look pressed. It gets `false` when the pointer
    /// goes up or leaves the view.
    public func onPress(perform action: @escaping (Bool) -> Void) -> TapView<Self> {
        TapView(content: self, onPress: action, onTap: {})
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


/// A view that answers a click.
public struct TapView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let onPress: (Bool) -> Void
    let onTap: () -> Void

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        let child = content.node(environment: environment)
        // `.onPress { }.onTapGesture { }` is one view for the pointer, not
        // two. Two places over each other would give the click to the one in
        // front only.
        if let inner = child as? TapNode {
            nodes.append(TapNode(child: inner.child, id: inner.id,
                                 onPress: { inner.onPress($0); onPress($0) },
                                 onTap: { inner.onTap(); onTap() }))
        } else {
            nodes.append(TapNode(child: child,
                                 id: environment.viewState?.interactionIdentity() ?? 0,
                                 onPress: onPress, onTap: onTap))
        }
    }
}

final class TapNode: LayoutNode {
    let child: LayoutNode
    let id: Int
    let onPress: (Bool) -> Void
    let onTap: () -> Void

    init(child: LayoutNode, id: Int, onPress: @escaping (Bool) -> Void,
         onTap: @escaping () -> Void) {
        self.child = child
        self.id = id
        self.onPress = onPress
        self.onTap = onTap
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        child.render(in: frame, into: &pass)
        pass.tapRegions.append(TapRegion(id: id, frame: frame, onPress: onPress, onTap: onTap))
    }
}
