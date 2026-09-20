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
| A buffer, and no minimum | The size of the buffer it last committed |
| Nothing yet | The proposal, and a tile on a side that the proposal leaves free |

A foreign app needs no code path of its own. It is a window that answers a proposal the layout cannot satisfy. Every layout must handle that case anyway, because an app of the toolkit can also answer badly.

## What a window that does not fit does

A window that the layout does not place waits in the rail. It stays open and it keeps its state. The rail shows a short bar for it, and the shell draws a stand-in where the window would have been.

This happens when a window answers a size that a tile cannot hold: more than 384 points long, or more than a tile is wide. A terminal that drew 784 points tall cannot use a tile of 256, so it waits.

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

Each of two windows gets half of the canvas, less the gap. Every window after the second waits in the rail.

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
| `ui/Sources/Compositor/WindowArrangement.swift` | How a window answers a proposal |
| `ui/Toolkit/Tests/ShellTests/WindowLayoutTests.swift` | The behaviour of each layout, as tests |

The layouts are in the toolkit package, so the Mac runs their tests in seconds. They know nothing about Wayland: a layout sees children that answer proposals, and a window is one kind of child.
