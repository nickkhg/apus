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
///     host.pointerButton(pressed: true)
public final class ViewHost {
    /// Called when the UI must be drawn again, because a `@State` value
    /// changed, because the pointer entered or left a view, or because
    /// something is still moving.
    public var needsUpdate: () -> Void = {}

    /// The time of the next frame, in seconds. The owner sets it before it
    /// draws, from the clock of the system. Tests set it by hand.
    public var now: Double = 0

    private let state = ViewState()
    private var hoverRegions: [HoverRegion] = []
    private var tapRegions: [TapRegion] = []
    private var keyRegions: [KeyRegion] = []
    private var hovered: Set<Int> = []
    private var pointer: (x: Double, y: Double)?
    /// The view that the pointer went down on, and whether the pointer is
    /// still over it.
    private var pressed: (id: Int, isInside: Bool)?

    /// True while the handlers of the views run. The compositor draws at
    /// once when something asks for a frame, so a handler can bring the
    /// program back here. Then it must not start again.
    private var isSendingEvents = false
    /// A handler asked for a frame. One frame is enough for all of them.
    private var missedUpdate = false

    public init() {
        state.needsUpdate = { [unowned self] in requestUpdate() }
    }

    /// Lays out `view` and gives the items to draw. It also collects the
    /// views that watch the pointer.
    /// `rect` is in points, and `scale` says how many pixels there are to a
    /// point. The pointer positions that this host takes are in points too.
    public func displayList(for view: some View, in rect: Rect, scale: Double = 1) -> DisplayList {
        let pass = ViewRenderer.render(view, in: rect, state: state, scale: scale, now: now)
        hoverRegions = pass.hoverRegions
        tapRegions = pass.tapRegions
        keyRegions = pass.keyRegions
        // A move that has not arrived needs the next frame to carry it on.
        if state.isMoving { requestUpdate() }
        // The frames moved, so the pointer can now be over other views.
        if let pointer { updateHover(at: pointer) }
        return pass.list
    }

    // MARK: - The pointer

    /// The compositor calls this when the pointer moves.
    public func pointerMoved(to x: Double, y: Double) {
        pointer = (x, y)
        updateHover(at: (x, y))
        updatePressed(at: (x, y))
    }

    /// The compositor calls this when a pointer button goes down or up.
    /// Only the first button counts.
    public func pointerButton(pressed isDown: Bool) {
        guard let pointer else { return }
        if isDown {
            press(at: pointer)
        } else {
            release(at: pointer)
        }
    }

    /// The pointer left the screen or another program took it.
    /// Gives a key to the view in front that wants it. It answers whether a
    /// view used the key; a key that none used belongs to whatever is under
    /// the toolkit.
    @discardableResult
    public func key(_ event: KeyEvent) -> Bool {
        var used = false
        send {
            for region in keyRegions.reversed() {
                if region.handler(event) {
                    used = true
                    break
                }
            }
        }
        return used
    }

    public func pointerLeft() {
        pointer = nil
        send {
            for region in tapRegions where pressed?.id == region.id { region.onPress(false) }
            pressed = nil
            let before = hovered
            hovered.removeAll()
            for region in hoverRegions where before.contains(region.id) { region.action(false) }
        }
    }

    // MARK: - Hovering

    /// Calls the handler of each view that the pointer entered or left. A
    /// view that keeps its state does not hear anything.
    private func updateHover(at point: (x: Double, y: Double)) {
        guard !isSendingEvents else { return }
        var inside: Set<Int> = []
        for region in hoverRegions where region.contains(x: point.x, y: point.y) {
            inside.insert(region.id)
        }
        guard inside != hovered else { return }
        // The new set is stored before the handlers run: a handler that asks
        // for a frame brings the program back here, and it must see the
        // result, not the question again.
        let before = hovered
        hovered = inside
        send {
            for region in hoverRegions {
                let isInside = inside.contains(region.id)
                guard isInside != before.contains(region.id) else { continue }
                region.action(isInside)
            }
        }
    }

    // MARK: - Clicking

    /// The view in front of the others at this place. The renderer draws
    /// from back to front, so the last region is the one on top.
    private func topmost(at point: (x: Double, y: Double)) -> TapRegion? {
        tapRegions.last { $0.contains(x: point.x, y: point.y) }
    }

    private func press(at point: (x: Double, y: Double)) {
        guard pressed == nil, let region = topmost(at: point) else { return }
        pressed = (region.id, true)
        send { region.onPress(true) }
    }

    /// A view looks pressed only while the pointer is over it.
    private func updatePressed(at point: (x: Double, y: Double)) {
        guard let pressed, let region = tapRegions.first(where: { $0.id == pressed.id }) else { return }
        let isInside = region.contains(x: point.x, y: point.y)
        guard isInside != pressed.isInside else { return }
        self.pressed = (pressed.id, isInside)
        send { region.onPress(isInside) }
    }

    /// The button goes up. The view gets the click when the pointer is still
    /// over the view that it went down on. A view that already stopped
    /// looking pressed, because the pointer left it, hears nothing more.
    private func release(at point: (x: Double, y: Double)) {
        guard let pressed else { return }
        self.pressed = nil
        guard pressed.isInside,
              let region = tapRegions.first(where: { $0.id == pressed.id }) else { return }
        send {
            region.onPress(false)
            region.onTap()
        }
    }

    // MARK: - Frames

    private func requestUpdate() {
        if isSendingEvents {
            missedUpdate = true
        } else {
            needsUpdate()
        }
    }

    /// Runs the handlers of the views. A handler that asks for a frame gets
    /// one frame after all the handlers, and it cannot start this again.
    private func send(_ handlers: () -> Void) {
        guard !isSendingEvents else { return }
        isSendingEvents = true
        handlers()
        isSendingEvents = false
        if missedUpdate {
            missedUpdate = false
            needsUpdate()
        }
    }
}
