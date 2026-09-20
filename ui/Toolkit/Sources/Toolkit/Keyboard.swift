import Render

// The keyboard in the toolkit.
//
// A view says that it wants the keys with `onKey`. The host sends each key
// to the view in front that wants them, and that view answers whether it
// used the key. A key that no view used goes on to whatever is under the
// toolkit: in mydistro that is the app with the focus.
//
// This is the same rule as the pointer: the front view gets the event, and
// the views behind it hear nothing.

/// One key, as a view reads it.
public struct KeyEvent: Equatable, Sendable {
    /// The key that a person pressed, and what it writes.
    public enum Named: Equatable, Sendable {
        case escape, enter, tab, backspace, delete
        case up, down, left, right, home, end
        /// A key that writes a character, or one that this list has no name
        /// for.
        case other
    }

    /// The number of the key in the keymap (an xkb keysym).
    public var keysym: UInt32
    /// What the key writes, which is empty for a key that writes nothing.
    public var characters: String
    public var isPressed: Bool
    public var control: Bool
    public var alt: Bool
    public var shift: Bool

    public init(keysym: UInt32, characters: String = "", isPressed: Bool = true,
                control: Bool = false, alt: Bool = false, shift: Bool = false) {
        self.keysym = keysym
        self.characters = characters
        self.isPressed = isPressed
        self.control = control
        self.alt = alt
        self.shift = shift
    }

    /// The name of the key, for the keys that do something instead of
    /// writing something. The numbers are the keysyms of xkbcommon.
    public var named: Named {
        switch keysym {
        case 0xFF1B: .escape
        case 0xFF0D, 0xFF8D: .enter
        case 0xFF09: .tab
        case 0xFF08: .backspace
        case 0xFFFF: .delete
        case 0xFF52: .up
        case 0xFF54: .down
        case 0xFF51: .left
        case 0xFF53: .right
        case 0xFF50: .home
        case 0xFF57: .end
        default: .other
        }
    }
}

/// A view that wants the keys.
public struct KeyRegion {
    let id: Int
    /// Answers whether it used the key. A key that it did not use goes on.
    let handler: (KeyEvent) -> Bool
}

/// A view that reads the keyboard while it is on the screen.
public struct KeyView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let handler: (KeyEvent) -> Bool

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        let child = children.count == 1 ? children[0]
            : ZStackNode(alignment: .center, children: children)
        nodes.append(KeyNode(child: child,
                             id: environment.viewState?.interactionIdentity() ?? 0,
                             handler: handler))
    }
}

extension View {
    /// Gives this view the keys while it is on the screen. The view in front
    /// reads them first, and a view answers `false` for a key that it did
    /// not use, so that the key goes on.
    public func onKey(_ handler: @escaping (KeyEvent) -> Bool) -> KeyView<Self> {
        KeyView(content: self, handler: handler)
    }
}

/// Records that the view inside it wants the keys.
final class KeyNode: LayoutNode {
    let child: LayoutNode
    let id: Int
    let handler: (KeyEvent) -> Bool

    init(child: LayoutNode, id: Int, handler: @escaping (KeyEvent) -> Bool) {
        self.child = child
        self.id = id
        self.handler = handler
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        pass.keyRegions.append(KeyRegion(id: id, handler: handler))
        child.render(in: frame, into: &pass)
    }
}
