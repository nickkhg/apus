// What a move works on.
//
// This is the SwiftUI model. A type says what part of it moves, as a value
// that can be added, subtracted and scaled, and the toolkit does the rest:
// a move is `from + (to − from) × amount` over that value. A type with more
// than one number puts them in pairs, so that a pair of pairs moves four
// numbers and a colour needs no code of its own.

/// A value that can be added, subtracted and scaled: what a move works on.
public protocol VectorArithmetic: AdditiveArithmetic {
    mutating func scale(by amount: Double)
    /// The square of the length. A move that has arrived has none.
    var magnitudeSquared: Double { get }
}

extension Double: VectorArithmetic {
    public mutating func scale(by amount: Double) { self *= amount }
    public var magnitudeSquared: Double { self * self }
}

/// Two values that move together. A type with four numbers in it is a pair
/// of pairs.
public struct AnimatablePair<First: VectorArithmetic, Second: VectorArithmetic>: VectorArithmetic {
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    public static var zero: AnimatablePair<First, Second> {
        AnimatablePair(First.zero, Second.zero)
    }

    public static func + (a: Self, b: Self) -> Self {
        AnimatablePair(a.first + b.first, a.second + b.second)
    }

    public static func - (a: Self, b: Self) -> Self {
        AnimatablePair(a.first - b.first, a.second - b.second)
    }

    public mutating func scale(by amount: Double) {
        first.scale(by: amount)
        second.scale(by: amount)
    }

    public var magnitudeSquared: Double {
        first.magnitudeSquared + second.magnitudeSquared
    }
}

/// A value that a move can be part of the way through.
///
/// A type says which of its numbers move. A type that is one number moves as
/// itself, and needs to say no more than that it is Animatable:
///
///     extension Double: Animatable {}
public protocol Animatable {
    associatedtype AnimatableData: VectorArithmetic
    var animatableData: AnimatableData { get set }
}

extension Animatable where AnimatableData == Self {
    public var animatableData: Self {
        get { self }
        set { self = newValue }
    }
}

extension Animatable {
    /// This value `amount` of the way to another one. An amount above 1 is
    /// past the other one, which is how a spring overshoots.
    public func moved(to end: Self, amount: Double) -> Self {
        var step = end.animatableData - animatableData
        step.scale(by: amount)
        var result = self
        result.animatableData = animatableData + step
        return result
    }

    /// True when the two values are the same value to move to.
    public func arrived(at end: Self) -> Bool {
        (end.animatableData - animatableData).magnitudeSquared == 0
    }
}

extension Double: Animatable {
    public typealias AnimatableData = Double
}

extension Color: Animatable {
    /// Each part of the colour moves on its own, so a colour arrives all at
    /// once.
    public var animatableData: AnimatablePair<AnimatablePair<Double, Double>,
                                              AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(red, green), AnimatablePair(blue, alpha)) }
        set {
            self = Color(red: newValue.first.first, green: newValue.first.second,
                         blue: newValue.second.first, alpha: newValue.second.second)
        }
    }
}

extension Size: Animatable {
    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(width, height) }
        set { self = Size(width: newValue.first, height: newValue.second) }
    }
}

extension Frame: Animatable {
    public var animatableData: AnimatablePair<AnimatablePair<Double, Double>,
                                              AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(x, y), AnimatablePair(width, height)) }
        set {
            self = Frame(x: newValue.first.first, y: newValue.first.second,
                         width: newValue.second.first, height: newValue.second.second)
        }
    }
}
