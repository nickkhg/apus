import Render

/// A view tree on a screen: it keeps the `@State` values from one frame to
/// the next, draws a frame when asked, and sends the pointer to the views
/// that watch it.
///
/// The compositor makes one host for the shell:
///
///     host.needsUpdate = { screen.setNeedsFrame() }
///     let items = host.displayList(for: RootView(state: shell), in: screenRect)
///     host.pointerMoved(to: x, y: y)
public final class ViewHost {
    /// Called when the UI must be drawn again, because a `@State` value
    /// changed or because the pointer entered or left a view.
    public var needsUpdate: () -> Void = {}

    private let state = ViewState()
    private var hoverRegions: [HoverRegion] = []
    private var hovered: Set<Int> = []
    private var pointer: (x: Double, y: Double)?
    /// True while the handlers of the views run. The compositor draws at
    /// once when something asks for a frame, so a handler can bring the
    /// program back here. Then it must not start again.
    private var isUpdatingHover = false
    /// A handler asked for a frame. One frame is enough for all of them.
    private var missedUpdate = false

    public init() {
        state.needsUpdate = { [unowned self] in requestUpdate() }
    }

    private func requestUpdate() {
        if isUpdatingHover {
            missedUpdate = true
        } else {
            needsUpdate()
        }
    }

    /// Lays out `view` and gives the items to draw. It also collects the
    /// views that watch the pointer.
    public func displayList(for view: some View, in rect: Rect) -> DisplayList {
        let pass = ViewRenderer.render(view, in: rect, state: state)
        hoverRegions = pass.hoverRegions
        // The frames moved, so the pointer can now be over other views.
        if let pointer { updateHover(at: pointer, redrawOnChange: false) }
        return pass.list
    }

    /// The compositor calls this when the pointer moves.
    public func pointerMoved(to x: Double, y: Double) {
        pointer = (x, y)
        updateHover(at: (x, y), redrawOnChange: true)
    }

    /// The pointer left the screen or another program took it.
    public func pointerLeft() {
        pointer = nil
        guard !hovered.isEmpty, !isUpdatingHover else { return }
        let before = hovered
        hovered.removeAll()
        isUpdatingHover = true
        for region in hoverRegions where before.contains(region.id) { region.action(false) }
        isUpdatingHover = false
        if missedUpdate {
            missedUpdate = false
            needsUpdate()
        }
    }

    /// Calls the handler of each view that the pointer entered or left. A
    /// view that keeps its state does not hear anything.
    ///
    /// The new set of views is stored before the handlers run. A handler
    /// that asks for a frame brings the program back into this class, and it
    /// must see the result, not the question again.
    private func updateHover(at point: (x: Double, y: Double), redrawOnChange: Bool) {
        guard !isUpdatingHover else { return }
        var inside: Set<Int> = []
        for region in hoverRegions where region.contains(x: point.x, y: point.y) {
            inside.insert(region.id)
        }
        guard inside != hovered else { return }
        let before = hovered
        hovered = inside

        isUpdatingHover = true
        for region in hoverRegions {
            let isInside = inside.contains(region.id)
            guard isInside != before.contains(region.id) else { continue }
            region.action(isInside)
        }
        isUpdatingHover = false

        if missedUpdate || redrawOnChange {
            missedUpdate = false
            needsUpdate()
        }
    }
}
