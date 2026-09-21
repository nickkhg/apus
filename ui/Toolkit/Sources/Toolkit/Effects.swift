import Render

// Depth: a shadow behind a view, a blur under one, and a gradient in one.
//
// A view asks for these the same way whatever draws the screen, because the
// three of them are items in the display list. They cost much more on the
// CPU than a flat colour does, so the shell asks for them in GPU mode only.
// `Appearance` in the Shell module holds what each mode uses. See
// docs/toolkit.md.

/// How the screen is drawn, which says what a view can afford to ask for.
///
/// This is in the toolkit, not in the shell, because it is a contract
/// between a view and whatever draws it. An app in a tile will read it as
/// the shell does, and ask for a blur only where a blur is cheap. The
/// compositor does not tell an app the mode yet, so an app reads `cpu`.
public enum RenderMode: String, Sendable {
    /// Solid colours, one-point lines, short motion. The software renderer.
    case cpu
    /// Shadows, blur and gradients. A renderer with a GPU behind it.
    case gpu
}

extension View {
    /// How the screen is drawn, for the views inside this one. It flows
    /// down the tree, so a view deep in it needs no state of its own.
    public func renderMode(_ mode: RenderMode) -> EnvironmentView<Self> {
        EnvironmentView(content: self) { $0.renderMode = mode }
    }
}

/// How a shadow looks: its colour, how far its edge fades, and how far it
/// is below the thing that casts it.
public struct ShadowStyle: Equatable, Sendable {
    public var color: Color
    /// How far the edge fades, in points.
    public var radius: Double
    /// How far down the shadow is from the shape.
    public var y: Double

    public init(color: Color, radius: Double, y: Double = 0) {
        self.color = color
        self.radius = radius
        self.y = y
    }

    /// No shadow. This is what CPU mode draws: it separates one surface
    /// from the next with a line and a step in the colour instead.
    public static let none = ShadowStyle(color: .clear, radius: 0, y: 0)

    /// True when the shadow puts something on the screen.
    public var isVisible: Bool { color.alpha > 0 && (radius > 0 || y != 0) }
}

/// A view that makes what is behind it soft.
///
///     Summon()
///         .background(Blur(radius: 24, cornerRadius: 20))
///
/// It reads the picture that the items before it made, so it blurs what is
/// behind it in the list, and nothing that comes after it.
public struct Blur: View {
    public typealias Body = Never
    /// How far a pixel spreads, in points.
    public var radius: Double
    /// The corner of the area that is made soft.
    public let cornerRadius: Double

    public init(radius: Double, cornerRadius: Double = 0) {
        self.radius = radius
        self.cornerRadius = cornerRadius
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        let shown = shown(in: environment)
        nodes.append(BlurNode(radius: shown.radius, cornerRadius: cornerRadius))
    }
}

extension Blur: Animatable {
    public var animatableData: Double {
        get { radius }
        set { radius = newValue }
    }
}

/// A colour that changes along a line, from one edge of the view to another.
///
///     LinearGradient(from: .accent, to: .clear, direction: .down)
public struct LinearGradient: View, Equatable, Sendable {
    public typealias Body = Never

    /// Which way the colour changes.
    public enum Direction: Sendable, Equatable {
        /// From the top edge to the bottom edge.
        case down
        /// From the leading edge to the trailing edge.
        case right
        /// From the top leading corner to the bottom trailing corner.
        case downRight
    }

    public var from: Color
    public var to: Color
    public let direction: Direction

    public init(from: Color, to: Color, direction: Direction = .down) {
        self.from = from
        self.to = to
        self.direction = direction
    }

    /// The same gradient, with both ends more or less solid.
    public func opacity(_ amount: Double) -> LinearGradient {
        LinearGradient(from: from.opacity(amount), to: to.opacity(amount), direction: direction)
    }

    /// The two ends of the line, for a frame in pixels.
    func gradient(in rect: Frame) -> Gradient {
        let (endX, endY): (Double, Double) = switch direction {
        case .down: (rect.x, rect.y + rect.height)
        case .right: (rect.x + rect.width, rect.y)
        case .downRight: (rect.x + rect.width, rect.y + rect.height)
        }
        return Gradient(from: from.premultiplied, to: to.premultiplied,
                        startX: rect.x, startY: rect.y, endX: endX, endY: endY)
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(GradientNode(gradient: shown(in: environment), makePath: { frame in
            var path = Path()
            path.addRectangle(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            return path
        }))
    }
}

extension LinearGradient: Animatable {
    /// The two ends move. The direction is not a number, so it changes at
    /// once.
    public var animatableData: AnimatablePair<Color.AnimatableData, Color.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }
}

extension Shape {
    /// The shape filled with a gradient instead of one colour.
    public func fill(_ gradient: LinearGradient) -> GradientShape<Self> {
        GradientShape(shape: self, gradient: gradient)
    }
}

/// A shape with the gradient that `fill(_:)` gave it.
public struct GradientShape<S: Shape>: View {
    public typealias Body = Never
    let shape: S
    var gradient: LinearGradient

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        let shown = shown(in: environment)
        nodes.append(GradientNode(gradient: shown.gradient,
                                  makePath: { shown.shape.path(in: $0) }))
    }
}

extension GradientShape: Animatable {
    public var animatableData: LinearGradient.AnimatableData {
        get { gradient.animatableData }
        set { gradient.animatableData = newValue }
    }
}

/// A view with a shadow behind it.
public struct ShadowView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    var style: ShadowStyle
    let cornerRadius: Double

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var children: [LayoutNode] = []
        content.makeNodes(into: &children, environment: environment)
        let child = children.count == 1 ? children[0]
            : ZStackNode(alignment: .center, children: children)
        nodes.append(ShadowNode(child: child, style: shown(in: environment).style,
                                cornerRadius: cornerRadius))
    }
}

extension ShadowView: Animatable {
    /// The colour, how far the edge fades, and how far down it is.
    public var animatableData: AnimatablePair<Color.AnimatableData,
                                              AnimatablePair<Double, Double>> {
        get { AnimatablePair(style.color.animatableData, AnimatablePair(style.radius, style.y)) }
        set {
            style.color.animatableData = newValue.first
            style.radius = newValue.second.first
            style.y = newValue.second.second
        }
    }
}

extension View {
    /// A soft dark shape behind this view, in the shape of its frame.
    ///
    /// The shadow is the frame with `cornerRadius` at its corners, not the
    /// outline of what the view draws: the renderer draws each item as it
    /// comes and keeps no picture of the view to take a shape from.
    ///
    /// A style of `.none` draws nothing, so a view can ask for the shadow
    /// of the mode that it is in and let the mode decide.
    public func shadow(_ style: ShadowStyle, cornerRadius: Double = 0) -> ShadowView<Self> {
        ShadowView(content: self, style: style, cornerRadius: cornerRadius)
    }

    public func shadow(radius: Double, y: Double = 0,
                       color: Color = Color(white: 0, alpha: 0.5),
                       cornerRadius: Double = 0) -> ShadowView<Self> {
        shadow(ShadowStyle(color: color, radius: radius, y: y), cornerRadius: cornerRadius)
    }
}

// MARK: - The nodes

/// A node that fills the space that it gets, as a colour does.
class SurfaceNode: LayoutNode {
    /// The size for an unspecified proposal, as SwiftUI gives shapes 10 × 10.
    private static let idealLength: Double = 10

    override func computeSize(fitting proposal: Proposal) -> Size {
        Size(width: proposal.width.map { max(0, $0) } ?? SurfaceNode.idealLength,
             height: proposal.height.map { max(0, $0) } ?? SurfaceNode.idealLength)
    }

    /// The area of this node, with round corners, in pixels.
    func area(_ frame: Frame, cornerRadius: Double, scale: Double) -> Path {
        var path = Path()
        path.addRoundedRectangle(x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                                 radius: cornerRadius)
        return path.scaled(by: scale)
    }
}

/// Makes the picture under it soft.
final class BlurNode: SurfaceNode {
    let radius: Double
    let cornerRadius: Double

    init(radius: Double, cornerRadius: Double) {
        self.radius = radius
        self.cornerRadius = cornerRadius
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        guard radius > 0, frame.width > 0, frame.height > 0 else { return }
        pass.list.append(.blur(area(frame, cornerRadius: cornerRadius, scale: pass.scale),
                               radius: radius * pass.scale))
    }
}

/// Fills an outline with a gradient.
final class GradientNode: SurfaceNode {
    let gradient: LinearGradient
    let makePath: (Frame) -> Path

    init(gradient: LinearGradient, makePath: @escaping (Frame) -> Path) {
        self.gradient = gradient
        self.makePath = makePath
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        guard frame.width > 0, frame.height > 0 else { return }
        guard gradient.from.alpha > 0 || gradient.to.alpha > 0 else { return }
        let path = makePath(frame).scaled(by: pass.scale)
        // Two ends of one colour are a fill, and a fill is cheaper: the
        // renderer then needs no colour for each pixel. CPU mode asks for
        // gradients whose two ends are the same, and gets flat colours.
        guard gradient.from != gradient.to else {
            pass.list.append(.path(path, color: gradient.from.premultiplied))
            return
        }
        let pixels = Frame(x: frame.x * pass.scale, y: frame.y * pass.scale,
                           width: frame.width * pass.scale, height: frame.height * pass.scale)
        pass.list.append(.gradient(path, gradient.gradient(in: pixels)))
    }
}

/// Draws a shadow, then the view that casts it.
final class ShadowNode: LayoutNode {
    let child: LayoutNode
    let style: ShadowStyle
    let cornerRadius: Double

    init(child: LayoutNode, style: ShadowStyle, cornerRadius: Double) {
        self.child = child
        self.style = style
        self.cornerRadius = cornerRadius
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        child.size(fitting: proposal)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        if style.isVisible, frame.width > 0, frame.height > 0 {
            var path = Path()
            path.addRoundedRectangle(x: frame.x, y: frame.y,
                                     width: frame.width, height: frame.height,
                                     radius: cornerRadius)
            let shadow = Shadow(color: style.color.premultiplied,
                                radius: style.radius * pass.scale,
                                dx: 0, dy: style.y * pass.scale)
            pass.list.append(.shadow(path.scaled(by: pass.scale), shadow))
        }
        child.render(in: frame, into: &pass)
    }
}
