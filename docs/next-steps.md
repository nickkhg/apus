# Loose ends and next steps

## Next steps for the compositor

In this sequence:

1. The pointer for apps. `wl_seat` has a keyboard already. Add `wl_pointer`, and send the events to the window under the pointer. The shell must keep the pointer when it is over the panel or the dock.
2. Window management. A window that moves and that changes its size (`xdg_toplevel.move`, `xdg_toplevel.resize`), and a click that brings a window forward.
3. Damage tracking. Draw only the parts of the screen that changed.
4. Stop drawing when libseat disables the seat (for example on a VT switch), and start again when libseat enables it.
5. A GPU renderer. Use GBM, EGL, and OpenGL ES to draw the display list. Keep `SoftwareRenderer` as a fallback.
6. `linux-dmabuf`, so that apps can give GPU buffers.
7. Popups (`xdg_popup` and `xdg_positioner`).
8. Test with real Wayland apps, for example `foot` or `weston-terminal`. The clients that test the Swift Wayland server now are `mydistro-hello-client` and `mydistro-terminal`.
9. `wl_registry.global_remove`, for globals that go away (for example a disconnected output).

## The toolkit and the shell

The toolkit draws the rail and Summon, with `@State`, shapes, clipping and the pointer. A layout puts the windows on the canvas. Summon starts the apps of `/Applications`, and the terminal is one of them. See [toolkit.md](toolkit.md), [layouts.md](layouts.md) and [applications.md](applications.md). Next, in this sequence:

1. More apps. `AppClient` and the system monitor are the pattern to follow. See [apps.md](apps.md). The design draws a file browser, a notes app and a power reading.
2. An icon file in a bundle, and an image as a display item. Summon draws a colour mark now.
3. A pointer position in a handler, and a drag.
4. More of the second mode. The shadow, the blur and the gradient are in the display list now, and both renderers draw all three. See [toolkit.md](toolkit.md#the-two-modes). Three things remain:

   - A blur reads the screen back. With damage tracking (item 3 of the compositor list) it could read only the part that changed.
   - The GPU blur is 17 steps in each direction. A smaller copy of the screen would give the same picture for less work.
   - The compositor does not tell an app which mode the screen is in. An app therefore reads `cpu` from `\.renderMode` and asks for no blur of its own. A `wl_output` value or a value in the bundle could carry it.
   - CPU mode asks for none of the three. A slow machine in GPU mode has no way to say "the shadows only", and `Appearance` has no middle mode.
5. More than one desktop, and a layout for each one. The design has this as the target, and one desktop is what ships.
6. A picture of a window in the card that stands in for it. It is a crop of the top left at one pixel to one point. A person turns it on for one app at a time.
7. A cell that moves. `Animation.window` names the move, and a frame moves already. A card, a message or the cell of a starting app can then slide to its new place instead of jumping. The window itself cannot: the compositor gives an app its size over Wayland, and an app that redraws at 60 different sizes is not free. So the chrome would move while the window jumps, which is worse than both jumping.

   A screen that moves also makes the pixel tests uncertain: a picture taken in the middle of a move is a different picture each run. `mydistro-screen shot` could wait for the screen to settle first. `ViewHost` knows when nothing is moving.
8. The display list of a view that did not change. The graph keeps the nodes of such a view. The frame still walks every node, to lay it out and to ask it for its items. A frame of the shell is 0.22 ms of that walk. An attribute for the items of a subtree, under its frame and the scale, would take most of it away.
9. Test OpenSwiftUI on Linux again if OpenAttributeGraph gets its engine. The toolkit API has the same shape, so a change costs little.

## The terminal

1. Text that a user can select, and copy and paste.
2. The lines that scrolled away, and a way to go back to them.
3. Key repeat. The compositor sends `repeat_info`, and the app does nothing with it.
4. More than one window, or more than one shell in one window.

## The system

- Root has no password. Add a user account and a password for use outside a VM.
- The toolkit is one dynamic library, and the machine carries one copy of it (see [ui.md](ui.md#one-library-for-the-machine)). It has no stable ABI: the library and the programs must come from one build. `-enable-library-evolution` on the toolkit would make a new library work with the programs that are there already. Put `@frozen` on the types of the hot path with it: `Frame`, `Size`, `Color`, `Rect` and `Proposal`. Measure `make bench` after it: a resilient type reaches its fields through a function.
- The shell runs as root. A shell of a person wants a session of that person. logind gives the seat, and the files that the apps open are that person's files.
- The live system does not start the installer automatically.

## Packages and the repository

- Sign the mydistro packages. Make a `mydistro-keyring` package with the public key, as Arch Linux does.
- Publish the `[mydistro]` repository on a server. Add it to `/etc/pacman.conf` on installed systems. Then installed systems get updates of mydistro packages.
- Build the packages that Arch Linux ARM does not have (see the Omarchy comparison in [decisions.md](decisions.md)).

## Reproducibility

- Arch Linux ARM has no archive of old package versions. Two builds on different days can be different. A mirror of our own with dated snapshots can fix this.
- In the key server copy, gpg marks the Swift signing key as expired. The signature is valid, and the Makefile checks the SHA-256 hash. Examine the key again at the next Swift update.
- The `.md5` file of Arch Linux ARM comes over HTTP. The Makefile pins the SHA-256 value of the first download.

## Development environment

- `lldb` does not work in the builder, because it needs Python 3.13. Arch Linux has Python 3.14.
- A debugger for the programs in the VM. `lldb-server` is in the Linux toolchain. The macOS toolchain has `lldb`, which can connect to it.
- Xcode gives no code completion for the Linux modules (see [ui.md](ui.md#limits-of-xcode)). An editor with SourceKit-LSP gives it.
- The Run action of the Xcode schemes (`make demo-dev`, `make demo`) was not tested in the Xcode window. A test with `xcodebuild` built the UI scheme.
- Unit tests for the `Wayland` library (wire format and object rules), with `swift test` in the builder container. Now only the VM tests test it.
- The VM must give the guest a GPU. The compositor can now render with one (see [ui.md](ui.md#the-two-renderers)). Apple's Virtualization framework gives a Linux guest none. There are three ways:

  | Way | What it needs |
  |---|---|
  | libkrun | It uses Hypervisor.framework, not Virtualization. It has virtio-gpu with Venus on Metal. |
  | QEMU with Venus | A build of our own. The QEMU of Homebrew does not have it. |
  | A virtio-gpu device of our own | `VZCustomVirtioDevice`, on macOS 27 or later. We must then write a Venus decoder on MoltenVK. |

- The GPU renderer draws a `path` from a coverage texture. The CPU makes that texture. `TextureCache` keeps it, so a shape that stays costs nothing after the first frame. A shape that moves or changes size goes to the CPU again. To fill an outline on the GPU, use a stencil pass and then a cover pass, with more than one sample for the smooth edges.
- The GPU renderer sends the pixels of a window to the GPU at each commit. The GPU can read a buffer of the app directly, with `EGL_WL_bind_wayland_display` or with dma-buf. That removes the copy.
- The GPU renderer draws one quad for each item. Items with the same texture and colour could go into one draw.
- `make gui` and `make demo` open a window. The automated tests do not test them. `tests/display.exp` and `tests/compositor.exp` test the same display with no window. In a window, the keyboard and the pointer are USB devices of the framework. The tests do not use those devices. They make their own with uinput.
- `make build` builds every package in `packages/` again, every time: `build.sh` removes the repository and runs `makepkg --cleanbuild --force` for each one. Two of them are Mesa (`mydistro-zink`, `vulkan-virtio`), which is most of the minutes of an image build. A package whose PKGBUILD and sources did not change could come from the repository of the last build.
- The tests use one VM disk in sequence. `tests/display.exp` and `tests/compositor.exp` need the disk from `tests/install.exp`.
- Old builder images use disk space. On 19 September, `container system df` reported 42 GB that `container image prune` can remove.

## Later

- x86_64 support.
- Real Mac hardware with Asahi Linux: its kernel, its boot chain, and its installer.
