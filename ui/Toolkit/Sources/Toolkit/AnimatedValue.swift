// What moves, and where the move is kept.
//
// A value changes at once: a view that reads a `@State` value reads where it
// is going, as it does in SwiftUI. The move is in the view under it. A view
// that conforms to Animatable says which of its numbers move, and the
// toolkit keeps a move for that view while its numbers are on their way.
//
// The move therefore belongs to the picture and not to the value. A colour
// that a handler set jumps to its new value in the state and arrives at it
// on the screen.

/// The animatable data of a view, on its own, so that a Motion can carry it.
struct AnimatableValue<Data: VectorArithmetic>: Animatable {
    var animatableData: Data
}

/// A move of one view, without the type of that view.
protocol AnyViewMotion: AnyObject {
    func isMoving(now: Double) -> Bool
}

/// Where one view is on its way from one value to another.
final class ViewMotion<V: View & Animatable>: AnyViewMotion {
    private let motion: Motion<AnimatableValue<V.AnimatableData>>
    /// The value that the view is going to.
    private(set) var target: V.AnimatableData

    init(_ data: V.AnimatableData) {
        motion = Motion(AnimatableValue(animatableData: data))
        target = data
    }

    func isMoving(now: Double) -> Bool {
        motion.isMoving(now: now)
    }

    /// A new value to go to. Without a move in the air the view is there at
    /// once, and the next move starts from the new value.
    func move(to data: V.AnimatableData, with animation: Animation?, now: Double) {
        target = data
        let value = AnimatableValue<V.AnimatableData>(animatableData: data)
        guard let animation else {
            motion.move(to: value, with: .instant, now: now)
            return
        }
        motion.move(to: value, with: animation, now: now)
    }

    /// The view as it is now, part of the way to its new value.
    func shown(_ view: V, now: Double) -> V {
        var view = view
        view.animatableData = motion.value(now: now).animatableData
        return view
    }
}

extension View where Self: Animatable {
    /// This view as it is now.
    ///
    /// A view calls this in `makeNodes` and lowers what comes back. While
    /// its numbers are on their way, what comes back is part of the way
    /// there, and the toolkit asks for the next frame.
    func shown(in environment: EnvironmentValues) -> Self {
        environment.viewState?.animating(self) ?? self
    }
}

/// A view whose subtree moves when a value changes.
public struct AnimationView<Content: View, Value: Equatable>: View {
    public typealias Body = Never
    let content: Content
    let animation: Animation?
    let value: Value

    public func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        guard let state = environment.viewState, state.animationValueChanged(value) else {
            content.makeNodes(into: &nodes, environment: environment)
            return
        }
        // The value changed, so everything that this view holds moves with
        // the move that it names.
        var made: [LayoutNode] = []
        state.graph.animating(animation) {
            content.makeNodes(into: &made, environment: environment)
        }
        nodes += made
    }
}

extension View {
    /// Moves the views inside this one when `value` changes.
    ///
    ///     Row(item: item)
    ///         .animation(.quick, value: isSelected)
    ///
    /// The value that a view arrives with is not a change, so a view that
    /// comes into the tree is drawn as it is. `nil` says that a change of
    /// `value` moves nothing, which takes away the move of an outer
    /// `withAnimation`.
    ///
    /// This is the modifier of SwiftUI, and it needs what SwiftUI needs: a
    /// graph that knows which values a view read. See Graph.swift.
    public func animation<Value: Equatable>(_ animation: Animation?,
                                            value: Value) -> AnimationView<Self, Value> {
        AnimationView(content: self, animation: animation, value: value)
    }
}
