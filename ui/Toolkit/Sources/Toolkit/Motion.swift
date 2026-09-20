/// How a value moves from one number to another.
///
/// Motion says where a thing went. It is short, and the design must be
/// correct with no motion at all: a screen drawn with every move finished is
/// the same screen. So a renderer that cannot hold the frame rate may end
/// every move at once and lose nothing but the pleasure.
public struct Animation: Equatable, Sendable {
    public enum Curve: Sendable, Equatable {
        /// The same speed from end to end. For a value that has no weight,
        /// such as a colour.
        case linear
        /// Fast at the start and slow at the end. This is the one to use
        /// when a thing arrives somewhere.
        case easeOut
        /// Slow at both ends. For a thing that leaves and arrives.
        case easeInOut
    }

    /// How long the move takes, in seconds.
    public var duration: Double
    public var curve: Curve

    public init(duration: Double, curve: Curve = .easeOut) {
        self.duration = duration
        self.curve = curve
    }

    /// A control answers the pointer at once.
    public static let quick = Animation(duration: 0.12, curve: .easeOut)
    /// A surface opens or closes.
    public static let surface = Animation(duration: 0.16, curve: .easeOut)
    /// A window moves to another cell.
    public static let window = Animation(duration: 0.24, curve: .easeInOut)
    /// Nothing moves: the value jumps to its target.
    public static let none = Animation(duration: 0, curve: .linear)

    /// How far the move has come after `time` seconds, from 0 to 1.
    public func amount(after time: Double) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(max(time / duration, 0), 1)
        return switch curve {
        case .linear: t
        case .easeOut: 1 - pow(1 - t, 3)
        case .easeInOut: t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

/// A number that moves to its target instead of jumping to it.
///
///     @State private var glow = Motion(0)
///     ...
///     glow.move(to: isHovered ? 1 : 0, with: .quick, now: now)
///     let amount = glow.value(now: now)
///
/// A view keeps one of these in `@State`. While it moves it asks for the
/// next frame, so the host keeps drawing until it arrives.
public final class Motion: @unchecked Sendable {
    private var from: Double
    private var to: Double
    private var startedAt: Double
    private var animation: Animation

    public init(_ value: Double = 0) {
        from = value
        to = value
        startedAt = 0
        animation = .none
    }

    /// The target. A new target starts a move from wherever the value is
    /// now, so a move that turns around does not jump. It answers whether
    /// this started a move: the same target again starts nothing.
    @discardableResult
    public func move(to target: Double, with animation: Animation, now: Double) -> Bool {
        guard target != to else { return false }
        from = value(now: now)
        to = target
        startedAt = now
        self.animation = animation
        return true
    }

    /// Where the value is.
    public func value(now: Double) -> Double {
        let amount = animation.amount(after: now - startedAt)
        return from + (to - from) * amount
    }

    /// True while the value still has somewhere to go.
    public func isMoving(now: Double) -> Bool {
        now - startedAt < animation.duration
    }

    /// Takes the move of another Motion. The store keeps one of these from
    /// frame to frame, and the new view adopts it.
    func adopt(_ other: Motion) {
        from = other.from
        to = other.to
        startedAt = other.startedAt
        animation = other.animation
    }
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

/// A number that a view sets and the toolkit moves.
///
///     struct Icon: View {
///         @Animated(.quick) private var glow = 0.0
///         var body: some View {
///             Color.white.opacity(glow)
///                 .onHover { glow = $0 ? 1 : 0 }
///         }
///     }
///
/// Reading it gives where the value is now. Writing it gives the value
/// somewhere to go. While it is on its way the view is drawn again, so the
/// move carries on without the view asking.
@propertyWrapper
public struct Animated {
    final class Box {
        let motion: Motion
        var animation: Animation
        var now: Double = 0
        var state: ViewState?
        var onChange: () -> Void = {}

        init(_ value: Double, _ animation: Animation) {
            motion = Motion(value)
            self.animation = animation
        }
    }

    let box: Box

    public init(wrappedValue: Double, _ animation: Animation = .quick) {
        box = Box(wrappedValue, animation)
    }

    public var wrappedValue: Double {
        get {
            // A value on its way needs the frame after this one.
            if box.motion.isMoving(now: box.now) { box.state?.isMoving = true }
            return box.motion.value(now: box.now)
        }
        nonmutating set {
            // The same target again is not a move, and it must not ask for
            // a frame: a view that sets its target in its body would then
            // draw for ever.
            guard box.motion.move(to: newValue, with: box.animation, now: box.now) else { return }
            box.state?.isMoving = true
            box.onChange()
        }
    }
}

extension Animated: AnyEnvironmentProperty {
    func take(from environment: EnvironmentValues) {
        box.now = environment.now
        box.state = environment.viewState
    }
}

extension Animated: AnyStateProperty {
    var anyBox: AnyObject { box }

    func adopt(_ stored: AnyObject) {
        guard let stored = stored as? Box else { return }
        // The value that the store kept is the one that goes on moving.
        box.motion.adopt(stored.motion)
    }

    func onChange(_ action: @escaping () -> Void) {
        box.onChange = action
    }
}
