import CWaylandServer
import CXDGShellServer
import Glibc

// The Wayland side of the compositor: the objects apps talk to.
//
// Supported so far:
//   wl_compositor  surfaces (and regions, which are ignored)
//   wl_shm         shared-memory buffers (libwayland implements this)
//   xdg_wm_base    toplevel windows (no popups yet)
//
// Every protocol object ("resource") has the WaylandServer as its user data.
// Swift objects are kept in dictionaries keyed by their resource, and are
// removed when libwayland destroys the resource (the client asked, or it
// disconnected).

/// A protocol object. (libwayland's headers define struct wl_resource, so
/// Swift sees a typed pointer; clients and the display are opaque.)
typealias Resource = UnsafeMutablePointer<wl_resource>

/// A surface: a rectangle of pixels that an app draws into.
final class Surface {
    let resource: Resource
    /// What the app last committed.
    private(set) var content: Bitmap?
    /// Set once the app committed a buffer after its first configure.
    var isMapped = false

    fileprivate var pendingBuffer: Resource?
    fileprivate var hasPendingBuffer = false
    fileprivate var pendingBufferListener: ResourceDestroyListener?
    fileprivate var pendingFrameCallbacks: [Resource] = []
    fileprivate var frameCallbacks: [Resource] = []

    fileprivate(set) var toplevel: Toplevel?

    init(resource: Resource) { self.resource = resource }

    /// Copies the pending buffer's pixels, then gives the buffer back.
    fileprivate func applyPendingBuffer() {
        defer {
            pendingBuffer = nil
            hasPendingBuffer = false
            pendingBufferListener = nil
        }
        guard let buffer = pendingBuffer else {
            content = nil   // attaching no buffer hides the surface
            return
        }
        guard let shm = wl_shm_buffer_get(buffer) else {
            log("wayland: only wl_shm buffers are supported")
            return
        }
        let width = Int(wl_shm_buffer_get_width(shm)), height = Int(wl_shm_buffer_get_height(shm))
        let stride = Int(wl_shm_buffer_get_stride(shm))
        let format = wl_shm_buffer_get_format(shm)
        var pixels = [UInt32](repeating: 0, count: width * height)
        wl_shm_buffer_begin_access(shm)
        if let data = wl_shm_buffer_get_data(shm) {
            pixels.withUnsafeMutableBufferPointer { destination in
                for row in 0..<height {
                    let source = (data + row * stride).assumingMemoryBound(to: UInt32.self)
                    (destination.baseAddress! + row * width).update(from: source, count: width)
                }
            }
        }
        wl_shm_buffer_end_access(shm)
        wl_buffer_send_release(buffer)
        content = Bitmap(width: width, height: height,
                         isOpaque: format != WL_SHM_FORMAT_ARGB8888.rawValue, pixels: pixels)
    }

    /// Tells the app a frame with its content was shown: time to draw the next.
    func sendFrameDone(time: UInt32) {
        let callbacks = frameCallbacks
        frameCallbacks.removeAll()
        for callback in callbacks {
            wl_callback_send_done(callback, time)
            wl_resource_destroy(callback)
        }
    }
}

/// An xdg_surface with the toplevel role: an app window.
final class Toplevel {
    let xdgSurface: Resource
    let resource: Resource
    unowned let surface: Surface
    var title = ""
    var appID = ""
    fileprivate var configured = false

    init(xdgSurface: Resource, resource: Resource, surface: Surface) {
        (self.xdgSurface, self.resource, self.surface) = (xdgSurface, resource, surface)
    }
}

/// Runs an action when a resource is destroyed (wl_resource_add_destroy_listener).
final class ResourceDestroyListener {
    private let storage: UnsafeMutablePointer<swift_wl_listener>
    private let action: () -> Void
    private var fired = false

    init(_ resource: Resource, _ action: @escaping () -> Void) {
        self.action = action
        storage = .allocate(capacity: 1)
        storage.initialize(to: swift_wl_listener(
            listener: wl_listener(link: wl_list(), notify: { listener, _ in
                let box = UnsafeMutableRawPointer(listener!).assumingMemoryBound(to: swift_wl_listener.self)
                let owner = Unmanaged<ResourceDestroyListener>.fromOpaque(box.pointee.context!).takeUnretainedValue()
                owner.fired = true
                owner.action()
            }),
            context: nil
        ))
        storage.pointee.context = Unmanaged.passUnretained(self).toOpaque()
        wl_resource_add_destroy_listener(resource, &storage.pointee.listener)
    }

    deinit {
        if !fired { wl_list_remove(&storage.pointee.listener.link) }
        storage.deallocate()
    }
}

final class WaylandServer {
    let display: OpaquePointer
    private(set) var socketName = ""

    /// A toplevel's surface got new content (or was mapped for the first time).
    var surfaceCommitted: (Surface) -> Void = { _ in }
    /// A surface went away.
    var surfaceDestroyed: (Surface) -> Void = { _ in }

    private var surfaces: [Resource: Surface] = [:]
    private var xdgSurfaces: [Resource: Surface] = [:]
    private var toplevels: [Resource: Toplevel] = [:]

    enum Failure: Error { case display, socket }

    init() throws(Failure) {
        guard let display = wl_display_create() else { throw .display }
        self.display = display
        guard let socket = wl_display_add_socket_auto(display) else { throw .socket }
        socketName = String(cString: socket)
        wl_display_init_shm(display)

        let me = Unmanaged.passUnretained(self).toOpaque()
        wl_global_create(display, wl_compositor_interface_ptr(), 6, me) { client, data, version, id in
            WaylandServer.bind(client, data, version, id, wl_compositor_interface_ptr(), WaylandServer.compositorRequests)
        }
        wl_global_create(display, xdg_wm_base_interface_ptr(), 6, me) { client, data, version, id in
            WaylandServer.bind(client, data, version, id, xdg_wm_base_interface_ptr(), WaylandServer.wmBaseRequests)
        }
    }

    deinit {
        wl_display_destroy_clients(display)
        wl_display_destroy(display)
    }

    var eventLoop: OpaquePointer { wl_display_get_event_loop(display) }

    /// Sends queued events to clients. Call before waiting for new events.
    func flush() { wl_display_flush_clients(display) }

    // MARK: - Helpers

    private static func server(_ resource: Resource?) -> WaylandServer {
        Unmanaged<WaylandServer>.fromOpaque(wl_resource_get_user_data(resource)!).takeUnretainedValue()
    }

    private static func bind<Requests>(_ client: OpaquePointer?, _ data: UnsafeMutableRawPointer?,
                                       _ version: UInt32, _ id: UInt32,
                                       _ interface: UnsafePointer<wl_interface>?,
                                       _ requests: UnsafeMutablePointer<Requests>) {
        guard let resource = wl_resource_create(client, interface, Int32(version), id) else {
            wl_client_post_no_memory(client)
            return
        }
        wl_resource_set_implementation(resource, requests, data, nil)
    }

    /// Creates a resource of the same version as `parent`, owned by this server.
    private static func makeResource<Requests>(_ client: OpaquePointer?, parent: Resource?, id: UInt32,
                                               _ interface: UnsafePointer<wl_interface>?,
                                               _ requests: UnsafeMutablePointer<Requests>?,
                                               destroyed: wl_resource_destroy_func_t?) -> Resource? {
        guard let resource = wl_resource_create(client, interface, wl_resource_get_version(parent), id) else {
            wl_client_post_no_memory(client)
            return nil
        }
        wl_resource_set_implementation(resource, requests, wl_resource_get_user_data(parent), destroyed)
        return resource
    }

    private static let destroyResource: @convention(c) (OpaquePointer?, Resource?) -> Void = { _, resource in
        wl_resource_destroy(resource)
    }

    // MARK: - wl_compositor

    nonisolated(unsafe) private static let compositorRequests = permanent(wl_compositor_requests(
        create_surface: { client, compositor, id in
            guard let resource = makeResource(client, parent: compositor, id: id, wl_surface_interface_ptr(),
                                              surfaceRequests, destroyed: { resource in
                let server = WaylandServer.server(resource)
                if let surface = server.surfaces.removeValue(forKey: resource!) {
                    server.surfaceDestroyed(surface)
                }
            }) else { return }
            server(compositor).surfaces[resource] = Surface(resource: resource)
        },
        create_region: { client, compositor, id in
            // Regions only optimise drawing and input; they're accepted and ignored.
            _ = makeResource(client, parent: compositor, id: id, wl_region_interface_ptr(),
                             regionRequests, destroyed: nil)
        },
        release: destroyResource
    ))

    nonisolated(unsafe) private static let regionRequests = permanent(wl_region_requests(
        destroy: destroyResource,
        add: { _, _, _, _, _, _ in },
        subtract: { _, _, _, _, _, _ in }
    ))

    // MARK: - wl_surface

    nonisolated(unsafe) private static let surfaceRequests = permanent(wl_surface_requests(
        destroy: destroyResource,
        attach: { _, resource, buffer, _, _ in
            guard let surface = server(resource).surfaces[resource!] else { return }
            surface.pendingBuffer = buffer
            surface.hasPendingBuffer = true
            // If the app destroys the buffer before committing, forget it.
            surface.pendingBufferListener = buffer.map { buffer in
                ResourceDestroyListener(buffer) { [unowned surface] in
                    surface.pendingBuffer = nil
                    surface.pendingBufferListener = nil
                }
            }
        },
        damage: { _, _, _, _, _, _ in },   // every frame is redrawn in full, for now
        frame: { client, resource, id in
            guard let surface = server(resource).surfaces[resource!],
                  let callback = wl_resource_create(client, wl_callback_interface_ptr(), 1, id) else { return }
            wl_resource_set_implementation(callback, nil, wl_resource_get_user_data(resource)) { callback in
                // The client went away before the callback was used.
                let server = WaylandServer.server(callback)
                for surface in server.surfaces.values {
                    surface.pendingFrameCallbacks.removeAll { $0 == callback }
                    surface.frameCallbacks.removeAll { $0 == callback }
                }
            }
            surface.pendingFrameCallbacks.append(callback)
        },
        set_opaque_region: { _, _, _ in },
        set_input_region: { _, _, _ in },
        commit: { _, resource in
            let server = WaylandServer.server(resource)
            guard let surface = server.surfaces[resource!] else { return }
            server.commit(surface)
        },
        set_buffer_transform: { _, _, _ in },
        set_buffer_scale: { _, _, _ in },
        damage_buffer: { _, _, _, _, _, _ in },
        offset: { _, _, _, _ in },
        get_release: { _, _, _ in }   // wl_surface v7; we advertise v6
    ))

    private func commit(_ surface: Surface) {
        if surface.hasPendingBuffer { surface.applyPendingBuffer() }
        surface.frameCallbacks += surface.pendingFrameCallbacks
        surface.pendingFrameCallbacks.removeAll()

        guard let toplevel = surface.toplevel else { return }
        if !toplevel.configured {
            // The first commit asks for a configure: we let the app pick its size.
            var states = wl_array()
            wl_array_init(&states)
            xdg_toplevel_send_configure(toplevel.resource, 0, 0, &states)
            wl_array_release(&states)
            xdg_surface_send_configure(toplevel.xdgSurface, wl_display_next_serial(display))
            toplevel.configured = true
            return
        }
        if surface.content != nil { surface.isMapped = true }
        surfaceCommitted(surface)
    }

    // MARK: - xdg_wm_base, xdg_surface, xdg_toplevel

    nonisolated(unsafe) private static let wmBaseRequests = permanent(xdg_wm_base_requests(
        destroy: destroyResource,
        create_positioner: { client, wmBase, id in
            // Positioners place popups, which aren't supported yet.
            _ = makeResource(client, parent: wmBase, id: id, xdg_positioner_interface_ptr(),
                             positionerRequests, destroyed: nil)
        },
        get_xdg_surface: { client, wmBase, id, surfaceResource in
            let server = WaylandServer.server(wmBase)
            guard let surface = server.surfaces[surfaceResource!],
                  let resource = makeResource(client, parent: wmBase, id: id, xdg_surface_interface_ptr(),
                                              xdgSurfaceRequests, destroyed: { resource in
                                                  WaylandServer.server(resource).xdgSurfaces[resource!] = nil
                                              }) else { return }
            server.xdgSurfaces[resource] = surface
        },
        pong: { _, _, _ in }
    ))

    nonisolated(unsafe) private static let xdgSurfaceRequests = permanent(xdg_surface_requests(
        destroy: destroyResource,
        get_toplevel: { client, xdgSurface, id in
            let server = WaylandServer.server(xdgSurface)
            guard let surface = server.xdgSurfaces[xdgSurface!],
                  let resource = makeResource(client, parent: xdgSurface, id: id, xdg_toplevel_interface_ptr(),
                                              toplevelRequests, destroyed: { resource in
                                                  let server = WaylandServer.server(resource)
                                                  if let toplevel = server.toplevels.removeValue(forKey: resource!) {
                                                      toplevel.surface.toplevel = nil
                                                      toplevel.surface.isMapped = false
                                                      server.surfaceDestroyed(toplevel.surface)
                                                  }
                                              }) else { return }
            let toplevel = Toplevel(xdgSurface: xdgSurface!, resource: resource, surface: surface)
            surface.toplevel = toplevel
            server.toplevels[resource] = toplevel
        },
        get_popup: { _, xdgSurface, _, _, _ in
            wl_resource_post_error_message(xdgSurface, 0, "popups are not supported yet")
        },
        set_window_geometry: { _, _, _, _, _, _ in },
        ack_configure: { _, _, _ in }
    ))

    nonisolated(unsafe) private static let toplevelRequests = permanent(xdg_toplevel_requests(
        destroy: destroyResource,
        set_parent: { _, _, _ in },
        set_title: { _, resource, title in
            server(resource).toplevels[resource!]?.title = String(cString: title!)
        },
        set_app_id: { _, resource, appID in
            server(resource).toplevels[resource!]?.appID = String(cString: appID!)
        },
        show_window_menu: { _, _, _, _, _, _ in },
        move: { _, _, _, _ in },
        resize: { _, _, _, _, _ in },
        set_max_size: { _, _, _, _ in },
        set_min_size: { _, _, _, _ in },
        set_maximized: { _, _ in },
        unset_maximized: { _, _ in },
        set_fullscreen: { _, _, _ in },
        unset_fullscreen: { _, _ in },
        set_minimized: { _, _ in }
    ))

    nonisolated(unsafe) private static let positionerRequests = permanent(xdg_positioner_requests(
        destroy: destroyResource,
        set_size: { _, _, _, _ in },
        set_anchor_rect: { _, _, _, _, _, _ in },
        set_anchor: { _, _, _ in },
        set_gravity: { _, _, _ in },
        set_constraint_adjustment: { _, _, _ in },
        set_offset: { _, _, _, _ in },
        set_reactive: { _, _ in },
        set_parent_size: { _, _, _, _ in },
        set_parent_configure: { _, _, _ in }
    ))
}
