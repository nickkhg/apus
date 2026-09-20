/// The values that flow down the view tree: the colour and the font that a
/// view uses if it does not set its own. A modifier such as
/// `.foregroundColor(_:)` changes them for the views inside it.
public struct EnvironmentValues: Sendable {
    public var foregroundColor: Color = .white
    public var font: Font = .body
    /// How many pixels there are to the point. Text is shaped at the size
    /// that it is drawn at, so that the glyphs are sharp on a screen with
    /// more than one pixel to the point. Every layout stays in points.
    public var scale: Double = 1
    /// The time of this frame, in seconds. Every move in one frame uses the
    /// same time, so that things that start together stay together.
    public var now: Double = 0

    /// How the screen is drawn: what a view can afford to ask for. See
    /// RenderMode in Effects.swift.
    public var renderMode: RenderMode = .cpu

    /// Where the `@State` values of the view tree are. The renderer puts it
    /// here, so that a view needs no global. See State.swift.
    var viewState: ViewState?

    public init() {}
}

/// Reads a value of the environment in a view.
///
///     struct Glow: View {
///         @Environment(\.now) private var now
///         var body: some View { ... }
///     }
@propertyWrapper
public struct Environment<Value> {
    final class Box {
        var value: Value?
        init() {}
    }

    let keyPath: KeyPath<EnvironmentValues, Value>
    let box = Box()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value {
        guard let value = box.value else {
            // A view outside a tree reads the value of a new environment.
            return EnvironmentValues()[keyPath: keyPath]
        }
        return value
    }
}

/// What the renderer needs of an `@Environment` property, without its type.
protocol AnyEnvironmentProperty {
    func take(from environment: EnvironmentValues)
}

extension Environment: AnyEnvironmentProperty {
    func take(from environment: EnvironmentValues) {
        box.value = environment[keyPath: keyPath]
    }
}

/// A view that changes the environment for the views inside it.
public struct EnvironmentView<Content: View>: View {
    public typealias Body = Never
    let content: Content
    let transform: (inout EnvironmentValues) -> Void

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        var inner = environment
        transform(&inner)
        content.makeNodes(into: &nodes, environment: inner)
    }
}

extension View {
    /// The colour of the text and the shapes inside this view.
    public func foregroundColor(_ color: Color) -> EnvironmentView<Self> {
        EnvironmentView(content: self) { $0.foregroundColor = color }
    }

    /// The font of the text inside this view.
    public func font(_ font: Font) -> EnvironmentView<Self> {
        EnvironmentView(content: self) { $0.font = font }
    }
}
