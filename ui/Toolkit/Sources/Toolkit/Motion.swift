// How a value moves from one value to another, and how a view asks for it.
//
// This follows SwiftUI: `withAnimation` names a move, the state that changes
// inside it moves to its new value instead of jumping to it, and a view
// reads the value on its way. See Animatable.swift for what can move.
//
// Motion says where a thing went. It is short, and the design must be
// correct with no motion at all: a screen drawn with every move finished is
// the same screen. So a renderer that cannot hold the frame rate may end
// every move at once and lose nothing but the pleasure.

/// How a value moves: how long it takes, and how the speed changes on the
/// way.
///
///     withAnimation(.easeOut(duration: 0.2)) { isOpen = true }
public struct Animation: Equatable, Sendable {
    public enum Curve: Sendable, Equatable {
        /// The same speed from end to end. For a value that has no weight,
        /// such as a colour.
        case linear
        /// Slow at the start. For a thing that leaves.
        case easeIn
        /// Fast at the start and slow at the end. This is the one to use
        /// when a thing arrives somewhere.
        case easeOut
        /// Slow at both ends. For a thing that leaves and arrives.
        case easeInOut
        /// It goes past its target by `bounce` of the distance, then comes
        /// back to it. For a surface that arrives with some weight.
        ///
        /// This is one overshoot, not a spring that swings and settles: a
        /// polynomial gives it, so the toolkit needs no maths library.
        case spring(bounce: Double)
    }

    public var curve: Curve
    /// How long the move takes, in seconds, before `speed` changes it.
    public var duration: Double
    /// How long the move waits before it starts.
    public var delay: Double
    /// How much faster the move goes. 2 makes it take half the time.
    public var speed: Double

    init(curve: Curve, duration: Double, delay: Double = 0, speed: Double = 1) {
        self.curve = curve
        self.duration = duration
        self.delay = delay
        self.speed = speed
    }

    // MARK: The moves

    /// The move that a value makes when nothing says otherwise.
    public static let `default` = Animation(curve: .easeInOut, duration: 0.25)

    public static func linear(duration: Double = 0.25) -> Animation {
        Animation(curve: .linear, duration: duration)
    }

    public static func easeIn(duration: Double = 0.25) -> Animation {
        Animation(curve: .easeIn, duration: duration)
    }

    public static func easeOut(duration: Double = 0.25) -> Animation {
        Animation(curve: .easeOut, duration: duration)
    }

    public static func easeInOut(duration: Double = 0.25) -> Animation {
        Animation(curve: .easeInOut, duration: duration)
    }

    /// A move with some weight. A bounce of 0 arrives without going past
    /// its target, and more than 0 goes past it once and comes back.
    public static func spring(duration: Double = 0.4, bounce: Double = 0.2) -> Animation {
        Animation(curve: .spring(bounce: bounce), duration: duration)
    }

    public static let linear = Animation.linear()
    public static let easeIn = Animation.easeIn()
    public static let easeOut = Animation.easeOut()
    public static let easeInOut = Animation.easeInOut()
    public static let spring = Animation.spring()

    /// The value jumps to its target. A move of no time is what a renderer
    /// that cannot hold the frame rate can fall back to.
    static let instant = Animation(curve: .linear, duration: 0)

    // MARK: Changing a move

    /// The same move, after a wait.
    public func delay(_ seconds: Double) -> Animation {
        Animation(curve: curve, duration: duration, delay: delay + seconds, speed: speed)
    }

    /// The same move, faster. 2 takes half the time.
    public func speed(_ factor: Double) -> Animation {
        Animation(curve: curve, duration: duration, delay: delay,
                  speed: speed * max(factor, 0.000_001))
    }

    /// The same move over a different time.
    public func duration(_ seconds: Double) -> Animation {
        Animation(curve: curve, duration: seconds, delay: delay, speed: speed)
    }

    // MARK: Where the move is

    /// How long the whole move takes, the wait as well.
    public var length: Double {
        delay + duration / speed
    }

    /// How far the move has come after `time` seconds, from 0 to 1. A
    /// spring answers more than 1 in the middle, which is the overshoot.
    public func amount(after time: Double) -> Double {
        let run = (time - delay) * speed
        guard duration > 0 else { return run >= 0 ? 1 : 0 }
        let t = min(max(run / duration, 0), 1)
        return switch curve {
        case .linear: t
        case .easeIn: t * t * t
        case .easeOut: 1 - pow(1 - t, 3)
        case .easeInOut: t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .spring(let bounce): Animation.overshoot(t, by: bounce)
        }
    }

    /// The curve that goes past 1 and comes back to it. At the end of the
    /// time it is exactly 1, whatever the bounce is.
    private static func overshoot(_ t: Double, by bounce: Double) -> Double {
        let back = max(0, bounce) * 8.5
        let away = t - 1
        return 1 + (back + 1) * away * away * away + back * away * away
    }
}

/// The move that the state changes of this moment belong to.
///
/// This is SwiftUI's transaction, with the one thing in it that the toolkit
/// uses. It is a task value, not a global one: `withAnimation` binds it for
/// the work inside it alone, so two trees on two threads never see each
/// other's moves.
public enum Transaction {
    @TaskLocal public static var animation: Animation?
}

/// Moves the state that `body` changes, instead of letting it jump.
///
///     .onHover { hovering in
///         withAnimation(.easeOut(duration: 0.12)) { glow = hovering ? 1 : 0 }
///     }
///
/// A value moves only if its type is Animatable. Anything else changes at
/// once, as it does without this.
///
/// `nil` takes the move away, for a change inside another move that must
/// not move.
@discardableResult
public func withAnimation<Result>(_ animation: Animation? = .default,
                                  _ body: () throws -> Result) rethrows -> Result {
    try Transaction.$animation.withValue(animation, operation: body)
}

/// A value that moves to its target instead of jumping to it.
///
/// `@State` uses one of these for a value that changes inside
/// `withAnimation`. A view can also hold one itself, for a value that the
/// view moves without a state change.
public final class Motion<Value: Animatable>: @unchecked Sendable {
    private var from: Value
    private var to: Value
    private var startedAt: Double
    private var animation: Animation

    public init(_ value: Value) {
        from = value
        to = value
        startedAt = 0
        animation = .instant
    }

    /// The target. A new target starts a move from wherever the value is
    /// now, so a move that turns around does not jump. It answers whether
    /// this started a move: the same target again starts nothing.
    @discardableResult
    public func move(to target: Value, with animation: Animation, now: Double) -> Bool {
        guard !to.arrived(at: target) else { return false }
        from = value(now: now)
        to = target
        startedAt = now
        self.animation = animation
        return true
    }

    /// Where the value is.
    public func value(now: Double) -> Value {
        guard isMoving(now: now) else { return to }
        return from.moved(to: to, amount: animation.amount(after: now - startedAt))
    }

    /// True while the value still has somewhere to go.
    public func isMoving(now: Double) -> Bool {
        now - startedAt < animation.length
    }

    /// Takes the move of another Motion. The store keeps one of these from
    /// frame to frame, and the new view adopts it.
    func adopt(_ other: Motion<Value>) {
        from = other.from
        to = other.to
        startedAt = other.startedAt
        animation = other.animation
    }
}

/// A move without its type, so that `@State` can hold one for any value.
protocol AnyMotion: AnyObject {
    func value(now: Double) -> Any
    func isMoving(now: Double) -> Bool
}

final class TypedMotion<Value: Animatable>: AnyMotion {
    let motion: Motion<Value>

    init(_ motion: Motion<Value>) {
        self.motion = motion
    }

    func value(now: Double) -> Any { motion.value(now: now) }
    func isMoving(now: Double) -> Bool { motion.isMoving(now: now) }
}

/// A move from where a value is now to where it is going. Nil when the two
/// values are of different types, or when the value is there already.
func startMotion<Start: Animatable>(from start: Start, to target: any Animatable,
                                    with animation: Animation, now: Double) -> AnyMotion? {
    guard let target = target as? Start else { return nil }
    let motion = Motion(start)
    guard motion.move(to: target, with: animation, now: now) else { return nil }
    return TypedMotion(motion)
}

/// True when a value is already on its way to this target.
func sameTarget<Going: Animatable>(_ going: Going, _ target: any Animatable) -> Bool {
    guard let target = target as? Going else { return false }
    return going.arrived(at: target)
}

/// The square root, the power and the rest come from the standard library on
/// both platforms, but `pow` for two Doubles does not. This is the one that
/// the curves need.
func pow(_ base: Double, _ exponent: Double) -> Double {
    guard base > 0 else { return 0 }
    // Only whole exponents are used here, so a loop is exact and needs no
    // maths library.
    if exponent == exponent.rounded(), exponent >= 0, exponent < 16 {
        var result = 1.0
        for _ in 0..<Int(exponent) { result *= base }
        return result
    }
    return base
}
