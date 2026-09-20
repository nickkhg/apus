import Render

/// A view that draws an outline: a rectangle with round corners, a circle,
/// and so on. A shape fills the space that it gets, in the foreground colour,
/// or in the colour that `fill(_:)` gives it.
///
///     RoundedRectangle(cornerRadius: 8)
///         .fill(Color.accent)
///         .frame(width: 48, height: 48)
public protocol Shape: View {
    /// The outline, for the space that the layout gave the shape.
    func path(in frame: Frame) -> Path
}

extension Shape {
    public typealias Body = Never

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(ShapeNode(shape: self, color: environment.foregroundColor))
    }

    /// The same shape in a colour of its own.
    public func fill(_ color: Color) -> FilledShape<Self> {
        FilledShape(shape: self, color: color)
    }
}

/// A shape with the colour that `fill(_:)` gave it.
public struct FilledShape<S: Shape>: View {
    public typealias Body = Never
    let shape: S
    let color: Color

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(ShapeNode(shape: shape, color: color))
    }
}

/// A rectangle with round corners.
public struct RoundedRectangle: Shape {
    public let cornerRadius: Double

    public init(cornerRadius: Double) {
        self.cornerRadius = cornerRadius
    }

    public func path(in frame: Frame) -> Path {
        var path = Path()
        path.addRoundedRectangle(x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                                 radius: cornerRadius)
        return path
    }
}

/// A circle. It uses the shorter side of the space and sits in the middle.
public struct Circle: Shape {
    public init() {}

    public func path(in frame: Frame) -> Path {
        let diameter = min(frame.width, frame.height)
        var path = Path()
        path.addEllipse(x: frame.x + (frame.width - diameter) / 2,
                        y: frame.y + (frame.height - diameter) / 2,
                        width: diameter, height: diameter)
        return path
    }
}

/// An oval that fills the space.
public struct Ellipse: Shape {
    public init() {}

    public func path(in frame: Frame) -> Path {
        var path = Path()
        path.addEllipse(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        return path
    }
}

/// A rectangle with half-circle ends.
public struct Capsule: Shape {
    public init() {}

    public func path(in frame: Frame) -> Path {
        var path = Path()
        path.addRoundedRectangle(x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                                 radius: min(frame.width, frame.height) / 2)
        return path
    }
}

/// Draws a shape. The outline comes from the frame, so the node makes it
/// after the layout.
final class ShapeNode: LayoutNode {
    let makePath: (Frame) -> Path
    let color: Color
    /// The size for an unspecified proposal, as a shape has no size of its own.
    private static let idealLength: Double = 10

    init(shape: some Shape, color: Color) {
        makePath = { shape.path(in: $0) }
        self.color = color
    }

    override func computeSize(fitting proposal: Proposal) -> Size {
        Size(width: proposal.width.map { max(0, $0) } ?? ShapeNode.idealLength,
             height: proposal.height.map { max(0, $0) } ?? ShapeNode.idealLength)
    }

    override func render(in frame: Frame, into pass: inout RenderPass) {
        guard color.alpha > 0, frame.width > 0, frame.height > 0 else { return }
        pass.list.append(.path(makePath(frame), color: color.premultiplied))
    }
}
