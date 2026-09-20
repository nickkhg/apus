import Render

/// A view that does something when the pointer clicks it.
///
///     Button("Close") { close() }
///
///     Button(action: { open(item) }) {
///         Icon(item)
///     }
///
/// `Button(_:action:)` draws a button: a title on a round background that
/// answers the pointer. `Button(action:label:)` draws only the label, and
/// the label decides how a button looks. Both call `action` when the pointer
/// goes down and up again on the button.
public struct Button<Label: View>: View {
    enum Look {
        /// A title on a background that the button draws.
        case filled
        /// Only the label.
        case plain
    }

    let look: Look
    let action: () -> Void
    let label: Label

    @State private var isPressed = false
    @State private var isHovered = false

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.look = .plain
        self.action = action
        self.label = label()
    }

    init(look: Look, action: @escaping () -> Void, label: Label) {
        self.look = look
        self.action = action
        self.label = label
    }

    public var body: some View {
        if look == .filled {
            label
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(background)
                )
                .onHover { isHovered = $0 }
                .onPress { isPressed = $0 }
                .onTapGesture(perform: action)
        } else {
            // The label decides how the button looks, so this button keeps
            // no state of its own.
            label.onTapGesture(perform: action)
        }
    }

    private var background: Color {
        if isPressed { Color(hex: 0x6C3FA0) } else if isHovered { Color(hex: 0xA26FE8) } else { .accent }
    }
}

extension Button where Label == Text {
    /// A button with a title.
    public init(_ title: String, action: @escaping () -> Void) {
        self.init(look: .filled, action: action, label: Text(title))
    }
}
