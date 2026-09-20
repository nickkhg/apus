import Render
import Toolkit

// A notice: a short message from the system or from an app.
//
// A notice never covers the principal window. It sits at the end of the
// band, where a tile would go, so that a person can read it without losing
// the thing they were doing. A notice that nobody answers goes away on its
// own; one that asks a question waits.

/// One message.
public struct Notice: Identifiable, Equatable, Sendable {
    /// How much the message matters.
    public enum Kind: Sendable, Equatable {
        /// Something happened that a person may want to know.
        case information
        /// Something is not right, and the system carries on.
        case warning
        /// Something failed.
        case failure

        var color: Color {
            switch self {
            case .information: Palette.widget
            case .warning: Palette.warning
            case .failure: Palette.error
            }
        }
    }

    public let id: String
    public let kind: Kind
    /// Who is speaking: an app, or the system.
    public let source: String
    /// One line that says what happened.
    public let title: String
    /// What a person can do about it.
    public let detail: String

    public init(id: String, kind: Kind = .information, source: String,
                title: String, detail: String = "") {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.detail = detail
    }
}

/// The card that a notice is drawn in.
public struct NoticeView: View {
    let notice: Notice
    let actions: ShellActions

    /// How the screen is drawn. The root puts it in the environment.
    @Environment(\.renderMode) private var mode

    public init(notice: Notice, actions: ShellActions = ShellActions()) {
        self.notice = notice
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            // The colour of the kind, as a band down the leading edge. A
            // colour alone never carries the meaning: the text says it too.
            notice.kind.color
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(notice.source)
                        .font(Font(size: 11, weight: .bold))
                        .foregroundColor(notice.kind.color)
                    Spacer()
                    Button(action: { actions.dismissNotice(notice.id) }) {
                        Cross()
                            .fill(Palette.dimText)
                            .frame(width: 8, height: 8)
                            .padding(4)
                    }
                }
                Text(notice.title)
                    .font(Font(size: 13))
                    .foregroundColor(Palette.text)
                    .padding(.top, 4)
                if !notice.detail.isEmpty {
                    Text(notice.detail)
                        .font(Font(size: 11))
                        .foregroundColor(Palette.dimText)
                        .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cellRadius)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cellRadius)
                .stroke(Palette.divider, lineWidth: 1)
        )
        .clipped()
        .shadow(Appearance(mode).cellShadow, cornerRadius: Metrics.cellRadius)
    }

    /// How tall a notice is, for the size that its text needs.
    public static func height(of notice: Notice) -> Double {
        notice.detail.isEmpty ? 72 : 96
    }
}

/// What the canvas shows when no window is open.
public struct EmptyCanvas: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Text("Nothing is open")
                .font(Font(size: 15))
                .foregroundColor(Palette.dimText)
            HStack(spacing: 8) {
                Text("Press")
                    .font(Font(size: 12))
                    .foregroundColor(Palette.faintText)
                Text("Super")
                    .font(Font(size: 11, weight: .bold))
                    .foregroundColor(Palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Palette.surface)
                    )
                Text("to start an app")
                    .font(Font(size: 12))
                    .foregroundColor(Palette.faintText)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
