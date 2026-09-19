# Compositor

`mydistro-compositor` is the display server of mydistro. It is a Swift program. The code is in `ui/Sources/Compositor/`, `ui/Sources/CompositorMain/`, and the Wayland server library `ui/Sources/Wayland/`.

## Run it

In the VM, log in as `root` on the serial console and run these commands:

```sh
LIBSEAT_BACKEND=noop mydistro-compositor &
mydistro-hello-client &
```

`make demo` does these steps for you in a QEMU window.

| Item | Details |
|---|---|
| Stop | Ctrl+Alt+Backspace, SIGINT, or SIGTERM. The compositor restores the text console. |
| Wayland socket | Printed at start, for example `WAYLAND_DISPLAY=wayland-0`, in `$XDG_RUNTIME_DIR`. |
| Debug messages | Set `MYDISTRO_DEBUG=1`. The compositor logs each start step, and libseat logs its messages. |
| Seat | `LIBSEAT_BACKEND=noop` lets root open the devices directly. The serial console has no seat session. In a login session on a VT, libseat uses logind. |

## Parts

| File | Part | Purpose |
|---|---|---|
| `Seat.swift` | `Seat` | Device access through libseat. It opens and closes the DRM device and the input devices. |
| `Screen.swift` | `Screen` | One output. It has two framebuffers and changes them at vertical blank. It draws a frame only when something changes. |
| `Input.swift` | `Input` | libinput and xkbcommon. It gives pointer motion, pointer position, buttons, and keys. |
| `WaylandServer.swift` | `WaylandServer`, `Surface`, `Toplevel` | The Wayland globals and objects that apps use: `wl_compositor`, `wl_surface`, and `xdg_wm_base`. |

| `Cursor.swift` | `Cursor` | The pointer image. |
| `Compositor.swift` | `Compositor` | Connects the parts. It keeps the window list, draws the shell panel, and makes the display list for each frame. |
| `Support.swift` | | Logging, the monotonic clock, and `permanent(_:)` for C handler tables. |

The display list and the CPU renderer are in the `Render` library (`ui/Sources/Render/`). The views and the layout are in the `Toolkit` library, and the panel is in the `Shell` library. See [toolkit.md](toolkit.md).

The `DRMKit` library (`ui/Sources/DRMKit/`) finds outputs, makes framebuffers, puts them on the screen, and does page flips.

The `Wayland` library (`ui/Sources/Wayland/`) is the Wayland server and the main loop. See [The Wayland server](#the-wayland-server).

## One frame

1. Something changes: an app commits a buffer, the pointer moves, or a window closes.
2. The compositor calls `Screen.setNeedsFrame()`.
3. If no page flip is pending, `Screen` draws a frame in the back buffer and asks DRM for a page flip at the next vertical blank. If a page flip is pending, `Screen` draws the frame after the flip.
4. To draw, the compositor makes a display list: the background, each window, the shell panel, and the pointer. `SoftwareRenderer` draws the list.
5. After the page flip, the compositor sends `wl_callback.done` to each window. The apps can then draw their next frame.

If the driver cannot do page flips, `Screen` uses a mode set for each frame.

## The display list

A display list is an array of items from back to front:

| Item | Content |
|---|---|
| `.fill(Rect, color:)` | A solid colour |
| `.bitmap(Bitmap, x:, y:)` | An image with premultiplied alpha, or an opaque image |

The display list is the interface between the UI layer and the pixels. The toolkit makes items from views, and only the renderer writes pixels. Thus, a GPU renderer can replace `SoftwareRenderer` and the toolkit does not change.

## The shell panel

The top 28 pixels of the screen are the shell panel. The compositor draws it with the toolkit, over the windows and under the pointer. It has the name of the system, the title of the front window, and the time in it.

The compositor gives the panel a `PanelState` for each frame: the window titles from the Wayland toplevels, and the time from `localtime_r`. A timer in the event loop reads the clock every second and asks for a frame when the minute changes.

The panel is a view, so its tests need no screen. See [toolkit.md](toolkit.md).

## Wayland support

| Interface | Version | Support |
|---|---|---|
| `wl_display`, `wl_registry`, `wl_callback` | 1 | Complete. The `Wayland` library implements them. |
| `wl_shm`, `wl_shm_pool`, `wl_buffer` | 2 | ARGB8888 and XRGB8888. The `Wayland` library implements them. |
| `wl_compositor` | 6 | Surfaces and regions. Regions have no effect. |
| `wl_surface` | 6 | `attach`, `commit`, `frame`. The other requests have no effect. |
| `xdg_wm_base` | 6 | `get_xdg_surface`, `create_positioner`, `pong` |
| `xdg_surface` | 6 | `get_toplevel`, `ack_configure`. `get_popup` gives a protocol error. |
| `xdg_toplevel` | 6 | `set_title`, `set_app_id`. The other requests have no effect. |

When an app commits a buffer, the compositor copies the pixels and releases the buffer immediately. The first commit of a toplevel gets a configure event with the size 0×0. The app then selects its own size.

The compositor puts a new window at the centre of the free space under the panel. Each further window is 32 pixels lower and to the right.

## The Wayland server

The `Wayland` library is a Wayland server in Swift. It does not use libwayland-server. It uses only glibc: sockets, `epoll`, `signalfd`, and `mmap`. The `CLinux` module imports the glibc headers for `epoll` and `signalfd`, which the Swift `Glibc` module does not include.

| File | Type | Purpose |
|---|---|---|
| `EventLoop.swift` | `EventLoop` | The main loop on `epoll`. It watches file descriptors, and it gets signals through a `signalfd`. All callbacks run on one thread. |
| `Display.swift` | `Display` | The socket `$XDG_RUNTIME_DIR/wayland-N` with its lock file, the clients, the globals, `wl_display`, and `wl_registry`. |
| `Client.swift` | `Client` | One connection: its objects, and the bytes and file descriptors in each direction. It sends protocol errors and disconnects. |
| `Wire.swift` | `MessageReader`, `MessageWriter` | The wire format: 32-bit words, strings, arrays, fixed-point numbers, and file descriptors (`SCM_RIGHTS`). |
| `Resource.swift` | `Interface`, `AnyResource`, `Resource<I>` | A protocol object of one client. |
| `Shm.swift` | `Shm`, `ShmPool`, `ShmBuffer` | `wl_shm`. |
| `Protocols/*.swift` | One enum for each interface | Generated from `ui/Protocols/*.xml`. See [ui.md](ui.md). |

### Protocol objects

For each interface, the generated code has an enum, for example `WlSurface`, with these parts:

- `WlSurface.Request`: one case for each request, with typed arguments. For example, `.attach(buffer: Resource<WlBuffer>?, x: Int32, y: Int32)`.
- The decoder for requests. It checks the opcode, the version of the object (`since`), the argument types, the object types, and new object IDs. An error in a request is a protocol error.
- The protocol enums, for example `WlShm.Format`. A bitfield is an `OptionSet`.
- One method for each event on `Resource<WlSurface>`, for example `sendEnter(output:)`. The method sends nothing after the resource's destruction, or if the version of the resource is older than the event.

The compositor handles requests with a closure:

```swift
display.addGlobal(WlCompositor.self, version: 6) { compositor in
    compositor.onRequest = { request in
        switch request {
        case .createSurface(let id):
            let surface = compositor.create(id)
            ...
        }
    }
}
```

These rules apply:

- A request that makes an object (an argument of type `NewID`) must make it with `create(_:)`, also if the compositor ignores the object.
- A request with a file descriptor gives it to the handler. The handler must close it.
- After a destructor request, the library destroys the resource. It sends `wl_display.delete_id` for IDs that the client allocated.
- The `data` property of a resource keeps the Swift object for it, for example a `Surface`. Other references to resources are weak.
- `onDestroy` handlers run when the client destroys the object or disconnects. On a disconnect, the library destroys the newest objects first.

### Protection against bad clients

- An error in a request sends `wl_display.error` to the client, then disconnects it. The compositor continues.
- If a client does not read its events, the library disconnects it when 4 MB of events wait.
- A client can make its shared-memory file smaller after it gave it to the compositor. A read of the missing memory then raises SIGBUS. During a buffer copy, a SIGBUS handler maps empty memory over the pool. The copy gets zeros, and the client gets a protocol error. libwayland-server does the same.

## Current limits

- Apps get no keyboard or pointer input. There is no `wl_seat`.
- There is no window management: no focus, no move, no stacking order, and no window close.
- The compositor draws the full screen for each frame. It ignores damage.
- Apps can use only `wl_shm` buffers, not GPU buffers (`linux-dmabuf`).
- There is no `wl_output`, no popups, and no window decorations.
- The compositor uses only the first connected output.
- The compositor does not stop drawing when libseat disables the seat (for example on a VT switch).

See [next-steps.md](next-steps.md).
