import Render

/// Turns a view into drawing items. The compositor calls this for each frame
/// that has shell UI in it.
public enum ViewRenderer {
    /// Lays out `view` in `rect` and gives the items to draw.
    public static func displayList(for view: some View, in rect: Rect) -> DisplayList {
        var list: DisplayList = []
        render(view, in: rect, into: &list)
        return list
    }

    /// The same, for a list that already has items in it.
    public static func render(_ view: some View, in rect: Rect, into list: inout DisplayList) {
        let frame = Frame(x: Double(rect.x), y: Double(rect.y),
                          width: Double(rect.width), height: Double(rect.height))
        let node = view.node(environment: EnvironmentValues())
        // The root view is offered the whole rectangle. A view that asks for
        // less goes in the middle of it, as a window does with its content.
        let size = node.size(fitting: Proposal(frame.size))
        let offset = Alignment.center.offset(for: size, in: frame.size)
        node.render(in: Frame(origin: (frame.x + offset.x, frame.y + offset.y), size: size),
                    into: &list)
    }

    /// The size that `view` wants for a proposed size. Tests use it, and so
    /// does a window that takes the size of its content.
    public static func size(of view: some View, fitting proposal: Proposal) -> Size {
        view.node(environment: EnvironmentValues()).size(fitting: proposal)
    }
}
