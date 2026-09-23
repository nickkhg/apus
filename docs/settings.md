# Settings

`apus-settings` is the app that changes the system: the name of the machine, the clock, the password of root, the screen, the keys, the network, the apps that Summon lists, and the power. Press Super, type `settings`, and press Enter.

Each pane changes a real file or asks a real program of the system. Nothing is kept in a file of the app itself. A change that you make with a command in the terminal therefore shows in Settings too, and the reverse.

## The parts

| Part | Where | What it holds |
|---|---|---|
| The panes | `ui/Toolkit/Sources/Settings/` | The views, the keys, and the parsers of the files. The Mac tests them (`make test-ui`). |
| The app | `ui/Sources/SettingsApp/` | The window, and `Machine`: what reads the files of the system and what changes them. |
| The bundle | `ui/Apps/Settings.app` | `org.apus.settings`, colour `8E9BF0`. |

The panes read a `Snapshot`, and they ask for a change through the `SettingsSystem` protocol. `Machine` is the one that runs on Apus. The tests give a machine of their own (`ui/Toolkit/Tests/SettingsTests/Machine.swift`), so a test can press keys and see what Settings asked for, with no VM.

## What each pane reads and writes

| Pane | Reads | Writes |
|---|---|---|
| About | `gethostname`, `/etc/os-release`, `uname`, `/proc/meminfo`, `statvfs("/")`, `/etc/apus-installed`, `/proc/cmdline`, `/proc/uptime`, `/etc/machine-id`, `systemd-detect-virt` | `/etc/hostname` and `sethostname` |
| Date & Time | The link `/etc/localtime`, `/usr/share/zoneinfo/zone1970.tab`, the link that enables `systemd-timesyncd`, `/run/systemd/timesync/synchronized` | The link `/etc/localtime`. `systemctl enable --now` or `disable --now systemd-timesyncd` |
| Password | The line of root in `/etc/shadow` | `chpasswd` with the new password on its standard input, or `passwd -d root` |
| Display | `/sys/class/drm/*/status` and `modes`, the environment of the app, the drop-in | The drop-in, then `systemctl daemon-reload` |
| Keyboard | The environment of the app, the drop-in | The drop-in, then `systemctl daemon-reload` |
| Network | `/sys/class/net`, `getifaddrs`, `/proc/net/route`, `/run/systemd/resolve/resolv.conf` | `networkctl reconfigure` for Renew |
| Apps | `/Applications/*.app/app.conf`, and the desktop entries in the directories that the compositor reads | A desktop entry of your own that hides the app |
| Power | `/proc/uptime`, `/proc/loadavg` | `systemctl --no-block restart apus-shell.service`, `systemctl reboot`, `systemctl poweroff` |

A write goes to a file beside the target, and then the file takes the name of the target. A program that reads the file sees the old file or the new file, never a part of one. `/etc/localtime` is a link, and Settings makes the new link in the same way.

### The time zone

The zone is the link `/etc/localtime`. It points into `/usr/share/zoneinfo`, as the build makes it and as `timedatectl set-timezone` makes it. glibc reads the link again only when a program calls `tzset`, so both Settings and the clock of the rail call it before they read the time. A new zone therefore shows in the rail within a second, without a new start of the compositor.

Type in the pane to find a zone. The query matches the city, the region and the country code, in the same way as Summon matches a query.

### The screen and the keys: the drop-in

The compositor reads the renderer, the mode, the scale and the layout of the keys from its environment when it starts. It does not read them again. So Settings writes them for the next start, in a drop-in of the service:

```
/etc/systemd/system/apus-shell.service.d/50-settings.conf
    [Service]
    Environment=APUS_RENDERER=gpu
    Environment=APUS_SCALE=2
    Environment=XKB_DEFAULT_LAYOUT=de
    Environment=XKB_DEFAULT_OPTIONS=ctrl:nocaps
```

| Control | Variable | Read by |
|---|---|---|
| Renderer | `APUS_RENDERER` | `Screen.swift`. See [ui.md](ui.md#the-two-renderers). |
| Surfaces | `APUS_SHELL_MODE` | `Compositor.chosenShellMode`. See [toolkit.md](toolkit.md#the-two-modes). |
| Scale | `APUS_SCALE` | `Compositor.chosenScale` |
| Layout, variant | `XKB_DEFAULT_LAYOUT`, `XKB_DEFAULT_VARIANT` | xkbcommon, when the compositor makes its keymap |
| Caps Lock, Alt and Super, Compose | `XKB_DEFAULT_OPTIONS` | xkbcommon |

The keymap of the compositor comes from `xkb_keymap_new_from_names` with no names, so xkbcommon takes the names from these variables. Every app gets the keymap from the compositor, so one layout is the layout of every app.

A setting at its default is not in the file, and a file with nothing in it is removed. The shell then decides as it does with no file.

Each of the two panes keeps a draft. **Save** writes the drop-in, and the notice has a control that starts the shell again. The foot of the pane says which of three states the settings are in:

| The foot says | Meaning |
|---|---|
| NOT SAVED | You changed something, and the file does not have it. |
| SAVED, the shell starts with these next time | The file has it, and the shell that runs now does not. |
| The shell runs with these now | The file and the shell agree. |

What the shell runs with comes from the environment of the app. An app gets the environment of the compositor that started it, so that is also the environment of the compositor.

A shell that `make demo` or a test started is not the service, and the drop-in does not change it. Settings knows this from its control group: an app of the service is in `/apus-shell.service`. It then says so, and it does not offer to start the shell again.

### The apps

The apps of `/Applications` are always in Summon. An app of a package is in Summon unless its desktop entry says `NoDisplay=true`. To hide one, Settings copies its desktop entry to `~/.local/share/applications` (or `$XDG_DATA_HOME/applications`) with `NoDisplay=true`. The first file of a name wins, so the copy hides the app, and a new version of the package does not show it again. The first line of the copy says that Settings wrote it. To show the app again, Settings removes that file, and only a file with that line.

Summon reads the list each time it opens, so the change needs no new start.

### Power

Each of the three controls asks for a second click within five seconds. The shell starts again with `--no-block`, because the app stops with the shell and cannot wait for the answer.

## The keys

The toolkit has no focus. Settings keeps its own: the sidebar or the pane has the keyboard, and the accent marks the one that has it.

| Key | In the sidebar | In a pane |
|---|---|---|
| Up, Down | Go to another pane | Move in the list of the pane |
| Enter, Right, Tab | Give the keyboard to the pane | Choose the selected line. In About, change the name. In Password, type a password. |
| Space | | Show or hide the selected app |
| Escape, Left, Tab | | Give the keyboard back to the sidebar. In Date & Time, clear the query first. |
| A letter | In Date & Time, start to find a zone | In Date & Time, find a zone |

In a field, Enter keeps the text and Escape does not. In Password, Tab moves between the two fields, and Settings does not keep a password after it gives it to `chpasswd`.

## Three sizes

| Size class | What Settings draws |
|---|---|
| `large` | The sidebar of 212 points, and the pane |
| `compact` | A sidebar of 168 points, and less space around the pane |
| `widget` | A tile: the time, the zone, the name, the address, and a warning when root has no password |

## Limits

- Settings runs as root, as every app on Apus does. When Apus has user accounts, the changes to `/etc` need a program of the system that does them for the user, such as `hostnamed` and `timedated`.
- The Network pane shows the wired and wireless interfaces, but it cannot join a wireless network. Apus has no wireless daemon.
- The layout list has the layouts that most people use. xkeyboard-config has many more. To use another one, write its name in the drop-in yourself.
- A field of text has its caret at the end only, as the query of Summon has.
