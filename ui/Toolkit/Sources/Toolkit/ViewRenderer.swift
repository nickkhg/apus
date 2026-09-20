import Render

/// Turns a view into drawing items. A test uses it directly. A UI on a screen
/// uses `ViewHost`, which also keeps the state and the pointer.
public enum ViewRenderer {
    /// Lays out `view` in `rect` and gives the items to draw.
    public static func displayList(for view: some View, in rect: Rect,
                                   scale: Double = 1) -> DisplayList {
        render(view, in: rect, scale: scale).list
    }

    /// Lays out `view` in `rect`. `state` keeps the `@State` values from one
    /// frame to the next. Without it, each call starts with new values.
    ///
    /// `rect` is in points and `scale` says how many pixels there are to the
    /// point. The layout is the same on every screen; only the items that
    /// come out are in pixels.
    public static func render(_ view: some View, in rect: Rect,
                              state: ViewState? = nil, scale: Double = 1) -> RenderPass {
        let state = state ?? ViewState()
        var environment = EnvironmentValues()
        environment.viewState = state
        environment.scale = scale

        state.beginPass()
        let node = view.node(environment: environment)
        state.endPass()

        var pass = RenderPass()
        pass.scale = scale
        let frame = Frame(x: Double(rect.x), y: Double(rect.y),
                          width: Double(rect.width), height: Double(rect.height))
        // The root view is offered the whole rectangle. A view that asks for
        // less goes in the middle of it, as a window does with its content.
        let size = node.size(fitting: Proposal(frame.size))
        let offset = Alignment.center.offset(for: size, in: frame.size)
        node.render(in: Frame(origin: (frame.x + offset.x, frame.y + offset.y), size: size),
                    into: &pass)
        return pass
    }

    /// The size that `view` wants for a proposed size. Tests use it, and so
    /// does a window that takes the size of its content.
    public static func size(of view: some View, fitting proposal: Proposal,
                            scale: Double = 1) -> Size {
        var environment = EnvironmentValues()
        environment.scale = scale
        return view.node(environment: environment).size(fitting: proposal)
    }
}
