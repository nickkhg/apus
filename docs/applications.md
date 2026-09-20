# Applications

An app of mydistro is a bundle in `/Applications`. The compositor reads the bundles when it starts. The dock shows one icon for each bundle. A click on an icon starts the app, and the app gets the space between the panel and the dock.

## A bundle

A bundle is a directory with a name that ends in `.app`. It holds a manifest, and usually the program:

```
/Applications/Terminal.app/
├── app.conf                the manifest
└── bin/mydistro-terminal   the program
```

The manifest is a list of `key = value` lines. A line that starts with `#` is a comment.

| Key | Content |
|---|---|
| `id` | The id of the app, for example `org.mydistro.terminal`. A window of the app gives the same id in `xdg_toplevel.set_app_id`, so the shell knows which app the window belongs to. |
| `name` | The name in the dock. The icon shows its first letter. |
| `exec` | The program: a path in the bundle, or an absolute path. |
| `color` | The colour of the icon, as `RRGGBB`. |

```
id = org.mydistro.terminal
name = Terminal
exec = bin/mydistro-terminal
color = 3BB273
```

A bundle needs an `id`, a `name`, and a program that exists. The compositor drops a bundle without them, and writes a line about it on the console. The dock shows the other bundles by name.

## The bundles in the image

The source of a bundle is a directory in `ui/Apps/`. The `mydistro-ui` package copies it to `/Applications`:

| Bundle | Program | Content |
|---|---|---|
| `Hello.app` | `/usr/bin/mydistro-hello-client` | The test client of the compositor: one coloured window. |
| `Terminal.app` | `bin/mydistro-terminal` in the bundle | The terminal. |

A bundle that names a program with a path in the bundle gets that program from the build. The program is then in the bundle only, and not in `/usr/bin`.

To add an app:

1. Add the program to `ui/Package.swift`, as a product with a name that starts with `mydistro-`.
2. Make the directory `ui/Apps/<Name>.app` with an `app.conf` in it.
3. Run `make build`.

## How an app starts

1. The pointer clicks an icon in the dock.
2. The dock asks the compositor: `ShellActions.openApp(id)`.
3. If a window of that app is open, it comes to the front and gets the keyboard.
4. If no window is open, `posix_spawn` starts the program of the bundle. The child gets the environment of the compositor, which has `WAYLAND_DISPLAY` in it, and a session of its own. The compositor does not wait for the child.
5. The app connects, and it opens a window. The compositor puts the window in the app area and gives it the keyboard. A dot under the icon says that the app is open.

The compositor writes `APP-STARTED <id> pid <number>` on the console, and `WINDOW-MAPPED` when the window comes.

`MYDISTRO_UI_DIR` changes which program starts: a program of that directory takes the place of the program of a bundle with the same name. `make demo-dev` and `make test-dev` set it, so that a click in the dock starts the new build.

## The app area

The app area is the space between the panel and the dock. On a screen of 1280 × 800 pixels it is 1280 × 675, at y 28.

- `RootView.windowArea(screen:)` gives the area. The shell computes it from the height of the panel, the height of the dock, and the space under the dock. Thus the shell decides how much space it keeps, and the compositor asks.
- The first configure event of a window gives that size, with the states `maximized` and `activated`. An app that answers with the size draws exactly the area.
- An app can keep another size. The compositor then puts the window in the middle of the area.
- The windows are behind the shell. The panel and the dock stay visible, because the compositor draws them after the windows.

## The terminal

`mydistro-terminal` is a window with a shell in it. It shows what the toolkit and the compositor can do together: text, the keyboard, and an app that fills the app area.

```
the pseudo terminal            the window
/bin/bash ─── bytes ───▶ Screen ─── cells ───▶ Grid ─── items ───▶ wl_shm buffer
          ◀── keys ──── Keyboard ◀── wl_keyboard ─── the compositor
```

| Part | File | Purpose |
|---|---|---|
| The grid | `ui/Toolkit/Sources/Terminal/Screen.swift` | The characters on the screen, and the parser for the escape sequences that a program writes. |
| The drawing | `ui/Toolkit/Sources/Terminal/Grid.swift` | The grid as drawing items. One run of the same colours becomes one `Text` of the toolkit. |
| The pseudo terminal | `ui/Sources/TerminalApp/PTY.swift` | Opens the terminal, starts the shell in a session of its own, and reads and writes it. |
| The keys | `ui/Sources/TerminalApp/Keyboard.swift` | The keymap of the compositor, through xkbcommon. It makes the bytes that a program reads. |
| The window | `ui/Sources/TerminalApp/main.swift` | The Wayland client: the window, the buffer, and the loop that waits for the compositor and for the shell. |

The grid and the drawing are in the toolkit package, so the Mac tests them in a few milliseconds (`make test-ui`). The window and the pseudo terminal need Linux, and the VM tests them (`tests/compositor.exp`).

The terminal says `TERM=xterm-256color` to the programs in it. It understands the control characters, the cursor sequences and the erase sequences. It also understands the lines that scroll and the colours: 16 colours, 256 colours, and a colour of its own. It reads and drops the other sequences, and the title that a program sets. See the comment at the start of `Screen.swift` for the list.

The terminal ends when the shell in it ends. The Close button of the panel also ends it, because the app stops at `xdg_toplevel.close`.

### Limits of the terminal

- There is no text that a user can select, and no copy and no paste.
- There are no lines above the first line: what scrolls away is gone.
- The pointer does nothing in the window. An app gets no pointer events yet.
- A key does not repeat while it stays down.
- The terminal reads underline, italic and a cursor of another shape, and then drops them.
- One window. A second click on the icon brings the window to the front.
