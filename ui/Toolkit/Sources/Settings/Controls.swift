import Render
import Toolkit

// The parts that every pane is made of: a card of rows, a switch, a choice
// of a few, a button, a place for text, and a notice. They answer the
// pointer as the shell's own controls do: brighter under it, darker while
// it is down, and the move is `.quick`.

/// A group of rows on a panel with round corners.
struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Ink.card))
    }
}

/// The name of a group of cards, over them.
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(Font(size: 10, weight: .bold))
            .foregroundColor(Ink.faintText)
            .padding(.leading, 4)
            // The stack puts a card's space above and below this; the
            // title belongs to the card under it, so it sits nearer that one.
            .padding(.top, 10)
            .padding(.bottom, -8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line between two rows of a card. It starts where the text does.
struct RowDivider: View {
    var body: some View {
        Divider(thickness: 1)
            .foregroundColor(Ink.divider)
            .padding(.leading, Metrics.rowPadding)
    }
}

/// A row of a card: a name, what it means under it, and a control at the
/// end.
struct SettingRow<Trailing: View>: View {
    let title: String
    let detail: String
    let trailing: Trailing

    init(_ title: String, detail: String = "", @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Font(size: 13))
                    .foregroundColor(Ink.text)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Font(size: 11))
                        .foregroundColor(Ink.dimText)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.rowPadding)
        .frame(height: detail.isEmpty ? Metrics.row : Metrics.rowWithDetail)
        .frame(maxWidth: .infinity)
    }
}

extension SettingRow where Trailing == ValueText {
    /// A row that says a value and changes nothing.
    init(_ title: String, value: String, detail: String = "") {
        self.title = title
        self.detail = detail
        self.trailing = ValueText(value)
    }
}

/// The value at the end of a row.
struct ValueText: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(Font(size: 13))
            .foregroundColor(Ink.secondaryText)
    }
}

/// On or off. The knob moves across, and the track takes the accent when
/// it is on.
struct Switch: View {
    let isOn: Bool
    var isEnabled = true
    let action: () -> Void
    @State private var glow = 0.0

    var body: some View {
        Button(action: { if isEnabled { action() } }) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(knob)
                    .frame(width: 14, height: 14)
                    .offset(x: isOn ? 17 : 3)
                    .animation(Moves.quick, value: isOn)
            }
            .frame(width: 34, height: 20)
            .onHover { hovering in withAnimation(Moves.quick) { glow = hovering && isEnabled ? 1 : 0 } }
        }
    }

    private var track: Color {
        guard isEnabled else { return Ink.divider.opacity(0.5) }
        return isOn ? Ink.accent.lightened(by: glow * 0.1) : Ink.control.lightened(by: glow * 0.25)
    }

    private var knob: Color {
        guard isEnabled else { return Ink.faintText }
        return isOn ? Ink.accentSurface : Ink.secondaryText
    }
}

/// One of a few. The one that is chosen has the accent.
struct Choice<Value: Equatable>: View {
    let options: [(value: Value, label: String)]
    let selected: Value
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { option in
                ChoiceSegment(label: option.element.label,
                              isSelected: option.element.value == selected) {
                    choose(option.element.value)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius + 2).fill(Ink.field))
    }
}

struct ChoiceSegment: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var glow = 0.0

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Font(size: 12, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? Ink.accent : Ink.secondaryText.lightened(by: glow * 0.3))
                .padding(.horizontal, 12)
                .frame(height: Metrics.controlHeight - 4)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius)
                        .fill(isSelected ? Ink.accentSurface : Ink.control.opacity(glow))
                )
                .onHover { hovering in withAnimation(Moves.quick) { glow = hovering ? 1 : 0 } }
        }
    }
}

/// A button with a title.
struct PushButton: View {
    enum Style { case normal, primary, danger }

    let title: String
    var style = Style.normal
    var isEnabled = true
    let action: () -> Void
    @State private var glow = 0.0
    @State private var isPressed = false

    init(_ title: String, style: Style = .normal, isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Text(title)
            .font(Font(size: 12, weight: style == .normal ? .regular : .bold))
            .foregroundColor(foreground)
            .padding(.horizontal, 14)
            .frame(height: Metrics.controlHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.controlRadius).fill(background))
            .onHover { hovering in withAnimation(Moves.quick) { glow = hovering && isEnabled ? 1 : 0 } }
            .onPress { isPressed = $0 && isEnabled }
            .onTapGesture { if isEnabled { action() } }
    }

    private var foreground: Color {
        guard isEnabled else { return Ink.faintText }
        return switch style {
        case .normal: Ink.text
        case .primary: Ink.accent
        case .danger: Ink.failure
        }
    }

    private var background: Color {
        let base: Color = switch style {
        case .normal: Ink.control
        case .primary: Ink.accentSurface
        case .danger: Ink.failureSurface
        }
        guard isEnabled else { return base.opacity(0.5) }
        if isPressed { return base.darkened(by: 0.25) }
        return base.lightened(by: glow * 0.18)
    }
}

/// A place that takes text. A click starts the typing, and the accent says
/// that the keys go here. Enter keeps what was typed, and Escape does not.
struct TextField: View {
    let text: String
    let placeholder: String
    let isEditing: Bool
    var width = Metrics.fieldWidth
    let begin: () -> Void
    @State private var glow = 0.0

    var body: some View {
        HStack(spacing: 1) {
            if text.isEmpty && !isEditing {
                Text(placeholder)
                    .font(Font(size: 13))
                    .foregroundColor(Ink.faintText)
            } else {
                Text(text)
                    .font(Font(size: 13))
                    .foregroundColor(Ink.text)
            }
            if isEditing {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Ink.accent)
                    .frame(width: 2, height: 16)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: Metrics.controlHeight + 2)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius).fill(Ink.field))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.controlRadius)
                .stroke(isEditing ? Ink.accent : Ink.divider.lightened(by: glow * 0.4),
                        lineWidth: isEditing ? 1.5 : 1)
        )
        .onHover { hovering in withAnimation(Moves.quick) { glow = hovering ? 1 : 0 } }
        .onTapGesture(perform: begin)
    }
}

/// A word in a small box of its colour: CONNECTED, NOT SAVED.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(Font(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.14)))
    }
}

/// What came of a change, at the top of a pane. The colour never says it
/// alone: the words say it too.
struct NoticeBar: View {
    let notice: Notice
    let perform: (Notice.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(notice.text)
                .font(Font(size: 12))
                .foregroundColor(Ink.text)
            Spacer(minLength: 8)
            if let action = notice.action {
                switch action {
                case .restartShell:
                    PushButton("Restart the shell", style: .primary) { perform(action) }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    private var color: Color {
        switch notice.kind {
        case .done: Ink.good
        case .information: Ink.secondaryText
        case .warning: Ink.warning
        case .failure: Ink.failure
        }
    }
}

/// A line of a list that the keyboard can walk: a mark, a name, a detail,
/// and what is at the end. The selected line has the accent while the pane
/// has the keyboard.
struct ListRow<Trailing: View>: View {
    let mark: Color?
    let title: String
    let detail: String
    let isSelected: Bool
    let hasKeyboard: Bool
    let action: () -> Void
    let trailing: Trailing
    @State private var isHovered = false

    init(mark: Color? = nil, title: String, detail: String = "", isSelected: Bool,
         hasKeyboard: Bool, action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing) {
        self.mark = mark
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.hasKeyboard = hasKeyboard
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let mark {
                RoundedRectangle(cornerRadius: 2)
                    .fill(mark)
                    .frame(width: 8, height: 8)
            }
            Text(title)
                .font(Font(size: 13))
                .foregroundColor(Ink.text)
            if !detail.isEmpty {
                Text(detail)
                    .font(Font(size: 11))
                    .foregroundColor(Ink.dimText)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.listRow)
        .frame(maxWidth: .infinity)
        // The click is on the background, behind the row, so that a control
        // at the end of the row gets its own clicks: a view that answers a
        // click hides every one under it.
        .background(
            Color.clear.onTapGesture(perform: action)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                )
        )
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return hasKeyboard ? Ink.accentSurface : Ink.control }
        return isHovered ? Ink.control.opacity(0.6) : .clear
    }
}

/// The small mark of a tick, for the line that is in use.
struct Tick: Shape {
    func path(in frame: Frame) -> Path {
        var path = Path()
        let (x, y, w, h) = (frame.x, frame.y, frame.width, frame.height)
        let t = min(w, h) * 0.18
        // The short arm down to the corner, and the long arm up from it.
        path.move(to: x, y + h * 0.55)
        path.line(to: x + t, y + h * 0.55 - t)
        path.line(to: x + w * 0.38, y + h * 0.78 - t)
        path.line(to: x + w - t, y)
        path.line(to: x + w, y + t)
        path.line(to: x + w * 0.38, y + h * 0.78 + t * 0.6)
        path.close()
        return path
    }
}
