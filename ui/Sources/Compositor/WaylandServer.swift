import Wayland

// The Wayland side of the compositor: the objects apps talk to.
//
// Supported so far:
//   wl_compositor  surfaces (and regions, which are ignored)
//   wl_shm         shared-memory buffers (the Wayland module implements it)
//   xdg_wm_base    toplevel windows (no popups yet)
//
// The Swift object for a protocol object is the `data` of its resource, so it
// lives as long as the resource. Back references to resources are weak.

/// A surface: a rectangle of pixels that an app draws into.
final class Surface {
    /// What the app last committed.
    private(set) var content: Bitmap?
    /// Set once the app committed a buffer after its first configure.
    var isMapped = false
    fileprivate(set) var toplevel: Toplevel?

    fileprivate enum PendingBuffer {
        case unchanged
        case attached(Resource<WlBuffer>?)
    }
    fileprivate var pendingBuffer = PendingBuffer.unchanged
    fileprivate var pendingFrameCallbacks: [Resource<WlCallback>] = []
    private var frameCallbacks: [Resource<WlCallback>] = []

    /// Makes the pending state current (wl_surface.commit).
    fileprivate func applyPendingState() {
        if case .attached(let buffer) = pendingBuffer {
            pendingBuffer = .unchanged
            // A buffer destroyed before the commit counts as no buffer.
            if let buffer, !buffer.isDestroyed {
                copyContent(of: buffer)
            } else {
                content = nil   // no buffer hides the surface
            }
        }
        frameCallbacks += pendingFrameCallbacks
        pendingFrameCallbacks.removeAll()
    }

    /// Copies the buffer's pixels, then gives the buffer back to the app.
    private func copyContent(of buffer: Resource<WlBuffer>) {
        guard let shm = buffer.data as? ShmBuffer else {
            return buffer.postError(code: DisplayErrorCode.invalidObject, "only wl_shm buffers are supported")
        }
        guard let pixels = shm.copyPixels() else {
            return buffer.postError(code: WlShm.ErrorCode.invalidFd.rawValue, "the shm pool became smaller")
        }
        buffer.sendRelease()
        content = Bitmap(width: shm.width, height: shm.height, isOpaque: !shm.hasAlpha, pixels: pixels)
    }

    /// Tells the app a frame with its content was shown: time to draw the next.
    func sendFrameDone(time: UInt32) {
        let callbacks = frameCallbacks
        frameCallbacks.removeAll()
        for callback in callbacks {
            callback.sendDone(callbackData: time)
            callback.destroy()
        }
    }
}

/// An xdg_surface with the toplevel role: an app window.
final class Toplevel {
    weak var xdgSurface: Resource<XdgSurface>?
    weak var resource: Resource<XdgToplevel>?
    unowned let surface: Surface
    var title = ""
    var appID = ""
    fileprivate var configured = false

    init(xdgSurface: Resource<XdgSurface>, resource: Resource<XdgToplevel>, surface: Surface) {
        (self.xdgSurface, self.resource, self.surface) = (xdgSurface, resource, surface)
    }
}

final class WaylandServer {
    let display: Display
    private let shm: Shm
    var socketName: String { display.socketName }

    /// A toplevel's surface got new content (or was mapped for the first time).
    var surfaceCommitted: (Surface) -> Void = { _ in }
    /// A surface went away.
    var surfaceDestroyed: (Surface) -> Void = { _ in }

    init(loop: EventLoop) throws(Display.Failure) {
        display = try Display(loop: loop)
        shm = Shm(display: display)
        display.addGlobal(WlCompositor.self, version: 6) { [unowned self] compositor in
            compositor.onRequest = { [unowned self, unowned compositor] request in
                handle(request, of: compositor)
            }
        }
        display.addGlobal(XdgWmBase.self, version: 6) { [unowned self] wmBase in
            wmBase.onRequest = { [unowned self, unowned wmBase] request in
                handle(request, of: wmBase)
            }
        }
    }

    /// Sends queued events to clients. Call before waiting for new events.
    func flush() { display.flushClients() }

    // MARK: - wl_compositor and wl_surface

    private func handle(_ request: WlCompositor.Request, of compositor: Resource<WlCompositor>) {
        switch request {
        case .createSurface(let id):
            let resource = compositor.create(id)
            let surface = Surface()
            resource.data = surface
            resource.onRequest = { [unowned self, unowned resource, unowned surface] request in
                handle(request, of: resource, surface: surface)
            }
            resource.onDestroy { [unowned self, unowned surface] in surfaceDestroyed(surface) }
        case .createRegion(let id):
            // Regions only optimise drawing and input: accepted and ignored.
            _ = compositor.create(id)
        case .release:
            break
        }
    }

    private func handle(_ request: WlSurface.Request, of resource: Resource<WlSurface>, surface: Surface) {
        switch request {
        case .attach(let buffer, _, _):
            surface.pendingBuffer = .attached(buffer)
        case .frame(let id):
            surface.pendingFrameCallbacks.append(resource.create(id))
        case .commit:
            commit(surface)
        case .getRelease(let id):
            _ = resource.create(id)   // wl_surface 7; we advertise 6
        case .destroy, .damage, .damageBuffer, .setOpaqueRegion, .setInputRegion,
             .setBufferTransform, .setBufferScale, .offset:
            break   // every frame is drawn in full, at scale 1, for now
        }
    }

    private func commit(_ surface: Surface) {
        surface.applyPendingState()
        guard let toplevel = surface.toplevel else { return }
        if !toplevel.configured {
            // The first commit asks for a configure: we let the app pick its size.
            toplevel.resource?.sendConfigure(width: 0, height: 0, states: [])
            toplevel.xdgSurface?.sendConfigure(serial: display.nextSerial())
            toplevel.configured = true
            return
        }
        if surface.content != nil { surface.isMapped = true }
        surfaceCommitted(surface)
    }

    // MARK: - xdg_wm_base, xdg_surface, xdg_toplevel

    private func handle(_ request: XdgWmBase.Request, of wmBase: Resource<XdgWmBase>) {
        switch request {
        case .createPositioner(let id):
            // Positioners place popups, which aren't supported yet.
            _ = wmBase.create(id)
        case .getXdgSurface(let id, let surfaceResource):
            let resource = wmBase.create(id)
            guard let surface = surfaceResource.data as? Surface else { return }
            resource.onRequest = { [unowned self, unowned resource, weak surface] request in
                guard let surface else { return }
                handle(request, of: resource, surface: surface)
            }
        case .destroy, .pong:
            break
        }
    }

    private func handle(_ request: XdgSurface.Request, of xdgSurface: Resource<XdgSurface>, surface: Surface) {
        switch request {
        case .getToplevel(let id):
            let resource = xdgSurface.create(id)
            let toplevel = Toplevel(xdgSurface: xdgSurface, resource: resource, surface: surface)
            surface.toplevel = toplevel
            resource.data = toplevel
            resource.onRequest = { [unowned toplevel] request in
                switch request {
                case .setTitle(let title): toplevel.title = title
                case .setAppId(let appID): toplevel.appID = appID
                default: break
                }
            }
            resource.onDestroy { [unowned self, weak surface] in
                guard let surface else { return }
                surface.toplevel = nil
                surface.isMapped = false
                surfaceDestroyed(surface)
            }
        case .getPopup(let id, _, _):
            _ = xdgSurface.create(id)
            xdgSurface.postError(code: DisplayErrorCode.implementation, "popups are not supported yet")
        case .destroy, .setWindowGeometry, .ackConfigure:
            break
        }
    }
}
