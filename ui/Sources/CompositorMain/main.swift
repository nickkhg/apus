// apus-compositor
//
// Takes over the screen, keyboard and mouse, and runs a Wayland server that
// apps connect to (WAYLAND_DISPLAY is printed at start). Quit with
// Ctrl+Alt+Backspace, SIGINT or SIGTERM.
//
// Device access goes through libseat: run it from a login session on a VT,
// or as root with LIBSEAT_BACKEND=noop.

import Compositor
import Glibc

do {
    let compositor = try Compositor()
    let (width, height) = compositor.screenSize
    print("COMPOSITOR-READY WAYLAND_DISPLAY=\(compositor.socketName) screen \(width)x\(height)")
    fflush(nil)
    compositor.run()
    print("COMPOSITOR-EXIT")
} catch {
    print("apus-compositor: \(error)")
    exit(1)
}
