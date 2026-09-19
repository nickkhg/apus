# Compositor

`mydistro-compositor` is the display server of mydistro. It is a Swift program. The code is in `ui/Sources/Compositor/` and `ui/Sources/CompositorMain/`.

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
| `EventLoop.swift` | `EventLoop` | The main loop. It uses the libwayland event loop, and watches file descriptors and signals. All code runs on one thread. |
| `Seat.swift` | `Seat` | Device access through libseat. It opens and closes the DRM device and the input devices. |
| `Screen.swift` | `Screen` | One output. It has two framebuffers and changes them at vertical blank. It draws a frame only when something changes. |
| `Input.swift` | `Input` | libinput and xkbcommon. It gives pointer motion, pointer position, buttons, and keys. |
| `WaylandServer.swift` | `WaylandServer`, `Surface`, `Toplevel` | The Wayland objects that apps use. |
| `Scene.swift` | `DisplayList`, `SoftwareRenderer` | The display list and the CPU renderer. |
| `Cursor.swift` | `Cursor` | The pointer image. |
| `Compositor.swift` | `Compositor` | Connects the parts. It keeps the window list and makes the display list for each frame. |

The `DRM` library (`ui/Sources/DRM/`) finds outputs, makes framebuffers, puts them on the screen, and does page flips.

## One frame

1. Something changes: an app commits a buffer, the pointer moves, or a window closes.
2. The compositor calls `Screen.setNeedsFrame()`.
3. If no page flip is pending, `Screen` draws a frame in the back buffer and asks DRM for a page flip at the next vertical blank. If a page flip is pending, `Screen` draws the frame after the flip.
4. To draw, the compositor makes a display list: the background, each window, and the pointer. `SoftwareRenderer` draws the list.
5. After the page flip, the compositor sends `wl_callback.done` to each window. The apps can then draw their next frame.

If the driver cannot do page flips, `Screen` uses a mode set for each frame.

## The display list

A display list is an array of items from back to front:

| Item | Content |
|---|---|
| `.fill(Rect, color:)` | A solid colour |
| `.bitmap(Bitmap, x:, y:)` | An image with premultiplied alpha, or an opaque image |

The display list is the interface for a future UI layer, for example OpenSwiftUI. A UI layer can add items to the list. Only the renderer writes pixels. Thus, a GPU renderer can replace `SoftwareRenderer` and the UI layer does not change.

## Wayland support

| Interface | Version | Support |
|---|---|---|
| `wl_compositor` | 6 | Surfaces and regions. Regions have no effect. |
| `wl_surface` | 6 | `attach`, `commit`, `frame`. The other requests have no effect. |
| `wl_shm` | From libwayland | libwayland implements it. The compositor reads ARGB8888 and XRGB8888 buffers. |
| `xdg_wm_base` | 6 | `get_xdg_surface`, `create_positioner`, `pong` |
| `xdg_surface` | 6 | `get_toplevel`, `ack_configure`. `get_popup` gives a protocol error. |
| `xdg_toplevel` | 6 | `set_title`, `set_app_id`. The other requests have no effect. |

When an app commits a buffer, the compositor copies the pixels and releases the buffer immediately. The first commit of a toplevel gets a configure event with the size 0×0. The app then selects its own size.

The compositor puts a new window at the centre of the screen. Each further window is 32 pixels lower and to the right.

### How Swift implements Wayland requests

libwayland calls a C function for each request. For each interface, the compositor makes a table of Swift closures (for example `wl_surface_requests`). A closure that has no captures can be a C function pointer.

- `permanent(_:)` allocates each table one time and never releases it, because libwayland keeps pointers to the tables.
- The user data of each resource is the `WaylandServer`. The Swift objects are in dictionaries, with the resource as the key.
- The destroy function of each resource removes its Swift object. This occurs when the app destroys the object or disconnects.
- `ResourceDestroyListener` uses `swift_wl_listener` to know when an app destroys a buffer.

## Current limits

- Apps get no keyboard or pointer input. There is no `wl_seat`.
- There is no window management: no focus, no move, no stacking order, and no window close.
- The compositor draws the full screen for each frame. It ignores damage.
- Apps can use only `wl_shm` buffers, not GPU buffers (`linux-dmabuf`).
- There is no `wl_output`, no popups, and no window decorations.
- The compositor uses only the first connected output.
- The compositor does not stop drawing when libseat disables the seat (for example on a VT switch).

See [next-steps.md](next-steps.md).
