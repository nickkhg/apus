import Render
import Toolkit

// The head of a window: the bar over a cell that is large enough to carry
// one. It names the app and the window, says how much room the window has,
// and holds the two controls that a window needs.
//
// A tile has no head. A tile is 256 points across, and a bar of controls
// would take a tenth of it, so an app draws its own name in its widget user
// interface instead.

/// The bar over one window, and where it is.
public struct WindowHead: Identifiable, Equatable, Sendable {
    public let id: String
    public let appName: String
    public let mark: Color
    /// What the window calls itself, under the name of the app.
    public let title: String
    /// How much room the window has: `large` or `compact`.
    public let sizeClass: SizeClass
    public let hasFocus: Bool
    /// The whole cell, in points on the screen. The head is at the top of it.
    public let cell: Rect

    public init(id: String, appName: String, mark: Color, title: String,
                sizeClass: SizeClass, hasFocus: Bool, cell: Rect) {
        self.id = id
        self.appName = appName
        self.mark = mark
        self.title = title
        self.sizeClass = sizeClass
        self.hasFocus = hasFocus
        self.cell = cell
    }
}

/// What the shell keeps of a cell for itself. A window gets the rest.
public enum WindowChrome {
    /// The space around the window inside its cell. A tile keeps nothing,
    /// because the app draws the whole tile.
    public static func insets(for sizeClass: SizeClass) -> EdgeInsets {
        sizeClass == .widget
            ? EdgeInsets(all: 0)
            : EdgeInsets(top: Metrics.headHeight, leading: Metrics.gap,
                         bottom: Metrics.gap, trailing: Metrics.gap)
    }

    /// The part of `cell` that the window draws into.
    public static func content(of cell: Rect, sizeClass: SizeClass) -> Rect {
        let insets = insets(for: sizeClass)
        return Rect(x: cell.x + Int(insets.leading), y: cell.y + Int(insets.top),
                    width: max(0, cell.width - Int(insets.horizontal)),
                    height: max(0, cell.height - Int(insets.vertical)))
    }
}

/// The bar itself.
public struct WindowHeadView: View {
    let head: WindowHead
    let actions: ShellActions

    public init(head: WindowHead, actions: ShellActions = ShellActions()) {
        self.head = head
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            // The line that says which window has the keyboard. A window
            // without it draws nothing here, because a clear colour makes
            // no item at all.
            (head.hasFocus ? Palette.accent : Color.clear)
                .frame(height: Metrics.ringWidth)
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(head.mark)
                    .frame(width: 8, height: 8)
                Text(head.appName)
                    .font(Font(size: 13, weight: .bold))
                    .foregroundColor(Palette.text)
                if !head.title.isEmpty {
                    Text(head.title)
                        .font(Font(size: 13))
                        .foregroundColor(Palette.dimText)
                }
                Spacer()
                Text(head.sizeClass.rawValue.uppercased())
                    .font(Font(size: 9, weight: .bold))
                    .foregroundColor(Palette.faintText)
                HeadButton(glyph: Collapse(), name: "widget") {
                    actions.makeWidget(head.id)
                }
                HeadButton(glyph: Cross(), name: "close") {
                    actions.closeWindow(head.id)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: Metrics.headHeight)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
    }
}

/// One control of the head. It is a glyph that answers the pointer.
struct HeadButton<Glyph: Shape>: View {
    let glyph: Glyph
    let name: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            glyph
                .fill(isHovered ? Palette.text : Palette.dimText)
                .frame(width: 10, height: 10)
                .padding(5)
                .onHover { isHovered = $0 }
        }
    }
}

/// A cross: the mark that closes a window. The renderer fills outlines and
/// cannot turn one, so each arm is a four-cornered shape of its own.
public struct Cross: Shape {
    /// How thick an arm is, as a part of the whole mark.
    let thickness: Double = 0.16

    public init() {}

    public func path(in frame: Frame) -> Path {
        var path = Path()
        let half = thickness * min(frame.width, frame.height)
        arm(&path, in: frame, half: half, rising: false)
        arm(&path, in: frame, half: half, rising: true)
        return path
    }

    /// One arm, from corner to corner, `half` wide on each side of the line.
    private func arm(_ path: inout Path, in frame: Frame, half: Double, rising: Bool) {
        let (left, right) = (frame.x, frame.x + frame.width)
        let (top, bottom) = rising
            ? (frame.y + frame.height, frame.y)
            : (frame.y, frame.y + frame.height)
        path.move(to: left, top - half)
        path.line(to: left + half, top)
        path.line(to: right, bottom + half)
        path.line(to: right - half, bottom)
        path.close()
    }
}

/// A large square with a small one in its corner: the mark that puts a
/// window into a tile.
public struct Collapse: Shape {
    public init() {}

    public func path(in frame: Frame) -> Path {
        var path = Path()
        let line = max(1, min(frame.width, frame.height) * 0.12)
        // The outline of the large square, as a ring.
        path.addRectangle(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        var inner = Path()
        inner.addRectangle(x: frame.x + line, y: frame.y + line,
                           width: frame.width - 2 * line, height: frame.height - 2 * line)
        path.add(inner.reversed())
        // The small square inside it.
        let small = min(frame.width, frame.height) * 0.4
        path.addRectangle(x: frame.x + frame.width - small - line,
                          y: frame.y + frame.height - small - line,
                          width: small, height: small)
        return path
    }
}
