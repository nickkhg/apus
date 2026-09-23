import CWaylandClient
import CXDGShellClient
import Glibc
import Render
import Toolkit

// The connection, the listeners and the loop. An app never sees any of it.

extension AppWindow {
    /// Opens the window and draws until it closes.
    public func run() {
        connect()
        let fd = wl_display_get_fd(display)
        while running {
            wl_display_flush(display)
            var watched = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            // The wait ends every 100 ms even with nothing to read, so that
            // a view that moves gets its next frame. A key that is held ends
            // it early, when it is due to go again.
            let wait = min(100, keyRepeat.wait(at: monotonic()) ?? 100)
            guard poll(&watched, 1, wait) >= 0 || errno == EINTR else { break }
            if watched[0].revents & Int16(POLLIN) != 0, wl_display_dispatch(display) < 0 { break }
            let now = monotonic()
            if let key = keyRepeat.due(at: now) { deliver(key: key, pressed: true) }
            if now - lastSecond >= 1 {
                lastSecond = now
                everySecond()
            }
            if needsDraw, !framePending { draw() }
        }
        wl_display_flush(display)
    }

    private func connect() {
        guard let connection = wl_display_connect(nil) else {
            fail("\(appID): no Wayland compositor (is WAYLAND_DISPLAY set?)")
        }
        display = connection
        let me = Unmanaged.passUnretained(self).toOpaque()
        let registry = wl_display_get_registry(connection)
        wl_registry_add_listener(registry, Listeners.registry, me)
        wl_display_roundtrip(connection)
        guard compositor != nil, shm != nil, wmBase != nil else {
            fail("\(appID): the compositor has no wl_compositor, wl_shm or xdg_wm_base")
        }
        wl_display_roundtrip(connection)    // the seat answers with what it has
        xdg_wm_base_add_listener(wmBase, Listeners.wmBase, me)

        surface = wl_compositor_create_surface(compositor)
        xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, surface)
        xdg_surface_add_listener(xdgSurface, Listeners.xdgSurface, me)
        toplevel = xdg_surface_get_toplevel(xdgSurface)
        xdg_toplevel_add_listener(toplevel, Listeners.toplevel, me)
        xdg_toplevel_set_title(toplevel, title)
        xdg_toplevel_set_app_id(toplevel, appID)
        if let minimumSize {
            xdg_toplevel_set_min_size(toplevel, Int32(minimumSize.width),
                                      Int32(minimumSize.height))
        }
        wl_surface_commit(surface)
    }

    /// Makes the shared memory that the pixels live in, for the size that
    /// the compositor asked for.
    func makeBuffer() {
        let stride = pixelWidth * 4
        let bytes = stride * pixelHeight
        guard bytes > 0 else { return }
        if let buffer { wl_buffer_destroy(buffer) }
        if let pool { wl_shm_pool_destroy(pool) }
        if let pixels, mappedBytes > 0 { munmap(pixels, mappedBytes) }
        buffer = nil
        pool = nil
        pixels = nil
        mappedBytes = 0

        buffers += 1
        let name = "/apus-\(appID)-\(getpid())-\(buffers)"
        let fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { fail("\(appID): no memory for the window") }
        shm_unlink(name)
        // Glibc.close, because this type has a close() of its own.
        defer { Glibc.close(fd) }
        guard ftruncate(fd, off_t(bytes)) == 0,
              let memory = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              memory != MAP_FAILED else {
            fail("\(appID): the window cannot be mapped")
        }
        pixels = memory.assumingMemoryBound(to: UInt32.self)
        mappedBytes = bytes
        pool = wl_shm_create_pool(shm, fd, Int32(bytes))
        buffer = wl_shm_pool_create_buffer(pool, 0, Int32(pixelWidth), Int32(pixelHeight),
                                           Int32(stride), WL_SHM_FORMAT_XRGB8888.rawValue)
        wl_surface_set_buffer_scale(surface, Int32(scale))
        sizeChanged(size, sizeClass)
    }

    /// The compositor asked for a size. The window takes it.
    func take(size newSize: Size) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        let changed = newSize != size || pixels == nil
        size = newSize
        // The class comes from the size that the compositor asked for, so
        // the app knows what to draw before it draws anything.
        sizeClass = SizeClass.of(Proposal(width: size.width, height: size.height))
        if changed {
            makeBuffer()
            needsDraw = true
        }
    }

    /// Draws the view tree of the app and gives the pixels to the compositor.
    func draw() {
        guard let pixels, let surface, let buffer else { return }
        needsDraw = false
        let canvas = Canvas(pixels: pixels, width: pixelWidth, height: pixelHeight,
                            stride: pixelWidth)
        host.now = monotonic() - startedAt
        let list = host.displayList(
            for: AnyViewBox(body()),
            in: Rect(x: 0, y: 0, width: Int(size.width), height: Int(size.height)),
            scale: Double(scale))
        SoftwareRenderer.render(list, into: canvas)

        let callback = wl_surface_frame(surface)
        wl_callback_add_listener(callback, Listeners.frame, Unmanaged.passUnretained(self).toOpaque())
        framePending = true

        wl_surface_attach(surface, buffer, 0, 0)
        wl_surface_damage_buffer(surface, 0, 0, Int32.max, Int32.max)
        wl_surface_commit(surface)
    }
}

/// Holds a view of any type, so that `body` can give a different one for
/// each frame.
struct AnyViewBox: View {
    public typealias Body = Never
    let content: any View

    init(_ content: any View) {
        self.content = content
    }

    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        content.makeNodes(into: &nodes, environment: environment)
    }
}
