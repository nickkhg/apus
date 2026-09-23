# Applications

An app of Apus is a bundle in `/Applications`. A program that came from a package is a desktop entry in `/usr/share/applications`. The compositor reads both, and Summon lists one line for each. A person chooses a line to start the app, and the layout gives the app a cell of the canvas.

## A bundle

A bundle is a directory with a name that ends in `.app`. It holds a manifest, and usually the program:

```
/Applications/Terminal.app/
├── app.conf                the manifest
└── bin/apus-terminal   the program
```

The manifest is a list of `key = value` lines. A line that starts with `#` is a comment.

| Key | Content |
|---|---|
| `id` | The id of the app, for example `org.apus.terminal`. A window of the app gives the same id in `xdg_toplevel.set_app_id`, so the shell knows which app the window belongs to. |
| `name` | The name that Summon shows. |
| `exec` | The program: a path in the bundle, or an absolute path. |
| `color` | The colour of the icon, as `RRGGBB`. |

```
id = org.apus.terminal
name = Terminal
exec = bin/apus-terminal
color = 3BB273
```

A bundle needs an `id`, a `name`, and a program that exists. The compositor drops a bundle without them, and writes a line about it on the console. Summon lists the other bundles by name.

## The bundles in the image

The source of a bundle is a directory in `ui/Apps/`. The `apus-ui` package copies it to `/Applications`:

| Bundle | Program | Content |
|---|---|---|
| `Hello.app` | `/usr/bin/apus-hello-client` | The test client of the compositor: one coloured window. It names a smallest size of 600 × 400, so no tile can hold it. The test uses it to check the card that stands in for a window with no cell. `--min-size WxH` or `--min-size none` changes that size. |
| `Terminal.app` | `bin/apus-terminal` in the bundle | The terminal. |
| `Settings.app` | `bin/apus-settings` in the bundle | The settings of the system. See [settings.md](settings.md). |
| `Files.app` | `bin/apus-files` in the bundle | The folders of the machine. See [files.md](files.md). |
| `Notes.app` | `bin/apus-notes` in the bundle | Short texts, as plain files in `~/Notes`. See [notes.md](notes.md). |

A bundle that names a program with a path in the bundle gets that program from the build. The program is then in the bundle only, and not in `/usr/bin`.

To add an app:

1. Add the program to `ui/Package.swift`, as a product with a name that starts with `apus-`.
2. Make the directory `ui/Apps/<Name>.app` with an `app.conf` in it.
3. Run `make build`.

## The apps of the packages

A program that comes from a package has no bundle. It has the desktop entry
that it ships, which pacman installs in `/usr/share/applications`:

```
/usr/share/applications/chromium.desktop
    [Desktop Entry]
    Type=Application
    Name=Chromium
    Exec=/usr/bin/chromium %U
```

`DesktopEntries.swift` reads those into the same list as the bundles, so
`pacman -S chromium` is all that a new app needs. Summon reads the list again
each time it opens, so an app that was installed a moment ago is in it
without a restart.

It reads the directories that the freedesktop.org specification names:
`$XDG_DATA_HOME/applications` (or `~/.local/share/applications`), and then
`$XDG_DATA_DIRS`, which is `/usr/local/share:/usr/share` by default. The
first file of a name wins.

| Key | What it does |
|---|---|
| `Type` | Must be `Application`. |
| `Name` | The name that Summon shows. |
| `Exec` | The program and its arguments. The field codes (`%u`, `%f`, …) stand for a thing to open, and Apus opens an app with nothing, so they go. |
| `TryExec` | When it names a program that is not there, the entry is dropped. |
| `NoDisplay`, `Hidden` | `true` drops the entry. |
| `Terminal` | `true` drops the entry: Apus cannot give a program a terminal to start in. |

The id of such an app is the name of its file without `.desktop`, which is
also the `app_id` that a Wayland window of it gives. A bundle of
`/Applications` with the same id wins, so an app of Apus keeps its name and
its colour.

A desktop entry names an icon of a theme, and Apus does not draw those, so
the tile of the app is a colour worked out from its id. It is the same colour
on every boot.

### Telling an app that it is on Wayland

A toolkit that can draw on more than one kind of display server picks one when
it starts, and most still pick X11 first. Each reads a variable of its own to
be told otherwise, and the compositor sets them all before it starts anything:

```
XDG_SESSION_TYPE=wayland     XDG_CURRENT_DESKTOP=Apus
GDK_BACKEND=wayland          QT_QPA_PLATFORM=wayland
SDL_VIDEODRIVER=wayland      CLUTTER_BACKEND=wayland
MOZ_ENABLE_WAYLAND=1         ELECTRON_OZONE_PLATFORM_HINT=auto
```

That is how a program that knows nothing about Apus comes up on it without
being told anything about it. Apus has no X server, so there is nothing to
fall back to: an app that cannot draw on Wayland fails, and says so.

Each one is set over whatever was there. systemd starts the shell as a service
on tty1 and sets `XDG_SESSION_TYPE=tty`, which says how the compositor was
started, not what it offers the apps that it starts; an app that reads that
value goes looking for an X server. To give one app a different value, put
`env` in front of the program in a desktop entry of your own.

### An app that needs a command line option

Some programs take an option rather than a variable, and the packaged desktop
entry does not pass it. Chromium is one: it picks X11 unless it is given
`--ozone-platform=wayland`, and it refuses to run as root without
`--no-sandbox`.

There is no key in any package format that says such a thing, so there is no
way to know it from the package. The answer is the one that every Linux
desktop uses: a desktop entry of your own, which wins over the packaged one.

```sh
mkdir -p ~/.local/share/applications
sed 's|^Exec=.*|Exec=/usr/bin/chromium --no-sandbox --ozone-platform=wayland %U|' \
    /usr/share/applications/chromium.desktop > ~/.local/share/applications/chromium.desktop
```

`--no-sandbox` is needed only because Apus runs everything as root. A program
that refuses to run as root is right to: that is the reason, and an ordinary
user account is the fix.

## How an app starts

1. The Super key opens Summon. A person types to narrow the list, and presses Enter.
2. Summon asks the compositor: `ShellActions.openApp(id)`.
3. If a window of that app is open, it comes to the front and gets the keyboard.
4. If no window is open, `posix_spawn` starts the program of the bundle. The child gets the environment of the compositor, which has `WAYLAND_DISPLAY` in it, and a session of its own. The compositor does not wait for the child.

   The child also gets its signals back. A signal that a process ignores, and a signal that it blocks, both cross `exec`, and the compositor does both: it ignores `SIGCHLD` so that it never has to wait for an app, and its event loop blocks `SIGINT` and `SIGTERM` to read them from a file descriptor. Neither belongs to the app, so `posix_spawn` sets every signal back to its default action with an empty mask (`AppCatalog.resetSignals`). `apus-terminal` does the same for the shell it starts.

   A program that inherits an ignored `SIGCHLD` cannot wait for its own children: the kernel takes each one away as it ends, and `waitpid` answers `ECHILD`. pacman does that for every package it installs and every hook it runs, so an install inside Apus failed on all of them. A program that inherits a blocked `SIGINT` cannot be stopped with Ctrl+C.
5. The app connects, and it opens a window. The layout gives the window a cell, and the window gets the keyboard.

The compositor writes `APP-STARTED <id> pid <number>` on the console, and `WINDOW-MAPPED` when the window comes.

## An app that starts holds a cell

An app takes a cell from the moment a person chooses it, and not from the moment its window appears. A person therefore sees the app in the place where it will be, instead of an unchanged screen.

- While the program runs and no window has come, the cell says that the app is starting.
- The window takes the cell when it comes, and the app is open.
- An app that opens no window in ten seconds did not start. The cell then names the app, says what went wrong, and shows the program that the bundle names. It has two controls: one starts the app again, and one takes the cell away.

The compositor writes `APP-DID-NOT-START <id>` on the console when it gives up.

A cell that says "did not start" is where a person is already looking, which a line on a console is not.

`APUS_UI_DIR` changes which program starts: a program of that directory takes the place of the program of a bundle with the same name. `make demo-dev` and `make test-dev` set it, so that Summon starts the new build.

## The canvas

The canvas is the screen without the rail. On a screen of 1280 × 800 pixels it is 1200 × 784, at 72, 8.

- `RootView.windowArea(screen:)` gives the canvas. The shell computes it from the width of the rail and the gaps around it. Thus the shell decides how much space it keeps, and the compositor asks.
- A layout owns every point of the canvas. A window never floats, and a window never covers another window. See [layouts.md](layouts.md).
- The first configure event of a window gives the size of its cell, with the states `maximized` and `activated`.
- An app can commit a buffer of another size. The compositor then puts the buffer in the middle of the cell and cuts it to the cell.
- The windows are behind the shell. The rail stays visible, because the compositor draws it after the windows.

## The terminal

`apus-terminal` is a window with a shell in it. It shows what the toolkit and the compositor can do together: text, the keyboard, and an app that fills the app area.

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

### The keys

The compositor sends each key once when it goes down and once when it goes
up. A key that is held repeats in the app, as Wayland has it: the compositor
says how with `wl_keyboard.repeat_info`, which on Apus is 25 times a second
after 600 ms, and the terminal sends the bytes of the key again at that rate
until the key goes up, another key goes down, or the window loses the keys.

- xkbcommon says which keys repeat (`xkb_keymap_key_repeats`). Shift,
  Control, Alt and Caps Lock do not.
- A rate of 0 is no repeat.
- A held key is read again each time it goes: Shift pressed while a letter
  repeats stops the repeat, because a person who presses a second key means
  that one.
- `Shift+Page Up` and `Shift+Page Down` repeat, and scroll on. Copy and
  paste do not: a held `Ctrl+Shift+V` pastes once.

The clock of the repeat is `KeyRepeat` in the toolkit
(`ui/Toolkit/Sources/Toolkit/KeyRepeat.swift`), so the Mac tests it. The
loop of the terminal waits in `poll` no longer than the time to the next
repeat. The apps of `AppClient` use the same clock. See [apps.md](apps.md).

### Scrolling back

The terminal keeps the lines that go off the top of the screen — 5000 of them
— and the wheel scrolls back into them. A trackpad works the same way: the
compositor sends `wl_pointer.axis` to the window under the pointer, with
`axis_source` saying whether a wheel or a finger made it, and the terminal
turns that into lines.

While the view stands above the live screen, the cursor is not drawn: it
marks a place that the view is not showing. Typing brings the view back to
the live screen, as every terminal does. Output does not: text that arrives
while a person is reading moves the screen underneath the view, and the same
lines stay in front of them.

Only the whole screen scrolling counts as history. A program that scrolls a
part of the screen, such as an editor with a status line, is drawing rather
than printing, and what it moves is not something to read back.

### Selecting and pasting

Drag with the left button to select, `Ctrl+Shift+C` to copy, `Ctrl+Shift+V`
to paste. What is copied goes on the clipboard of the system and on the
clipboard of the Mac. See [clipboard.md](clipboard.md).

### Limits of the terminal

- A selection is by character. There is no selecting a word or a line, and no
  rectangular selection.
- There is no primary selection: a selection is not on the clipboard until
  `Ctrl+Shift+C`, and the middle button does not paste.
- A paste is not bracketed, so a paste of several lines runs all but the last.
- The terminal reads underline, italic and a cursor of another shape, and then drops them.
- One window. A second click on the icon brings the window to the front.
