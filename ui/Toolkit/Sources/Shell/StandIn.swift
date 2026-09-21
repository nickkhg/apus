import Render
import Toolkit

// A stand-in: what the shell draws in a cell that a window cannot use.
//
// A window that answers a size no tile can hold is not placed. It stays
// open, it keeps its state, and it waits in the rail. The band keeps its
// cell, and this card goes there instead, so the band still shows the shape
// of the session.
//
// The card is not a small picture of the window. A window of 1200 points
// scaled into 256 is unreadable, and it would cost a frame to make. The card
// states facts that the protocol already carries, and the title of a
// terminal follows the command that runs in it, so the card is a line of
// status for no work.

/// A window that waits for a cell, and the cell that the band holds for it.
public struct StandIn: Identifiable, Equatable, Sendable {
    public let id: String
    /// The name of the app, and its colour.
    public let appName: String
    public let mark: Color
    /// What the window calls itself now.
    public let title: String
    /// The size that the window answered, as "at least 600 × 400".
    public let answered: String
    /// The size that the window last drew.
    public let drew: String
    /// How long ago the window last changed, as "4 s".
    public let changed: String
    /// Where the cell is, in points on the screen.
    public let frame: Rect

    public init(id: String, appName: String, mark: Color, title: String,
                answered: String, drew: String, changed: String, frame: Rect) {
        self.id = id
        self.appName = appName
        self.mark = mark
        self.title = title
        self.answered = answered
        self.drew = drew
        self.changed = changed
        self.frame = frame
    }
}

/// The card in the cell.
public struct StandInCard: View {
    let card: StandIn
    let actions: ShellActions
    @State private var isHovered = false
    /// How the screen is drawn. The root puts it in the environment.
    @Environment(\.renderMode) private var mode

    public init(card: StandIn, actions: ShellActions = ShellActions()) {
        self.card = card
        self.actions = actions
    }

    public var body: some View {
        Button(action: { actions.raiseWindow(card.id) }) {
            VStack(alignment: .leading, spacing: 0) {
                head
                Text(card.title)
                    .font(Font(size: 13))
                    .foregroundColor(Palette.text)
                    .padding(.top, 10)
                Divider(thickness: 1)
                    .foregroundColor(Palette.divider)
                    .padding(.vertical, 12)
                row("It answered", card.answered)
                row("Window", card.drew)
                row("Changed", card.changed)
                Spacer()
                Divider(thickness: 1)
                    .foregroundColor(Palette.divider)
                    .padding(.bottom, 10)
                Text("Click to make it the principal")
                    .font(Font(size: 10))
                    .foregroundColor(Palette.dimText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cellRadius)
                    .fill(isHovered ? Palette.control : Palette.slot)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cellRadius)
                    .stroke(Palette.divider, lineWidth: 1)
            )
            .onHover { isHovered = $0 }
            .clipped()
            .shadow(Appearance(mode).cellShadow, cornerRadius: Metrics.cellRadius)
        }
    }

    private var head: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(card.mark)
                .frame(width: 8, height: 8)
            Text(card.appName)
                .font(Font(size: 13, weight: .bold))
                .foregroundColor(Palette.text)
            Spacer()
            Text("WAITING")
                .font(Font(size: 9, weight: .bold))
                .foregroundColor(Palette.faintText)
        }
    }

    /// One fact: what it is on the left, what it says on the right.
    private func row(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(Font(size: 10))
                .foregroundColor(Palette.dimText)
            Spacer()
            Text(value)
                .font(Font(size: 11))
                .foregroundColor(Palette.secondaryText)
        }
        .padding(.bottom, 8)
    }
}

// A view says when it is the same view as before, so that the graph can keep
// the nodes that it made. `@State` and `@Environment` are left out of that:
// the store keeps the state by the place of the view in the tree, and the
// environment is compared on its own. See Graph.swift.

extension StandInCard: Equatable {
    public static func == (a: StandInCard, b: StandInCard) -> Bool {
        a.card == b.card && a.actions == b.actions
    }
}
