// mydistro-hello-client [--seconds N] [--size WxH]
//
// A minimal Wayland app: opens one window filled with a colour (with a white
// border) through wl_shm and xdg-shell. Used to test the compositor.
//
// The window takes the size that the compositor asks for in the configure
// event, which is the app area of the screen. --size keeps a size of our own.

import CWaylandClient
import CXDGShellClient
import Glibc

let windowColor: UInt32 = 0x3070F0
let borderColor: UInt32 = 0xFFFFFF
let border = 8

func fail(_ message: String) -> Never {
    print("mydistro-hello-client: \(message)")
    exit(1)
}

// MARK: - Client state

final class Client {
    /// The size of the window. The compositor asks for one in the configure
    /// event; --size keeps this size instead.
    var width = 400
    var height = 300
    var sizeIsFixed = false
    var compositor: OpaquePointer?
    var shm: OpaquePointer?
    var wmBase: OpaquePointer?
    var surface: OpaquePointer?
    var buffer: OpaquePointer?
    var drawn = false
}

let client = Client()
let clientPointer = Unmanaged.passUnretained(client).toOpaque()
func state(_ data: UnsafeMutableRawPointer?) -> Client {
    Unmanaged<Client>.fromOpaque(data!).takeUnretainedValue()
}

/// Allocates a value that never moves (libwayland keeps listener pointers).
func permanent<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    pointer.initialize(to: value)
    return pointer
}

// MARK: - Arguments

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--seconds":
        guard let seconds = arguments.popFirst().flatMap(UInt32.init) else { fail("--seconds needs a number") }
        alarm(seconds)   // SIGALRM ends the process
    case "--size":
        let parts = (arguments.popFirst() ?? "").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { fail("--size needs WxH") }
        (client.width, client.height) = (parts[0], parts[1])
        client.sizeIsFixed = true
    default:
        fail("usage: mydistro-hello-client [--seconds N] [--size WxH]")
    }
}

// MARK: - The window's pixels

/// Makes a shared-memory buffer of the current size, with the window drawn
/// in it: a colour with a white border.
func makeBuffer(_ client: Client) {
    let (width, height) = (client.width, client.height)
    let stride = width * 4
    let size = stride * height
    let name = "/mydistro-hello-\(getpid())"
    let fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail("shm_open: \(String(cString: strerror(errno)))") }
    shm_unlink(name)
    guard ftruncate(fd, off_t(size)) == 0,
          let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), memory != MAP_FAILED else {
        fail("can't map the buffer")
    }
    let pixels = memory.assumingMemoryBound(to: UInt32.self)
    for y in 0..<height {
        for x in 0..<width {
            let edge = x < border || y < border || x >= width - border || y >= height - border
            pixels[y * width + x] = edge ? borderColor : windowColor
        }
    }
    let pool = wl_shm_create_pool(client.shm, fd, Int32(size))
    client.buffer = wl_shm_pool_create_buffer(pool, 0, Int32(width), Int32(height), Int32(stride),
                                              WL_SHM_FORMAT_XRGB8888.rawValue)
    wl_shm_pool_destroy(pool)
    close(fd)
}

// MARK: - Listeners

let registryListener = permanent(wl_registry_listener(
    global: { data, registry, name, interface, version in
        let client = state(data)
        switch String(cString: interface!) {
        case "wl_compositor":
            client.compositor = OpaquePointer(wl_registry_bind(registry, name, wl_compositor_interface_ptr(), 4))
        case "wl_shm":
            client.shm = OpaquePointer(wl_registry_bind(registry, name, wl_shm_interface_ptr(), 1))
        case "xdg_wm_base":
            client.wmBase = OpaquePointer(wl_registry_bind(registry, name, xdg_wm_base_interface_ptr(), 1))
        default:
            break
        }
    },
    global_remove: { _, _, _ in }
))

let wmBaseListener = permanent(xdg_wm_base_listener(
    ping: { _, wmBase, serial in xdg_wm_base_pong(wmBase, serial) }
))

let xdgSurfaceListener = permanent(xdg_surface_listener(
    configure: { data, xdgSurface, serial in
        let client = state(data)
        xdg_surface_ack_configure(xdgSurface, serial)
        guard !client.drawn else { return }
        // First configure: make a buffer of the size we now know, and show
        // the window.
        makeBuffer(client)
        wl_surface_attach(client.surface, client.buffer, 0, 0)
        wl_surface_damage_buffer(client.surface, 0, 0, Int32.max, Int32.max)
        wl_surface_commit(client.surface)
        client.drawn = true
        print("CLIENT-DRAWN \(client.width)x\(client.height)")
        fflush(nil)
    }
))

let toplevelListener = permanent(xdg_toplevel_listener(
    configure: { data, _, newWidth, newHeight, _ in
        // The compositor gives the window the app area of the screen. A zero
        // size means "pick your own", and --size keeps ours.
        let client = state(data)
        guard !client.sizeIsFixed, newWidth > 0, newHeight > 0 else { return }
        (client.width, client.height) = (Int(newWidth), Int(newHeight))
    },
    close: { _, _ in exit(0) },
    configure_bounds: { _, _, _, _ in },
    wm_capabilities: { _, _, _ in }
))

// MARK: - Main

guard let display = wl_display_connect(nil) else {
    fail("can't connect to a Wayland compositor (is WAYLAND_DISPLAY set?)")
}
let registry = wl_display_get_registry(display)
wl_registry_add_listener(registry, registryListener, clientPointer)
wl_display_roundtrip(display)
guard client.compositor != nil, client.shm != nil, client.wmBase != nil else {
    fail("compositor lacks wl_compositor, wl_shm or xdg_wm_base")
}
xdg_wm_base_add_listener(client.wmBase, wmBaseListener, clientPointer)

// The window: a surface with the xdg toplevel role. The first commit (with no
// buffer) asks the compositor to configure it; we draw in the configure handler.
client.surface = wl_compositor_create_surface(client.compositor)
let xdgSurface = xdg_wm_base_get_xdg_surface(client.wmBase, client.surface)
xdg_surface_add_listener(xdgSurface, xdgSurfaceListener, clientPointer)
let toplevel = xdg_surface_get_toplevel(xdgSurface)
xdg_toplevel_add_listener(toplevel, toplevelListener, clientPointer)
xdg_toplevel_set_title(toplevel, "Hello from Swift")
xdg_toplevel_set_app_id(toplevel, "org.mydistro.hello")
wl_surface_commit(client.surface)

while wl_display_dispatch(display) != -1 {}
fail("lost the connection to the compositor")
