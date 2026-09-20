# Toolkit

The toolkit is the declarative user interface layer of mydistro. It has the shape of SwiftUI: a view is a value, and the `body` of a view says what it contains.

The toolkit and the shell are a Swift package of their own, in `ui/Toolkit/`. **Write your UI in `ui/Toolkit/Sources/Shell/`.** The rest of `ui/` is the display server, and you rarely change it.

```swift
HStack(spacing: 12) {
    Text("mydistro").font(.headline).foregroundColor(Color(hex: 0xC8A8F0))
    Spacer()
    Text("14:05")
}
.padding(.horizontal, 12)
.frame(maxWidth: .infinity, maxHeight: .infinity)
.background(Color(hex: 0x1B1626))
```

## Why not OpenSwiftUI

OpenSwiftUI is an open-source implementation of SwiftUI. It needs an attribute graph: the engine that keeps the values of a view up to date. On Apple platforms it uses Apple's private AttributeGraph framework. On Linux it uses OpenAttributeGraph.

A test on 20 September (OpenSwiftUI at commit `5af2b2b`, newer than release 0.21.0) gave this result:

| Step | Result |
|---|---|
| Build OpenAttributeGraph for Linux | Complete in 4 seconds. Its 51 tests pass. |
| Build OpenSwiftUI for Linux | Complete in 46 seconds, with warnings only. |
| Start an app with one view | Segmentation fault in `GraphHost.Data.updateSeed`, in `AppGraph.instantiate()`. |

The cause is not a small error. In `Sources/OpenAttributeGraphCxx/Attribute/OAGAttribute.cpp`, all 29 attribute operations are `// TODO`: `OAGGraphCreateAttribute` gives a null attribute, `OAGGraphGetValue` gives a null pointer, and `OAGGraphAddInput`, `OAGGraphUpdateValue` and `OAGGraphInvalidateValue` do nothing. The first read of an attribute value uses the null pointer. The OpenSwiftUI documentation says the same thing: "the cross-platform OpenAttributeGraph is not fully implemented".

To use OpenSwiftUI on Linux, someone must first write the attribute graph: a demand-driven dependency engine with attribute bodies of any type, subgraphs, and invalidation. Also, OpenSwiftUI on Linux has no text layout and no event loop.

Thus, mydistro has a toolkit of its own. It is much smaller, it is complete for what the shell needs, and every part of it is in this repository. See [decisions.md](decisions.md).

## How it works

There is no dependency graph. Each frame lowers the view tree to layout nodes, and the nodes lay out and draw themselves:

1. The compositor makes a view, for example `RailView(state:)`.
2. `ViewRenderer` asks the view for its layout nodes. A composite view gives the nodes of its `body`. A primitive view (`Color`, `Text`, a stack, a modifier) makes its own node.
3. The root node gets the rectangle to fill. It asks each child for a size, then gives each child a frame.
4. Each node adds items to the display list: a fill or a bitmap. See [compositor.md](compositor.md#the-display-list).

A complete frame of the rail takes microseconds, because the shell is small. A dependency graph saves work in a large app. It costs much more code.

### Layout: a proposal and an answer

The parent proposes a size. The child answers with the size that it wants. The parent then puts the child in a frame.

| Proposal | Meaning | Example answer |
|---|---|---|
| A length | "You can have this much" | A colour takes all of it |
| `nil` | "How much do you want?" | A colour asks for 10, text asks for the width of its glyphs |
| `.infinity` | "How much can you take?" | A colour and a spacer have no limit |

A stack shares the length along its axis between the children. It gives the space to the least flexible child first, and each child gets an equal share of the space that remains. A child's flexibility is the difference between its largest and its smallest answer. Thus a view with a fixed size keeps its size, and a `Spacer` takes the remainder.

A stack is only as large as its children need. To make a stack fill its space, put `Spacer` in it, or use `.frame(maxWidth: .infinity, maxHeight: .infinity)`.

## Where the files are

```
ui/
├── Package.swift          mydistro-ui: the display server, for mydistro only
├── Sources/               THE SYSTEM
├── Apps/                  THE APP BUNDLES: one directory for /Applications
├── Sources/               THE SYSTEM
│   ├── Compositor/        screen, input, windows, apps, the display list
│   ├── Wayland/           the Wayland server
│   ├── DRMKit/  C*/       the kernel-facing libraries
│   ├── TerminalApp/       the terminal: the window and the shell in it
│   └── CompositorMain/  HelloClient/  DisplayProbe/  UICheck/
└── Toolkit/               A SWIFT PACKAGE: mydistro-toolkit
    ├── Package.swift
    ├── Sources/
    │   ├── Render/        the display list and the software renderer
    │   ├── Toolkit/       View, the layout, the text
    │   ├── Terminal/      the grid of characters of the terminal
    │   └── Shell/         YOUR UI
    │       ├── RootView.swift
    │       ├── Rail.swift
    │       ├── Summon.swift
    │       ├── Theme.swift
    │       └── WindowLayout.swift
    └── Tests/
```

| Module | Content |
|---|---|
| `Render` | `Rect`, `Bitmap`, `DisplayItem`, `DisplayList`, `Canvas`, and `SoftwareRenderer`. No other module of ours is below it. |
| `Toolkit` | The views, the layout, the text, and `ViewRenderer`. It makes display lists. It knows nothing about the screen or about Wayland. |
| `Shell` | What mydistro draws itself: the rail, Summon, the layouts, and `RootView`. |
| `Terminal` | What the terminal app draws: the grid of characters, and the escape sequences that change it. The app around it is `ui/Sources/TerminalApp/`. See [applications.md](applications.md). |

### The root view

`RootView` is the whole screen. The compositor draws it for each frame, over the windows of the apps and under the pointer:

```swift
public struct RootView: View {
    let state: ShellState
    let actions: ShellActions

    public var body: some View {
        VStack(spacing: 0) {
            RailView(state: state, actions: actions)
                .padding(Metrics.gap)
            Spacer()            // the app area: the windows are behind it
            SummonView(state: state, actions: actions)
                .padding(.bottom, DockView.bottomMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

To add a part to the interface, write a `View` in `ui/Toolkit/Sources/Shell/` and put it in the body of `RootView`.

`ShellActions` is what the shell can ask the compositor to do: open an app, and close the front window. The shell knows nothing about windows, processes or Wayland, so it asks. The dock icons and the Close button of the panel use these actions.

`ShellState` is what the compositor gives the shell for each frame: the apps in `/Applications`, the apps that are open, the window titles, and the time. Add a value to it when your UI needs more.

`RootView.windowArea(screen:)` says which part of the screen the windows use: the space between the panel and the dock. The compositor asks the shell, so the shell decides how much space it takes. See [applications.md](applications.md).

### The two systems

The toolkit package builds for mydistro and for macOS:

| Command | Builds for | Time | Use |
|---|---|---|---|
| `make test-ui` | macOS | Seconds | The usual test run while you write UI code |
| `make test-ui-linux` | mydistro (in the container) | Approximately 30 seconds | Before a commit |
| `make ui` | mydistro (cross, with the Swift SDK) | Approximately 3 seconds | Run it in the VM |

Because the package builds for macOS, Xcode gives code completion for the toolkit and the shell. Open `ui/Toolkit/Package.swift` in Xcode. For the display server, Xcode cannot do this (see [ui.md](ui.md#limits-of-xcode)).

The only platform-dependent code is in `FontCache.swift`: which directory the font files are in. On mydistro the font is DejaVu, and on the Mac it is Arial. Thus the same test measures different glyph widths, and the tests do not compare exact widths.

`ui/Toolkit/Package.swift` runs pkg-config for FreeType and HarfBuzz. `MYDISTRO_CROSS=1` stops this. `make ui` sets that variable, because then the Swift SDK supplies the include directories. Without this, pkg-config on the Mac answers with the macOS libraries of Homebrew.

## The views

| View | Purpose |
|---|---|
| `Color` | A colour, and a view that fills its space |
| `Text` | One line of text |
| `Button` | A view that does something when the pointer clicks it |
| `Spacer` | Space that grows |
| `Divider` | A line across a stack |
| `VStack`, `HStack`, `ZStack` | Children in a column, in a row, or on top of each other |
| `ForEach`, `Group`, `AnyView`, `EmptyView` | Containers |

| Shape | Purpose |
|---|---|
| `Rectangle` | A rectangle. It draws as a plain fill. |
| `RoundedRectangle(cornerRadius:)` | A rectangle with round corners |
| `Circle` | A circle in the middle of the space, as large as the shorter side |
| `Ellipse` | An oval that fills the space |
| `Capsule` | A rectangle with half-circle ends |

A shape takes the foreground colour, or the colour of `fill(_:)`. The renderer
draws the outline with smooth edges. To make a shape of your own, write a
`struct` that conforms to `Shape` and give it a `path(in:)` method.

| Modifier | Purpose |
|---|---|
| `.frame(width:height:alignment:)` | A fixed size |
| `.frame(minWidth:maxWidth:minHeight:maxHeight:alignment:)` | Limits on the size. Use `.infinity` to take the space. |
| `.padding(_:)`, `.padding(_ edges:_:)` | Space around the view |
| `.background(_:)` | A view behind this one, with the same frame |
| `.offset(x:y:)` | Moves the view after the layout |
| `.aspectRatio(_:contentMode:)`, `.scaledToFit()`, `.scaledToFill()` | Keeps the proportions |
| `.foregroundColor(_:)`, `.font(_:)` | The colour and the font for the views inside |
| `.onHover { isOver in ... }` | Called when the pointer comes over the view and when it leaves |
| `.onTapGesture { ... }` | Called when the pointer goes down and up again on the view |
| `.onPress { isDown in ... }` | Called while the pointer is down on the view, for a view that must look pressed |

A `body` uses `if`, `if`/`else`, `switch`, and `for` loops, as SwiftUI does.

`.foregroundColor(_:)` and `.font(_:)` set values that flow down the tree. Each view uses the value of the nearest modifier above it.

## State

A view is a value, and the toolkit makes the view tree again for each frame.
A value in a view thus cannot survive a frame. `@State` keeps the value
outside the view and connects it to the new view at the start of each frame.
A change to a state value asks for a new frame.

```swift
struct DockIcon: View {
    let item: DockItem
    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isHovered ? item.color : item.color.opacity(0.7))
            .frame(width: 44, height: 44)
            .onHover { isHovered = $0 }
    }
}
```

`$isHovered` gives a `Binding`, for a view that must change a value that
another view owns:

```swift
struct Row: View {
    @Binding var isOn: Bool
}
```

The name of a state value is the position of its view in the tree: the type
of the view, the number of views of that type before it in the same parent,
and the path from the root. `ForEach` adds the identity of the element, and
the two branches of an `if` are different places. Thus:

- A view that moves to another position gets the state of that position.
- A view that goes away loses its state.
- A row keeps its state when the rows change order, if `ForEach` knows the
  identity of the elements.

Only a view with a `body` can have state. A view that draws itself
(`Body == Never`) cannot.

`ViewState` holds the values, and `ViewHost` holds a `ViewState`. The
compositor keeps one host for the shell, so the values live as long as the
compositor. A test can give `ViewRenderer.render` a `ViewState` of its own.

## The pointer

`ViewHost` sends the pointer to the views:

```swift
let host = ViewHost()
host.needsUpdate = { screen.setNeedsFrame() }
let items = host.displayList(for: RootView(state: shell), in: screenRect)
host.pointerMoved(to: x, y: y)
host.pointerButton(pressed: true)
```

The host calls `onHover` when the pointer comes over a view, and again when
it leaves. It calls the handler one time for each change, not for each
movement of the pointer. A view under another view also hears the pointer,
because a view tree has no window order.

A click is a press and a release on the same view:

| Step | What the host does |
|---|---|
| The button goes down over a view | `onPress(true)` on the view in front at that place |
| The pointer leaves the view, with the button down | `onPress(false)`. The view is no longer pressed. |
| The pointer comes back | `onPress(true)` |
| The button goes up over the view | `onPress(false)`, then `onTapGesture` |
| The button goes up somewhere else | Nothing. There is no click. |

Only the view in front gets a click, and only the first button (`BTN_LEFT`)
counts. `.onPress { }` and `.onTapGesture { }` on the same view are one place
for the pointer, not two.

A `Button` puts the two together:

```swift
Button("Close") { actions.closeFrontWindow() }      // a title on a background

Button(action: { open(item) }) {                    // your own look
    Icon(item)
}
```

`Button(_:action:)` draws the button: a title on a round background that
becomes brighter under the pointer and darker while the pointer is down.
`Button(action:label:)` draws only the label, and the label decides how the
button looks. The dock icons use the second one.

## Text

`Text` uses two C libraries:

- HarfBuzz shapes the string: which glyphs to draw, and where.
- FreeType draws each glyph into a coverage map (0 to 255).

`FontCache` opens the font file, keeps one face for each font and size, and keeps each glyph that it drew before. The font is DejaVu, from the `ttf-dejavu` package. The `mydistro-ui` package depends on it, and the builder image has it for the tests.

`Text` makes one bitmap for the line and puts it in the display list. The colour comes from the environment.

## Add a view

1. Write a `struct` that conforms to `View`.
2. For a view that contains other views, write `var body: some View`. That is all.
3. For a view that draws, add `public typealias Body = Never`, write a `LayoutNode` subclass with `computeSize(fitting:)` and `render(in:into:)`, and make the node in `makeNodes(into:environment:)`.

A view of the interface goes in `ui/Toolkit/Sources/Shell/`. A view that every UI can use goes in `ui/Toolkit/Sources/Toolkit/`.

## Tests

`make test-ui` runs the 107 unit tests on the Mac, and `make test-ui-linux` runs the same tests on mydistro. They need no screen. `ui/Toolkit/Tests/ToolkitTests/` tests the layout, the modifiers, the shapes, the state, and the pointer. `ui/Toolkit/Tests/ShellTests/` tests the panel, the dock and the app area. `ui/Toolkit/Tests/TerminalTests/` tests the grid of the terminal and its escape sequences.

A test lays out a view in a rectangle and looks at the display list. For example, this is the test of a spacer:

```swift
let view = HStack {
    red.frame(width: 20)
    Spacer()
    green.frame(width: 30)
}
let items = fills(view, width: 100, height: 10)
#expect(items.map(\.0.x) == [0, 70])
```

`tests/compositor.exp` also checks the panel on the screen of the VM.

## Speed

`make bench` draws the shell into memory and gives the time of one frame.
On a Mac (M-series, 1280 × 800):

| Step | Time |
|---|---|
| Lay out the views and make the display list | 0.40 ms |
| Draw the items | 0.09 ms |
| A complete frame | 0.49 ms |

The compositor draws a frame only when something changes, so this is the cost
of a change, not of a second. In the VM the same work is slower, because Mesa
draws with the CPU.

Use `make bench` after a change that touches the layout or the renderer. A
frame that becomes 10 times slower is usually a layout error: a view that
takes the whole screen makes the renderer fill the whole screen.

## Points and pixels

A layout works in points. A point is one pixel on most screens and two on a
screen with small pixels, and `ViewRenderer` takes the scale. Only the
drawing items that come out of a layout are in pixels, so a view is the same
size on every screen.

A text view makes its glyphs at the size that it draws them at, so they are
sharp, and it reports its size in points, so a line breaks in the same place
whatever the screen is. A shape is a path, so it scales without steps.

The places that answer the pointer stay in points. The compositor divides the
position of the mouse by the scale before it gives it to the host.


## Limits

- `Text` does not wrap and does not cut a long line.
- There are no images and no shadows, and a shape has no border: the renderer
  fills an outline, it does not draw a line along one.
- The pointer reaches the views, as `onHover`, `onPress` and
  `onTapGesture`. A view gets no pointer position in its handlers. The keys
  go to the app in front, and not to a view: the toolkit has no focus.
- A view cannot draw outside its frame, and nothing clips a view to its
  frame.
- One point is one pixel. There is no scale for a high-resolution screen.
