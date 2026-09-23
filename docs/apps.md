# Writing an app

An app of Apus gives a view tree and gets a window. `AppClient` holds everything between the two. That is the connection, the surface, and the shared memory of the pixels. It is also the size that the compositor asks for, and the pointer and the keys.

```swift
import AppClient
import Toolkit

let window = AppWindow(title: "System", appID: "org.apus.system")
window.body = { SystemView(readings: readings) }
window.run()
```

`ui/Sources/SystemMonitor` is the whole of an app written this way. It is worth reading before you write one. `ui/Sources/SettingsApp` is a larger one: its views are a module of the toolkit package, so that the Mac tests them, and the program holds only the window and the files of the system. See [settings.md](settings.md).

## What the window gives you

| | |
| --- | --- |
| `body` | The view tree, asked for again on every frame |
| `size`, `sizeClass` | The room that the layout gave the window, in points |
| `sizeChanged` | Called after the size changes |
| `onKey` | The keys that no view of the app took |
| `everySecond` | For an app that shows something that changes on its own |
| `setNeedsDraw()` | Asks for a frame |
| `close()` | Ends `run()` |

The pointer, the wheel and the keys go through `ViewHost`. So `onHover`, `onPress`, `onTapGesture`, `onKey` and `ScrollView` work in an app exactly as they do in the shell, and an app writes no Wayland code.

A key that is held repeats. The window reads the rate and the delay from `wl_keyboard.repeat_info`, asks xkbcommon whether the key repeats (a modifier does not), and gives the views the key again at that rate, as a press. A view cannot tell a repeat from a press. The clock is `KeyRepeat` in the toolkit, and the terminal uses it too.

## Two user interfaces

`sizeClass` says how much room the window has: `widget`, `compact` or `large`. It comes from the size that the compositor proposed, so an app knows what to draw before it draws anything. See [layouts.md](layouts.md).

A tile is 256 points across. A tile is not the window made smaller. It keeps the one thing that a person wants from the corner of an eye, and it drops everything that needs reading. The system monitor keeps the part of the processor that is busy. The terminal states what the shell is doing and shows the last lines of it.

```swift
window.body = {
    window.sizeClass == .widget ? AnyMonitor(MonitorTile(...)) : AnyMonitor(MonitorWindow(...))
}
```

## The colours

An app does not link `Shell`, which is the user interface of the system. An app that wants the colours of the design writes them down. `ui/Sources/SystemMonitor/MonitorView.swift` has them in an `Ink` enum at the top.

## The bundle

A program becomes an app with a bundle in `ui/Apps/<Name>.app`. See [applications.md](applications.md).

```
id = org.apus.system
name = System
exec = bin/apus-system
color = 49C7C7
```

`make build` puts the bundle in `/Applications` and the program inside it.

`make test-dev` runs the programs of a directory in place of the installed ones, but it reads the bundles of the image. A new app therefore needs `make build` once before a test can reach it.

## The terminal

The terminal does not use `AppClient`. It draws a grid of characters rather than a view tree, and it reads the keys as bytes for a pseudo terminal. So it has Wayland code of its own. Its tile is a view tree, in `ui/Toolkit/Sources/Terminal/Widget.swift`, which the Mac tests.
