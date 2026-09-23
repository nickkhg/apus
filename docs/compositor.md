# Compositor

`apus-compositor` is the display server of apus. It is a Swift program. The code is in `ui/Sources/Compositor/`, `ui/Sources/CompositorMain/`, and the Wayland server library `ui/Sources/Wayland/`.

## It starts the machine

An installed system starts the shell when it finishes booting. `apus-shell.service` runs the compositor on tty1, and systemd starts seatd for it. The installer turns the service on for the system that it installs. The live system keeps its console, because the installer is what the live system is for.

`make gui` boots an installed disk in a window, and the shell is there.

## Run it by hand

A test drives the screen itself, so it takes the screen back first:

```sh
systemctl stop apus-shell
LIBSEAT_BACKEND=noop apus-compositor &
```

Then press Super to open Summon, and type a name to open an app. `make demo` does these steps for you in a window, and every test does the first one (`tests/lib.exp`).

| Item | Details |
|---|---|
| Stop | Ctrl+Alt+Backspace, SIGINT, or SIGTERM. The compositor restores the text console. |
| Wayland socket | Printed at start, for example `WAYLAND_DISPLAY=wayland-0`, in `$XDG_RUNTIME_DIR`. |
| Debug messages | Set `APUS_DEBUG=1`. The compositor logs each start step, and libseat logs its messages. |
| Seat | `LIBSEAT_BACKEND=noop` lets root open the devices directly. The serial console has no seat session. In a login session on a VT, libseat uses logind. |

## Parts

| File | Part | Purpose |
|---|---|---|
| `Seat.swift` | `Seat` | Device access through libseat. It opens and closes the DRM device and the input devices. |
| `Screen.swift` | `Screen` | One output. It has two framebuffers and changes them at vertical blank. It draws a frame only when something changes. |
| `Input.swift` | `Input` | libinput and xkbcommon. It gives pointer motion, pointer position, buttons, and keys. |
| `WaylandServer.swift` | `WaylandServer`, `Surface`, `Toplevel` | The Wayland globals and objects that apps use: `wl_compositor`, `wl_surface`, `xdg_wm_base`, and `wl_seat` with the keyboard and the pointer. |
| `AppCatalog.swift` | `AppCatalog`, `AppBundle` | The app bundles in `/Applications`, and how a bundle starts. See [applications.md](applications.md). |

| `Cursor.swift` | `Cursor` | The pointer image. |
| `Compositor.swift` | `Compositor` | Connects the parts. It keeps the window list and the focus, holds the pointer during a press, a move and a resize, starts the apps, draws the shell, and makes the display list for each frame. |
| `Support.swift` | | Logging, the monotonic clock, and `permanent(_:)` for C handler tables. |

The display list, the views and the shell UI are in the package `ui/Toolkit/`: the libraries `Render`, `Toolkit` and `Shell`. See [toolkit.md](toolkit.md).

The `DRMKit` library (`ui/Sources/DRMKit/`) finds outputs, makes framebuffers, puts them on the screen, and does page flips.

The `Wayland` library (`ui/Sources/Wayland/`) is the Wayland server and the main loop. See [The Wayland server](#the-wayland-server).

## One frame

1. Something changes: an app commits a buffer, the pointer moves, or a window closes.
2. The compositor calls `Screen.setNeedsFrame()`.
3. If no page flip is pending, `Screen` draws a frame in the back buffer and asks DRM for a page flip at the next vertical blank. If a page flip is pending, `Screen` draws the frame after the flip.
4. To draw, the compositor makes a display list: the background, each window, the shell, and the pointer.
5. The screen finds the part of the screen that changed (see [Damage](#damage)), and `SoftwareRenderer` draws the list inside that part only.
6. After the page flip, the compositor sends `wl_callback.done` to each window. The apps can then draw their next frame.

If the driver cannot do page flips, `Screen` uses a mode set for each frame.

## Damage

A frame draws only the part of the screen that changed. A line of the terminal, the minute of the clock, or a button that lights up under the pointer costs its own pixels, and not the screen. The code is in `ui/Toolkit/Sources/Render/Damage.swift`, and `ScreenDamage` in `Screen.swift` connects it to the buffers.

Two things say what changed:

| What | How |
|---|---|
| The display list | `DamageTracker` compares the list of this frame with the list of the last one. An item that is in both lists, in the same order and with the same clip, changed nothing. Every other item changed the pixels under it, in the old list and in the new one. The two lists are matched with the diff of Myers, so an item that went in or out changes its own pixels, and not those of every item after it. This covers the shell (the rail, Summon, the heads and the cards that `ViewHost` draws), a window that moved, and a window that opened or closed. |
| The pixels of a window | An app says what it drew with `wl_surface.damage` or `wl_surface.damage_buffer`. A buffer of the same size goes into the same `Bitmap`, and the commit copies only the damaged part of it. `Bitmap.markChanged` keeps that part, so the item of the window is the same item and only the damaged part counts. The GPU renderer also sends only those rows to its texture. |

The damage is a `Region`: up to 12 rectangles that do not overlap. The renderer draws the list once for each rectangle, with the rectangle as a clip under every clip of the list. The shape of an item does not depend on the clip, only which of its pixels are written, so a pixel comes out the same in part as in whole. `ui/Toolkit/Tests/RenderTests/DamageTests.swift` holds that, pixel for pixel, for every kind of item and for random edits of random lists.

A screen draws into the buffer that the display does not show, and that buffer holds an older frame: two frames ago with two dumb buffers, and what EGL says with GBM (`EGL_EXT_buffer_age`). `DamageHistory` keeps the damage of the last 6 frames, and a buffer draws everything that changed since the frame it holds. A buffer with no frame, a new size of the screen, or an EGL without buffer age draws the whole screen.

A blur reads the picture around it, 2 × `boxHalfWidth(radius)` pixels outside its shape. A change there changes the blur, and the blur must read pixels of this frame and not what the buffer held. `Region.grown(for:)` therefore makes every rectangle that touches what a blur reads hold all of it. A blur is then drawn once, whole, inside one rectangle. The GPU renderer copies the screen for a blur only when the damage touches it, so a frame that changes something far from Summon reads nothing back.

Two app programs of Apus, `AppClient` and the terminal, keep their buffer between frames and use the same `DamageTracker`. They draw only what changed, and they send that part as `damage_buffer`. A frame that changed nothing sends no buffer.

The pointer is not part of the damage when the display has a plane for it: moving it draws no frame at all.

`APUS_DAMAGE=full` draws every frame whole, to compare the costs, or to rule damage out when a picture looks wrong. `APUS_FRAME_LOG` says what part of the screen the frames drew (see [testing.md](testing.md#the-vm)). `APUS_DAMAGE_CHECK=1` makes `GPUScreen` draw each frame that it drew in part a second time, whole, and say `DAMAGE-WRONG` when the two differ. `tests/gpu.exp` turns it on, because the picture of that screen is drawn whole and would not show a fault.

## The display list

A display list is an array of items from back to front:

| Item | Content |
|---|---|
| `.fill(Rect, color:)` | A solid colour |
| `.bitmap(Bitmap, x:, y:)` | An image with premultiplied alpha, or an opaque image |
| `.path(Path, color:)` | An outline of lines and curves, filled with smooth edges |

The display list is the interface between the UI layer and the pixels. The toolkit makes items from views, and only the renderer writes pixels. Thus, a GPU renderer can replace `SoftwareRenderer` and the toolkit does not change.

## The shell

The rail is the chrome of the shell. It is 56 points wide, on the left edge, and the compositor draws it with the toolkit, over the windows and under the pointer. It holds the Summon button, the layout button, a bar for each open window, and the time.

The compositor draws `RootView` from the `Shell` library over the whole screen. `RootView` puts the rail on the left, and the canvas beside it. `RootView.windowArea(screen:)` tells the compositor where the canvas is, so the shell decides how much space it takes. A layout then puts the windows in the canvas. See [layouts.md](layouts.md).

The compositor gives the shell a `ShellState` for each frame. In it are the apps of `/Applications` and the ids of the apps that have a window. In it are also the window titles from the Wayland toplevels, and the time from `localtime_r`. A timer in the event loop reads the clock every second and asks for a frame when the minute changes.

A `ViewHost` keeps the shell between frames: the `@State` values of the shell views, and which view the pointer is over. When the pointer moves or a button goes down, the compositor gives it to the host. The host then calls the handler of the view: `onHover` for a view that the pointer entered or left, and `onPress` and `onTapGesture` for a click. A handler that changes a state value asks for a frame. This is how a bar of the rail becomes brighter under the pointer.

The shell asks the compositor for two things (`ShellActions`):

| Action | What the compositor does |
|---|---|
| `openApp(id)` | Starts the app of that bundle, or brings its window to the front. See [applications.md](applications.md). |
| `closeFrontWindow` | Sends `xdg_toplevel.close` to the window that has the keys. The app decides what it does with that. |

A press on the chrome goes to the shell, and a press on a window goes to the app (see [The pointer](#the-pointer)).

The shell is a view, so its tests need no screen. See [toolkit.md](toolkit.md).

## The pointer

The seat has a pointer as well as a keyboard. Where the pointer is decides who reads it.

1. Summon covers the canvas while it is open, so the shell reads the pointer.
2. A pointer inside the window of an app goes to that app, in the coordinates of its surface. The shell hears that the pointer left it.
3. Everything else is the chrome of the shell: the rail, the head of a window, a card, a notice. The shell reads it.

The first press decides who holds the pointer until the last button comes up. A press on a window keeps the pointer with that app, also when the pointer leaves the window, so a drag that goes past the edge still reaches it. Wayland calls this the implicit grab. A press on the chrome keeps it with the shell.

## Window management

A move and a resize are requests of the app, after a press on its own title bar or its own edge. The shell draws no edge that a person can drag. The layout owns every frame, so a move takes a window to another cell and a resize moves only an edge that the layout lets a person move. [layouts.md](layouts.md#moving-and-resizing) has the rules for each layout.

1. The app gets the press in `wl_pointer.button`, with a serial.
2. It sends `xdg_toplevel.move`, or `xdg_toplevel.resize` with the edges. `WaylandServer` checks that the serial is the serial of the last press on that surface. `Compositor` checks that the button of that press is still down. A request that fails either check is ignored, and the log says `WINDOW-MOVE-IGNORED` or `WINDOW-RESIZE-IGNORED`. An edge that is not in `resize_edge` is a protocol error.
3. The compositor takes the pointer from the app. The app gets `wl_pointer.leave`, and no button events until the grab ends.
4. During a move, the window follows the pointer, over the shell. During a resize, the edge follows the pointer: each motion runs the layout again, and a window whose size changed gets a configure with the new size and the `resizing` state.
5. When the last button comes up, a move drops the window on the cell under the pointer, and a resize sends one more configure without `resizing`. The pointer then goes to whatever is under it.

A request that the layout cannot use is refused (`WINDOW-MOVE-REFUSED`, `WINDOW-RESIZE-REFUSED`), and the app keeps the pointer as if it had not asked.

## The keyboard and the focus

One window has the keys. In the principal layout it is the window in the large cell, and in Full it is the one window that shows. Side by side and in the grid, it is the window that a person clicked last. These things change it:

- An app opens a window. The new window has the keys.
- A click on a window. In the principal layout a click on a tile brings the tile into the large cell when the button comes up. Side by side and in the grid the window keeps its cell. See [layouts.md](layouts.md#a-click).
- Summon or the rail brings a window to the first place.
- A move. Side by side and in the grid the window that moved keeps the keys.
- A window closes.

The window with the keys gets the `activated` state in its configure, and the other windows get a configure without it. The accent line along the head says the same to a person.

A key goes to that window in three steps:

1. `Input` reads the key from libinput. It gives the code of the kernel, the keysym from the keymap, and the modifiers.
2. Ctrl+Alt+Backspace stops the compositor. The volume keys change the volume of the machine with `wpctl` and play `audio-volume-change` (see [sounds.md](sounds.md#who-plays-what)). Super opens Summon. Every other key goes to the shell, and then to the app.
3. `WaylandServer.send(key:)` sends `wl_keyboard.key` to the window with the focus, with `wl_keyboard.modifiers` before it when the modifiers changed.

The seat says that it has a keyboard and a pointer, and no touch. A `wl_keyboard` object gets the keymap first: the compositor writes the xkb keymap of `Input` into shared memory and sends the file descriptor. The app compiles the same keymap, so the app reads the keys in the same way as the system.

A window that gets the focus gets `wl_keyboard.enter`, and the window that loses it gets `wl_keyboard.leave`.

## Wayland support

| Interface | Version | Support |
|---|---|---|
| `wl_display`, `wl_registry`, `wl_callback` | 1 | Complete. The `Wayland` library implements them. |
| `wl_shm`, `wl_shm_pool`, `wl_buffer` | 2 | ARGB8888 and XRGB8888. The `Wayland` library implements them. |
| `wl_compositor` | 6 | Surfaces and regions. Regions have no effect. |
| `wl_surface` | 6 | `attach`, `commit`, `frame`, `damage`, `damage_buffer`, `set_buffer_scale`. The other requests have no effect. |
| `xdg_wm_base` | 6 | `get_xdg_surface`, `create_positioner`, `pong` |
| `xdg_surface` | 6 | `get_toplevel`, `ack_configure`. `get_popup` gives a protocol error. |
| `xdg_toplevel` | 6 | `set_title`, `set_app_id`, `set_min_size`, `move`, `resize`. The configure carries the states `maximized`, `activated` and `resizing`. The other requests have no effect. |
| `wl_seat` | 7 | The keyboard and the pointer. `get_touch` gives an object that gets no events. |
| `wl_pointer` | 7 | `enter`, `leave`, `motion`, `button`, `axis`, `axis_source`, `frame`. `set_cursor` has no effect: the compositor draws its own pointer. |
| `wl_keyboard` | 7 | `keymap`, `enter`, `leave`, `key`, `modifiers`, `repeat_info` |

When an app commits a buffer, the compositor copies the pixels and releases the buffer immediately. It copies only what the app damaged, over its copy of the last buffer, when the new buffer has the same size. A commit of a new buffer with no damage at all copies the whole buffer. The protocol says that nothing changed then, and a copy of the whole buffer is never wrong. The first commit of a toplevel gets a configure event with the size of its cell, less the head, and the states `maximized` and `activated`. An app that answers with that size fills the area. A later configure comes when the size or the states change.

The compositor puts a window in the app area. A window of another size goes in the middle of the area. See [applications.md](applications.md).

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

- A second compositor cannot start at once after the first one stops. `COMPOSITOR-EXIT` goes on the console before the process ends, and the screen and the DRM device go back after that. A compositor that starts inside that window fails to become DRM master, with `drmModeSetCrtc: Permission denied`. Wait for the process to end, not for the line.
- A person can move a window or change its size only through the app, with `xdg_toplevel.move` and `xdg_toplevel.resize`. The head that the shell draws has no bar to drag and no edge to pull.
- A move shows no mark on the cell that the window will take. The window follows the pointer, and the drop decides.
- Apps can use only `wl_shm` buffers, not GPU buffers (`linux-dmabuf`).
- There is no `wl_output`, no popups, and no window decorations.
- The compositor uses only the first connected output.
- The compositor does not stop drawing when libseat disables the seat (for example on a VT switch).

See [next-steps.md](next-steps.md).
