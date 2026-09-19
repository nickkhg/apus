# Loose ends and next steps

## Next steps for the compositor

In this sequence:

1. Input for apps. Add `wl_seat` with `wl_pointer` and `wl_keyboard`. Send the keymap from xkbcommon. Send pointer events to the window under the pointer, and keyboard events to the focused window.
2. Window management. Click to focus and raise a window. Move a window with the pointer (`xdg_toplevel.move`). Close a window.
3. `wl_output`. Many apps need it to know the screen size and scale.
4. Damage tracking. Draw only the parts of the screen that changed.
5. Stop drawing when libseat disables the seat (for example on a VT switch), and start again when libseat enables it.
6. A GPU renderer. Use GBM, EGL, and OpenGL ES to draw the display list. Keep `SoftwareRenderer` as a fallback.
7. `linux-dmabuf`, so that apps can give GPU buffers.
8. Popups (`xdg_popup` and `xdg_positioner`).
9. Test with real Wayland apps, for example `foot` or `weston-terminal`.

## The UI layer

- Make the first shell UI (for example a panel and window title bars) as display list items.
- Test OpenSwiftUI on Linux again with each new release. See [decisions.md](decisions.md).
- If OpenSwiftUI is not ready, examine other options: a small declarative layer of our own, or swift-cross-ui with a mydistro backend.
- Text rendering with FreeType and HarfBuzz. The modules exist. No code uses them yet.

## The system

- Root has no password. Add a user account and a password for use outside a VM.
- Start the compositor at login, or with a display manager, as a normal user through logind.
- `make gui` gives a text login on tty1. The compositor does not start on tty1 automatically.
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
- A GPU in the VM needs a QEMU with `virtio-gpu-gl`, for example from UTM.
- `make gui` and `make demo` open a window. The automated tests do not test them. `tests/display.exp` and `tests/compositor.exp` test the same display with no window.
- The tests use one VM disk in sequence. `tests/display.exp` and `tests/compositor.exp` need the disk from `tests/install.exp`.
- Old builder images use disk space. On 19 September, `container system df` reported 42 GB that `container image prune` can remove.

## Later

- x86_64 support.
- Real Mac hardware with Asahi Linux: its kernel, its boot chain, and its installer.
