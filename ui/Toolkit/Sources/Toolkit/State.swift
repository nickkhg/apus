// A view is a value, and the toolkit makes the view tree again for each
// frame. Thus a value in a view cannot survive a frame: the next frame makes
// a new view. @State keeps the value outside the view, in a ViewState store,
// and connects it to the new view at the start of each frame.
//
// Which value belongs to which view comes from the position of the view in
// the tree: the type of the view, the number of views of that type before it,
// and the path from the root. ForEach adds the identity of the element, so
// that the state of a row follows the row when the rows change order.
//
// This is the same rule as in SwiftUI. It has the same result: if you remove
// a view, its state goes away, and if a view moves to another position, it
// gets the state of that position.

/// A value that a view owns and can change. A change asks for a new frame.
///
///     struct Counter: View {
///         @State private var count = 0
///         var body: some View { Text("\(count)") }
///     }
///
/// Only a view with a `body` can have state. A view that draws itself
/// (`Body == Never`) cannot.
///
/// A change inside `withAnimation` moves to its new value instead of
/// jumping to it, if the type of the value is Animatable. A read then gives
/// where the value is now, not where it is going, so a view may name the
/// same target again and start nothing. See Motion.swift.
@propertyWrapper
public struct State<Value> {
    final class Box {
        /// Where the value is going. A read gives this one when nothing is
        /// moving, and it is what another write starts from.
        var value: Value
        /// The move that a `withAnimation` started, while it lasts.
        var motion: AnyMotion?
        var onChange: () -> Void = {}
        /// The time of this frame, and where to say that a move is not
        /// finished. Both come from the environment.
        var now: Double = 0
        var state: ViewState?

        init(_ value: Value) { self.value = value }

        /// Where the value is now: on its way if a move is running.
        var shown: Value {
            guard let motion, motion.isMoving(now: now),
                  let moving = motion.value(now: now) as? Value else { return value }
            // A value on its way needs the frame after this one.
            state?.isMoving = true
            return moving
        }

        func set(_ newValue: Value) {
            // A change inside `withAnimation` moves from where the value is
            // now, so a move that turns around does not jump.
            if let animation = Transaction.animation,
               let target = newValue as? any Animatable {
                // The same target again is not a new move, and it must not
                // ask for a frame: a view that names its target in its body
                // would then draw for ever.
                if let going = value as? any Animatable, sameTarget(going, target) { return }
                if let start = shown as? any Animatable {
                    motion = startMotion(from: start, to: target, with: animation, now: now)
                    if motion != nil { state?.isMoving = true }
                }
            } else {
                motion = nil
            }
            value = newValue
            onChange()
        }
    }

    let box: Box

    public init(wrappedValue: Value) {
        box = Box(wrappedValue)
    }

    public var wrappedValue: Value {
        get { box.shown }
        nonmutating set { box.set(newValue) }
    }

    /// `$count` gives a binding, for a view that changes the value.
    public var projectedValue: Binding<Value> {
        Binding(get: { box.shown }, set: { box.set($0) })
    }
}

/// A reference to a value that another view owns.
@propertyWrapper
public struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    /// A binding to a value that does not change.
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }

    public var projectedValue: Binding<Value> { self }
}

// MARK: - The store

/// What the toolkit knows about a state property, without its value type.
protocol AnyStateProperty {
    var anyBox: AnyObject { get }
    /// Copies the value of an earlier box of the same property into this one.
    func adopt(_ box: AnyObject)
    func onChange(_ action: @escaping () -> Void)
}

extension State: AnyEnvironmentProperty {
    func take(from environment: EnvironmentValues) {
        box.now = environment.now
        box.state = environment.viewState
    }
}

extension State: AnyStateProperty {
    var anyBox: AnyObject { box }

    func adopt(_ other: AnyObject) {
        guard let other = other as? Box else { return }
        box.value = other.value
        // The move that the store kept is the one that goes on running.
        box.motion = other.motion
    }

    func onChange(_ action: @escaping () -> Void) {
        box.onChange = action
    }
}

/// The values of the `@State` properties of a view tree, from one frame to
/// the next. The compositor keeps one of these and gives it to the renderer.
///
/// The UI runs on one thread. Two threads must not draw the same ViewState at
/// the same time.
public final class ViewState: @unchecked Sendable {
    /// Called when a state value changes. The compositor asks for a frame.
    public var needsUpdate: () -> Void = {}

    /// The time of the frame that is being drawn, in seconds.
    public internal(set) var now: Double = 0
    /// Set by a view that has somewhere still to move. The host then asks
    /// for another frame.
    public var isMoving = false

    /// One state property: where its view is, and which property it is.
    private struct Key: Hashable {
        let path: [Int]
        let slot: Int
    }

    private var boxes: [Key: AnyObject] = [:]
    private var seen: Set<Key> = []
    /// The path to the view that the renderer is in now.
    private var path: [Int] = []
    /// For each level, how many views of each type are there already.
    private var counts: [[Int: Int]] = [[:]]

    public init() {}

    // MARK: Passes

    /// The renderer calls this before it lowers the view tree.
    func beginPass() {
        path.removeAll(keepingCapacity: true)
        counts = [[:]]
        seen.removeAll(keepingCapacity: true)
    }

    /// The renderer calls this after it lowers the view tree. The state of a
    /// view that is no longer in the tree goes away.
    func endPass() {
        guard seen.count != boxes.count else { return }
        boxes = boxes.filter { seen.contains($0.key) }
    }

    // MARK: Position in the tree

    /// Enters the scope of a view of this type. Views of the same type in the
    /// same parent get 0, 1, 2 and so on.
    func enter(_ type: Any.Type) {
        let name = ObjectIdentifier(type).hashValue
        let index = counts[counts.count - 1][name] ?? 0
        counts[counts.count - 1][name] = index + 1
        enter(identity: name &* 31 &+ index)
    }

    /// Enters a scope with an identity of its own: an element of a ForEach,
    /// or a branch of an `if`.
    func enter(identity: Int) {
        path.append(identity)
        counts.append([:])
    }

    func leave() {
        path.removeLast()
        counts.removeLast()
    }

    // MARK: Values

    /// Connects the `@State` properties of `view` to their values. A property
    /// that has no value yet keeps the value that the view gave it.
    func connect(_ view: some View, environment: EnvironmentValues) {
        var slot = 0
        for child in Mirror(reflecting: view).children {
            if let reader = child.value as? AnyEnvironmentProperty {
                reader.take(from: environment)
            }
            guard let property = child.value as? AnyStateProperty else { continue }
            let key = Key(path: path, slot: slot)
            slot += 1
            if let stored = boxes[key] {
                property.adopt(stored)
            }
            boxes[key] = property.anyBox
            seen.insert(key)
            property.onChange { [weak self] in self?.needsUpdate() }
        }
    }

    /// A name for a view that watches the pointer. It is the same in the
    /// next frame, because it comes from the position of the view.
    func interactionIdentity() -> Int {
        // -1 is not the hash of a type, so the count of the pointer watchers
        // in this view is its own.
        let index = counts[counts.count - 1][-1] ?? 0
        counts[counts.count - 1][-1] = index + 1
        var hasher = Hasher()
        for component in path { hasher.combine(component) }
        hasher.combine(index)
        return hasher.finalize()
    }

    /// The number of state properties that the store keeps. Tests use it.
    var count: Int { boxes.count }
}
