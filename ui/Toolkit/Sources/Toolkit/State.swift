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
/// A change inside `withAnimation` names a move. The value itself goes to
/// its new value at once, as it does in SwiftUI, and the views that draw it
/// move instead of jumping. See AnimatedValue.swift.
///
/// A change made while the tree is being laid out lands after that work, so
/// a body that names a target draws the value that the frame started with
/// and the target in the frame after it.
@propertyWrapper
public struct State<Value> {
    final class Box {
        /// Where the value is going. A read gives this one when nothing is
        /// moving, and it is what another write starts from.
        var value: Value
        var onChange: () -> Void = {}
        /// Where to reach the graph of this tree.
        var state: ViewState?
        /// This value in the graph. A body that reads the value depends on
        /// it from then on, and a write marks that body out of date.
        var attribute: Attribute<Value>?

        init(_ value: Value) { self.value = value }

        /// The value in the graph, made the first time it is needed.
        func attribute(in graph: Graph) -> Attribute<Value> {
            if let attribute { return attribute }
            let made = graph.source(value)
            attribute = made
            return made
        }

        /// The value.
        ///
        /// The read goes through the graph, so the body that reads it now
        /// depends on it: a later write marks that body out of date and
        /// nothing else.
        var shown: Value {
            guard let graph = state?.graph else { return value }
            return graph.value(of: attribute(in: graph))
        }

        /// Gives the value a new value. Inside `withAnimation`, the views
        /// that draw it move to it instead of jumping.
        func set(_ newValue: Value) {
            value = newValue
            if let graph = state?.graph {
                graph.set(attribute(in: graph), to: newValue,
                          animation: Transaction.animation)
            }
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
/// A state value in the graph, without its type. The store uses it to take
/// the value out of the graph when its view goes away.
protocol AnyStateBox: AnyObject {
    var anyAttribute: AnyAttribute? { get }
}

extension State.Box: AnyStateBox {
    var anyAttribute: AnyAttribute? { attribute }
}

protocol AnyStateProperty {
    var anyBox: AnyObject { get }
    /// Copies the value of an earlier box of the same property into this one.
    func adopt(_ box: AnyObject)
    func onChange(_ action: @escaping () -> Void)
}

extension State: AnyEnvironmentProperty {
    func take(from environment: EnvironmentValues) {
        box.state = environment.viewState
    }
}

extension State: AnyStateProperty {
    var anyBox: AnyObject { box }

    func adopt(_ other: AnyObject) {
        guard let other = other as? Box else { return }
        box.value = other.value
        // The value in the graph is the one that other views depend on.
        box.attribute = other.attribute
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

    /// What a view made last time, and what it was made from.
    ///
    /// A pass that finds the same view value in the same place, in the same
    /// environment, keeps these nodes. It then never asks the view for its
    /// body, and everything that hangs off those nodes stays as well: the
    /// size they worked out, the glyphs of a line of text, the picture of
    /// that line.
    private final class Entry {
        let attribute: Attribute<[LayoutNode]>
        /// The view value and the environment that the nodes came from.
        let holder: Holder
        /// The state that lives under this view. A pass that keeps the
        /// nodes keeps that state with them.
        var keys: Set<Key> = []

        init(attribute: Attribute<[LayoutNode]>, holder: Holder) {
            self.attribute = attribute
            self.holder = holder
        }
    }

    /// What the rule of an entry reads. The rule holds this and not the
    /// view, so a new view value needs no new rule.
    private final class Holder {
        var view: Any
        var environment: EnvironmentValues

        init(view: Any, environment: EnvironmentValues) {
            self.view = view
            self.environment = environment
        }
    }

    /// The values of this tree, and what each one depends on.
    let graph = Graph()

    private var boxes: [Key: AnyObject] = [:]
    private var entries: [Key: Entry] = [:]
    /// Where each view that can move is on its way. The key is the place of
    /// the view in the tree, as it is for state.
    private var motions: [Key: Moving] = [:]
    /// The body that a move belongs to. A view inside a branch of an `if`,
    /// or inside a ForEach, has a place of its own that holds no body, so
    /// the move names the body that made it.
    private struct Moving {
        let motion: AnyViewMotion
        let owner: Key
    }
    /// The bodies that are running now. The last one owns what it lowers.
    private var owners: [Key] = []
    /// The values that `.animation(_:value:)` watches, from the last pass.
    private var watched: [Key: Any] = [:]
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
        // A view that is on its way is drawn differently in this frame, so
        // the view that made it must make it again.
        for moving in motions.values where moving.motion.isMoving(now: now) {
            guard let entry = entries[moving.owner] else { continue }
            graph.invalidate(entry.attribute)
        }
    }

    /// The renderer calls this after it lowers the view tree. The state of a
    /// view that is no longer in the tree goes away, and so do the values
    /// that the graph kept for it.
    func endPass() {
        // `seen` holds the name of each view as well as the name of each
        // state value, so the two counts say nothing about each other.
        for (key, box) in boxes where !seen.contains(key) {
            // The value of a view that went away leaves the graph with it.
            if let attribute = (box as? AnyStateBox)?.anyAttribute { graph.forget(attribute) }
            boxes[key] = nil
        }
        for (key, entry) in entries where !seen.contains(key) {
            graph.forget(entry.attribute)
            entries[key] = nil
        }
        // A move belongs to the view that made it, not to one pass. A view
        // whose body did not run this time keeps its moves, because the
        // pass counts the names of everything under a view that it keeps.
        motions = motions.filter { seen.contains($0.key) }
        watched = watched.filter { seen.contains($0.key) }
    }

    /// The view as it is now, on its way to what it says it is.
    ///
    /// A view that can move calls this while it lowers itself. The first
    /// call writes down where the view is. A later call with another value
    /// starts a move, if a move is in the air, and gives back the view part
    /// of the way there.
    func animating<V: View & Animatable>(_ view: V) -> V {
        let key = Key(path: path, slot: animationSlot())
        seen.insert(key)
        let target = view.animatableData
        guard let owner = owners.last else { return view }
        guard let motion = (motions[key]?.motion as? ViewMotion<V>) else {
            motions[key] = Moving(motion: ViewMotion<V>(target), owner: owner)
            return view
        }
        if motion.target != target {
            motion.move(to: target, with: graph.animation, now: now)
        }
        guard motion.isMoving(now: now) else { return view }
        // The view has somewhere still to go, so the frame after this one
        // must be drawn.
        isMoving = true
        return motion.shown(view, now: now)
    }

    /// True when the value that a `.animation(_:value:)` watches is not
    /// the value that it had when this place was last lowered.
    ///
    /// The first time is not a change: a view that arrives is drawn as it
    /// is, and only what happens to it after that moves.
    func animationValueChanged(_ value: some Equatable) -> Bool {
        let key = Key(path: path, slot: watchSlot())
        seen.insert(key)
        defer { watched[key] = value }
        guard let old = watched[key] else { return false }
        return !isEqual(old, value)
    }

    private func watchSlot() -> Int {
        let index = counts[counts.count - 1][-3] ?? 0
        counts[counts.count - 1][-3] = index + 1
        return index
    }

    private func isEqual(_ old: Any, _ new: some Equatable) -> Bool {
        guard let old = old as? any Equatable else { return false }
        return isEqual(old, new as Any)
    }

    /// Which view that can move this is, among the ones in this body. The
    /// count lives with the other counts of the level, so a view inside a
    /// branch of an `if` has a count of its own.
    private func animationSlot() -> Int {
        let index = counts[counts.count - 1][-2] ?? 0
        counts[counts.count - 1][-2] = index + 1
        return index
    }

    /// The nodes of one view.
    ///
    /// `make` lowers the view. It runs only when this is the first pass for
    /// this view, or when the view value changed, or when the environment
    /// changed, or when something that the body read changed. Otherwise the
    /// nodes of the last pass come back as they are.
    func nodes<V: View>(for view: V, environment: EnvironmentValues,
                        make: @escaping (V, EnvironmentValues) -> [LayoutNode]) -> [LayoutNode] {
        // One entry for each view. The slot of -1 is not the slot of any
        // state property, so the two never meet.
        let key = Key(path: path, slot: -1)
        seen.insert(key)

        let entry: Entry
        if let existing = entries[key] {
            entry = existing
            if !isSameView(existing.holder.view, view)
                || !existing.holder.environment.isSame(as: environment) {
                existing.holder.view = view
                existing.holder.environment = environment
                graph.invalidate(existing.attribute)
            }
        } else {
            let holder = Holder(view: view, environment: environment)
            let attribute = graph.rule { _ -> [LayoutNode] in
                guard let view = holder.view as? V else { return [] }
                return make(view, holder.environment)
            }
            entry = Entry(attribute: attribute, holder: holder)
            entries[key] = entry
        }

        let runs = graph.evaluations
        let before = seen
        owners.append(key)
        let nodes = graph.value(of: entry.attribute)
        owners.removeLast()
        if graph.evaluations == runs {
            // The nodes are the ones from an earlier pass, so the state
            // under them is in this tree as well.
            seen.formUnion(entry.keys)
        } else {
            entry.keys = seen.subtracting(before)
        }
        return nodes
    }

    /// True when a view is the same value as the one that made the nodes.
    ///
    /// A view that is not Equatable is never the same one. It says nothing
    /// about itself, so the toolkit asks it for its body again.
    private func isSameView(_ old: Any, _ new: some View) -> Bool {
        guard let old = old as? any Equatable else { return false }
        return isEqual(old, new)
    }

    private func isEqual<Value: Equatable>(_ old: Value, _ new: Any) -> Bool {
        guard let new = new as? Value else { return false }
        return old == new
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
