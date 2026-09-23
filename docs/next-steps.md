# Loose ends and next steps

## Next steps for the compositor

Apps have the pointer, and a window moves, changes its size and comes forward with a click. A frame draws only what changed. See [compositor.md](compositor.md#window-management), [compositor.md](compositor.md#damage) and [layouts.md](layouts.md#moving-and-resizing). Next, in this sequence:

1. Stop drawing when libseat disables the seat (for example on a VT switch), and start again when libseat enables it.
2. A GPU renderer. Use GBM, EGL, and OpenGL ES to draw the display list. Keep `SoftwareRenderer` as a fallback.
3. `linux-dmabuf`, so that apps can give GPU buffers.
4. Popups (`xdg_popup` and `xdg_positioner`).
5. Test with real Wayland apps, for example `foot` or `weston-terminal`. The clients that test the Swift Wayland server now are `apus-hello-client` and `apus-terminal`. A real app is also the first test of a move and a resize from a title bar that someone else drew.
6. `wl_registry.global_remove`, for globals that go away (for example a disconnected output).
7. What window management does not have yet:

   - The head that the shell draws has no bar to drag and no edge to pull. An app that draws no title bar of its own, such as the terminal, can therefore not be moved with the pointer. The head could start the same move and the same resize.
   - A move shows no mark on the cell that the window will take.
   - `xdg_toplevel.wm_capabilities` (version 5). It would tell an app that there is no maximize, no minimize and no window menu, so that it hides those buttons.
   - The `tiled_left` to `tiled_bottom` states (version 2). A cell is a tile more than it is a maximized window, and an app draws square corners and no shadow for a tiled edge.
   - `wl_pointer.set_cursor`. The compositor always draws its own arrow, also over an edge that resizes.
   - The VM test resizes the edge between two windows side by side, and not the length of a tile. The unit tests hold the rule for a tile.
8. Give the display the damage too. A frame draws only what changed (see [compositor.md](compositor.md#damage)), but the page flip hands the display the whole buffer, and a virtual display copies all of it to the host. `FB_DAMAGE_CLIPS` on an atomic commit, or `drmModeDirtyFB`, says which part changed. The offscreen renderer still reads the whole frame back from the GPU, and copies only the damage into the buffer of the display.

## The toolkit and the shell

The toolkit draws the rail and Summon, with `@State`, shapes, clipping and the pointer. A layout puts the windows on the canvas. Summon starts the apps of `/Applications`, and the terminal is one of them. See [toolkit.md](toolkit.md), [layouts.md](layouts.md) and [applications.md](applications.md). Next, in this sequence:

1. More apps. `AppClient` and the system monitor are the pattern to follow. See [apps.md](apps.md). The design draws a file browser, a notes app and a power reading. Settings is there ([settings.md](settings.md)); it cannot join a wireless network, because Apus has no wireless daemon.
2. An icon file in a bundle, and an image as a display item. Summon draws a colour mark now.
3. A pointer position in a handler, and a drag.
4. More of the second mode. The shadow, the blur and the gradient are in the display list now, and both renderers draw all three. See [toolkit.md](toolkit.md#the-two-modes). Three things remain:

   - A blur reads the screen back only when the damage touches it, and then it reads all that it covers. A change under Summon therefore draws the whole blur again. A blur that kept its soft picture could put back only the part that changed, as long as nothing under it changed.
   - The GPU blur is 17 steps in each direction. A smaller copy of the screen would give the same picture for less work.
   - The compositor does not tell an app which mode the screen is in. An app therefore reads `cpu` from `\.renderMode` and asks for no blur of its own. A `wl_output` value or a value in the bundle could carry it.
   - CPU mode asks for none of the three. A slow machine in GPU mode has no way to say "the shadows only", and `Appearance` has no middle mode.
5. More than one desktop, and a layout for each one. The design has this as the target, and one desktop is what ships.
6. A picture of a window in the card that stands in for it. It is a crop of the top left at one pixel to one point. A person turns it on for one app at a time.
7. A cell that moves. `Animation.window` names the move, and a frame moves already. A card, a message or the cell of a starting app can then slide to its new place instead of jumping. The window itself cannot: the compositor gives an app its size over Wayland, and an app that redraws at 60 different sizes is not free. So the chrome would move while the window jumps, which is worse than both jumping.

   A screen that moves also makes the pixel tests uncertain: a picture taken in the middle of a move is a different picture each run. `apus-screen shot` could wait for the screen to settle first. `ViewHost` knows when nothing is moving.
8. The display list of a view that did not change. The graph keeps the nodes of such a view. The frame still walks every node, to lay it out and to ask it for its items. A frame of the shell is 0.22 ms of that walk. An attribute for the items of a subtree, under its frame and the scale, would take most of it away.
9. Test OpenSwiftUI on Linux again if OpenAttributeGraph gets its engine. The toolkit API has the same shape, so a change costs little.
10. Key repeat in the shell. The apps repeat a held key, and the shell does not: the compositor reads the keys from libinput, which sends one press, and gives them to Summon as they come. `KeyRepeat` of the toolkit is the clock, and a timer of the event loop of the compositor could drive it.

## The terminal

1. More than one window, or more than one shell in one window.

## Sounds

The theme is in the image, and the toolkit has `playSound` (see [sounds.md](sounds.md)). Nothing asks for a sound yet. In this sequence:

1. The audio stack: PipeWire, WirePlumber and `pipewire-audio` (for `pw-play`), and virtio-sound to the Mac. This work is separate. Until it is done, `playSound` plays nothing.
2. The compositor plays `desktop-login` at the first frame of the session, and a sound for each notice: `message-new-instant` for a notice of an app, and `dialog-information`, `dialog-warning` or `dialog-error` for a notice of the system.
3. The terminal plays `bellTerminal` for BEL, at most once in 100 ms. `Screen.swift` drops BEL now.
4. The volume keys: the compositor changes the volume with `wpctl`, then plays `audio-volume-change`.
5. The Power app plays `power-plug`, `power-unplug`, and `battery-low` once when the charge crosses the low level.
6. A udev monitor in the compositor plays `device-added` and `device-removed` for a device that a person plugs in after the session started.
7. The compositor plays `desktop-logout` and waits 0.6 s before it asks systemd to power off. Otherwise systemd stops the player with the shell.
8. A screenshot key, which plays `screen-capture`.
9. A switch in Settings: sounds on or off, and a volume for event sounds. The lookup honours a `.disabled` file already.
10. Nobody has listened to the sounds on the machine yet. The check measures them; it cannot hear them.

## The system

- Root has no password. The Password pane of Settings gives it one. Add a user account for use outside a VM. Settings then needs a program of the system to change `/etc` for the user, such as `hostnamed` and `timedated`.
- The toolkit is one dynamic library, and the machine carries one copy of it (see [ui.md](ui.md#one-library-for-the-machine)). It has no stable ABI: the library and the programs must come from one build. `-enable-library-evolution` on the toolkit would make a new library work with the programs that are there already. Put `@frozen` on the types of the hot path with it: `Frame`, `Size`, `Color`, `Rect` and `Proposal`. Measure `make bench` after it: a resilient type reaches its fields through a function.
- The shell runs as root. A shell of a person wants a session of that person. logind gives the seat, and the files that the apps open are that person's files.
- The live system does not start the installer automatically.
- Sound (see [audio.md](audio.md)):
  - Ask Arch Linux ARM for `CONFIG_SND_VIRTIO=m` in `linux-aarch64`. Then `packages/virtio-snd` can go. Until then, each new kernel needs a new `pkgver` and new sums in that PKGBUILD, and a machine that updates its kernel with pacman has no sound until it gets a new package. DKMS would build the module on the machine, but it needs the compiler and the headers there.
  - The system sounds. The theme goes in `/usr/share/sounds/apus/`, and the shell plays a file with `pw-play`.
  - A volume control in the panel or in Settings. `wpctl set-volume @DEFAULT_AUDIO_SINK@ 50%` does it now.
  - The sound server runs as root, beside the shell. When the shell runs in the session of a person, use the `systemd --user` units of the packages.
  - The microphone is off by default (`VM_AUDIO=mic` turns it on), and no automated test uses it. The question of macOS for the microphone, on a Mac where nobody has answered it, is not tested.
  - The live system has no sound server, because it does not start the shell.

## Packages and the repository

- Sign the Apus packages. Make a `apus-keyring` package with the public key, as Arch Linux does.
- Publish the `[apus]` repository on a server. Add it to `/etc/pacman.conf` on installed systems. Then installed systems get updates of Apus packages.
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
- The GPU renderer sends the rows of a window that the app damaged to the GPU at each commit. The GPU can read a buffer of the app directly, with `EGL_WL_bind_wayland_display` or with dma-buf. That removes the copy.
- The GPU renderer draws one quad for each item. Items with the same texture and colour could go into one draw.
- `make gui` and `make demo` open a window. The automated tests do not test them. `tests/display.exp` and `tests/compositor.exp` test the same display with no window. In a window, the keyboard and the pointer are USB devices of the framework. The tests do not use those devices. They make their own with uinput.
- `make build` builds every package in `packages/` again, every time: `build.sh` removes the repository and runs `makepkg --cleanbuild --force` for each one. Two of them are Mesa (`apus-zink`, `vulkan-virtio`), which is most of the minutes of an image build. A package whose PKGBUILD and sources did not change could come from the repository of the last build.
- The tests use one VM disk in sequence. `tests/display.exp` and `tests/compositor.exp` need the disk from `tests/install.exp`.
- Old builder images use disk space. On 19 September, `container system df` reported 42 GB that `container image prune` can remove.

## Later

- x86_64 support.
- Real Mac hardware with Asahi Linux: its kernel, its boot chain, and its installer.
