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

1. The compositor makes a view, for example `Panel(state:)`.
2. `ViewRenderer` asks the view for its layout nodes. A composite view gives the nodes of its `body`. A primitive view (`Color`, `Text`, a stack, a modifier) makes its own node.
3. The root node gets the rectangle to fill. It asks each child for a size, then gives each child a frame.
4. Each node adds items to the display list: a fill or a bitmap. See [compositor.md](compositor.md#the-display-list).

A complete frame of the panel takes microseconds, because the shell is small. A dependency graph saves work in a large app. It costs much more code.

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
│   ├── Compositor/        screen, input, windows, the display list
│   ├── Wayland/           the Wayland server
│   ├── DRMKit/  C*/       the kernel-facing libraries
│   └── CompositorMain/  HelloClient/  DisplayProbe/  UICheck/
└── Toolkit/               A SWIFT PACKAGE: mydistro-toolkit
    ├── Package.swift
    ├── Sources/
    │   ├── Render/        the display list and the software renderer
    │   ├── Toolkit/       View, the layout, the text
    │   └── Shell/         YOUR UI
    │       ├── RootView.swift
    │       └── Panel.swift
    └── Tests/
```

| Module | Content |
|---|---|
| `Render` | `Rect`, `Bitmap`, `DisplayItem`, `DisplayList`, `Canvas`, and `SoftwareRenderer`. No other module of ours is below it. |
| `Toolkit` | The views, the layout, the text, and `ViewRenderer`. It makes display lists. It knows nothing about the screen or about Wayland. |
| `Shell` | What mydistro draws itself. |

### The root view

`RootView` is the whole screen. The compositor draws it for each frame, over the windows of the apps and under the pointer:

```swift
public struct RootView: View {
    let state: ShellState

    public var body: some View {
        VStack(spacing: 0) {
            Panel(state: state)
                .frame(height: Panel.height)
            Spacer()            // the windows are behind this space
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

To add a part to the interface, write a `View` in `ui/Toolkit/Sources/Shell/` and put it in the body of `RootView`.

`ShellState` is what the compositor gives the shell for each frame: the window titles and the time. Add a value to it when your UI needs more.

`RootView.windowArea(screen:)` says which part of the screen the windows use. The compositor asks the shell, so the shell decides how much space it takes.

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
| `Rectangle` | A rectangle in the foreground colour |
| `Text` | One line of text |
| `Spacer` | Space that grows |
| `Divider` | A line across a stack |
| `VStack`, `HStack`, `ZStack` | Children in a column, in a row, or on top of each other |
| `ForEach`, `Group`, `AnyView`, `EmptyView` | Containers |

| Modifier | Purpose |
|---|---|
| `.frame(width:height:alignment:)` | A fixed size |
| `.frame(minWidth:maxWidth:minHeight:maxHeight:alignment:)` | Limits on the size. Use `.infinity` to take the space. |
| `.padding(_:)`, `.padding(_ edges:_:)` | Space around the view |
| `.background(_:)` | A view behind this one, with the same frame |
| `.offset(x:y:)` | Moves the view after the layout |
| `.foregroundColor(_:)`, `.font(_:)` | The colour and the font for the views inside |

A `body` uses `if`, `if`/`else`, `switch`, and `for` loops, as SwiftUI does.

`.foregroundColor(_:)` and `.font(_:)` set values that flow down the tree. Each view uses the value of the nearest modifier above it.

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

`make test-ui` runs the unit tests on the Mac, and `make test-ui-linux` runs the same tests on mydistro. They need no screen. `ui/Toolkit/Tests/ToolkitTests/` tests the layout, the modifiers, and the text. `ui/Toolkit/Tests/ShellTests/` tests the panel.

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

## Limits

- There is no `@State` and there is no automatic update. The compositor makes the view again for each frame, and it asks for a frame when something changes.
- `Text` does not wrap and does not cut a long line.
- There are no rounded corners, no images, and no shadows. The display list has fills and bitmaps only.
- Views do not get input. The compositor sends input to the window under the pointer.
- One point is one pixel. There is no scale for a high-resolution screen.
