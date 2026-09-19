import Render

/// A rectangle that fills its space with the foreground colour.
public struct Rectangle: View {
    public typealias Body = Never
    public init() {}

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(FillNode(color: environment.foregroundColor))
    }
}

/// Empty space that takes what the other views in the stack do not use.
public struct Spacer: View {
    public typealias Body = Never
    let minLength: Double

    public init(minLength: Double = 0) {
        self.minLength = minLength
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(SpacerNode(axis: nil, minLength: minLength))
    }
}

/// A line across a stack.
public struct Divider: View {
    public typealias Body = Never
    let thickness: Double

    public init(thickness: Double = 1) {
        self.thickness = thickness
    }

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        nodes.append(FrameNode(child: FillNode(color: environment.foregroundColor.opacity(0.3)),
                               height: thickness))
    }
}
