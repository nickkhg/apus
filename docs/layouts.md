# Layouts

A layout puts the windows on the canvas. A window never floats, and a window never covers another window. The layout gives every window its frame. That is the only way a window gets one.

## The negotiation

A layout and a window agree on a size in three steps. This is the model of SwiftUI's `Layout`, and `xdg_toplevel.configure` already works the same way.

1. The layout proposes a size. It can leave one side unspecified, which asks the window for its own length on that side.
2. The window answers with the size that it wants.
3. The layout places the window. The frame can differ from the answer, because the layout owns the space and the window does not.

The compositor cannot call into a window, because a window is another process. So a window answers from what the protocol already carries:

| What the window sent | The answer |
| --- | --- |
| `xdg_toplevel.set_min_size` | That size, or the proposal when the proposal is larger |
| No minimum | The proposal, and a tile on a side that the proposal leaves free |
| A resize of its tile (see [Moving and resizing](#moving-and-resizing)) | On a side that the proposal leaves free, the length that the resize gave it, or the minimum when that is larger |

The size that a window last drew is not its answer. An app that drew a large window would then answer a large length for a tile. No app could take a tile after it drew once. The app answers the real question by drawing: the layout gives it the tile, and the app commits a buffer for that size. An app that names a minimum larger than a tile is the one case that needs no round trip.

A foreign app needs no code path of its own. It is a window that answers a proposal the layout cannot satisfy. Every layout must handle that case anyway, because an app of the toolkit can also answer badly.

## Moving and resizing

An app asks to move its window with `xdg_toplevel.move`, and to change its size with `xdg_toplevel.resize`. It asks after a press on its own title bar or its own edge, and it names the serial of that press. On a desktop where windows float, the window then follows the pointer and stays where the pointer leaves it. Here no window floats, so the compositor reads each request as a change to the arrangement. The layout still gives every window its frame.

The compositor takes a request only while the button of that press is still down, and only for the window that got the press. Any other request is ignored, as the protocol allows.

### A move

The window follows the pointer while the button is down. It is drawn over everything else, and its cell keeps only the head. When the button comes up, the window changes places with the window whose cell is under the pointer. A stand-in counts as a cell, so a window can change places with a window that waits in the rail. A window dropped on its own cell, on the rail or on an empty part of the canvas goes back to its cell.

| Layout | What a move does |
| --- | --- |
| Principal and widgets | A tile dropped on the large cell becomes the principal. The principal dropped on a tile becomes that tile, and the tile takes the large cell. Two tiles change places in the band. |
| Side by side | The two halves change places. |
| Grid | Two cells change places. |
| Full | Nothing. There is one cell, so the move is refused. |

Side by side and in the grid, the window that moved keeps the keys. In Principal and widgets the keys go with the large cell (see [A click](#a-click)), so after a move they belong to the window that is in it.

A move changes places rather than inserting the window between two others. A swap moves two windows, and a person can see both of them before the release. An insert would move every window after the drop point.

### A resize

The layout owns every size. A resize moves only an edge that a layout lets a person move, and every other resize is refused. The app then keeps the pointer as if it had not asked.

| Layout | The edge that moves | Why the others do not |
| --- | --- | --- |
| Principal and widgets | An end of a tile, along the band. The length snaps to a whole 64 points, between 192 and 384. | A tile is 256 across on every screen, so that an app writes one widget user interface. The large cell takes what the band leaves, and the band is a whole number of tiles across. |
| Side by side | The edge between the two windows. Neither side gets less than 360 points, so neither becomes a widget. | The outer edges are the edges of the canvas. |
| Grid | None | Every cell has the size of the others. |
| Full | None | The window has the whole canvas. |

The length of a tile stays with the window. It is the window's answer from then on (see the table in [The negotiation](#the-negotiation)), so it holds when the window leaves the band and comes back. It never goes over 384, so a resize never takes a window out of the band. The edge between two windows side by side stays where a person put it, as a part of the canvas. It keeps its place when the screen changes size.

While the edge follows the pointer, the window gets a configure with each new size and the `resizing` state. The release sends one more configure, without `resizing`.

### A click

A click gives a window the keys. What else it does depends on the layout:

- In Principal and widgets, the keys and the large cell never belong to two different windows. A click on a tile therefore brings the tile into the large cell. It goes there when the button comes up, not when it goes down: in the large cell the window would no longer be under the pointer that holds it. The app reads the press and the release in the tile where the person clicked.
- In Full only the window with the keys shows.
- Side by side and in the grid, the cells have one rank. A click gives the window the keys and moves nothing. The accent line of its head says that it has them.

Summon and the rail still bring a window to the first place, in every layout, because that is how a window that waits in the rail gets a cell. A change to Principal and widgets or to Full puts the window with the keys in the first place, so it keeps them.

## What a window that does not fit does

A window that the layout does not place waits in the rail. It stays open and it keeps its state. The rail shows a short bar for it, and the shell draws a stand-in where the window would have been.

This happens when a window answers a size that a tile cannot hold: more than 384 points long, or more than a tile is wide. A terminal that drew 784 points tall cannot use a tile of 256, so it waits.

## What the shell keeps of a cell

A layout gives a window a cell. The shell keeps the top 32 points of it for a head, and 8 points on the other three sides. The window draws in the rest. A cell of 1200 × 784 at 72, 8 gives the window 1184 × 744 at 80, 40.

The head names the app and the window, and says which class the window has. It holds two controls. One closes the window. The other takes the window out of the large cell, so that it becomes a tile. A line in the accent colour along the top says which window has the keyboard.

A tile keeps nothing. A tile is 256 points across, and a bar of controls would take a tenth of it. An app draws its own name inside its widget user interface instead.

## The four layouts

A person picks one. The rail has a button for it, and Summon lists them as commands.

| Layout | Key | What it does |
| --- | --- | --- |
| Principal and widgets | Super 1 | One window in the large cell, the others as tiles in a band |
| Side by side | Super 2 | Two windows, each with half of the canvas |
| Grid | Super 3 | Every window in a cell of a grid, up to nine |
| Full | Super 4 | One window with the whole canvas |

### Principal and widgets

The first window takes the large cell. The band of tiles sits on the long edge of the canvas. A wide screen puts it in a column on the right. A tall screen puts it in a row along the bottom.

- A tile is 256 points across on every screen, so an app writes one widget user interface for one width. Only the length of a tile changes.
- The layout proposes 256 across and leaves the length free. It then takes the answer up to a whole 64 points, and holds it between 192 and 384.
- Tiles start at the top and do not stretch. The leftover space stays empty, so a tile never moves when another window opens.
- The band takes a second column only while the large cell keeps 720 points. The band must also stay inside a third of the canvas. That gives one column at 1280, two at 1920, and three at 2560.

On a screen of 1280 × 800 the canvas is 1200 × 784. With one window the cell is the whole canvas. With two windows the large cell is 936 × 784 and the band starts at x 1016.

### Side by side

Each of two windows gets half of the canvas, less the gap, until a person moves the edge between them. Every window after the second waits in the rail.

### Grid

The grid is as square as the count allows: `columns = ceil(sqrt(n))`. A cell whose shorter side is 320 points or less carries the widget class, so a window draws its widget user interface in it. Every window after the ninth waits in the rail.

### Full

One window takes the canvas. Every other window waits in the rail.

## The size class

A window must know which user interface to draw while it answers, so the class comes from the proposal and not from the frame. The shorter side decides.

| Class | The shorter side |
| --- | --- |
| `widget` | 320 points or less |
| `compact` | 321 to 640 points |
| `large` | more than 640 points |

## Where the code is

| File | What it holds |
| --- | --- |
| `ui/Toolkit/Sources/Toolkit/Layout.swift` | The `Layout` protocol, `LayoutSubview` and `AnyLayout` |
| `ui/Toolkit/Sources/Shell/WindowLayout.swift` | The four layouts, the sizes and the size class |
| `ui/Toolkit/Sources/Shell/WindowGesture.swift` | What a move, a resize and a click mean in each layout |
| `ui/Sources/Compositor/WindowArrangement.swift` | How a window answers a proposal |
| `ui/Toolkit/Tests/ShellTests/WindowLayoutTests.swift` | The behaviour of each layout, as tests |
| `ui/Toolkit/Tests/ShellTests/WindowGestureTests.swift` | The rules of a move, a resize and a click, as tests |

The layouts are in the toolkit package, so the Mac runs their tests in seconds. They know nothing about Wayland: a layout sees children that answer proposals, and a window is one kind of child.
