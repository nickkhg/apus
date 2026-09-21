// The graph of the values that a frame is made of, and of what each value
// depends on.
//
// This is the model of SwiftUI's AttributeGraph. A value is an attribute. An
// attribute with a rule works its value out from other attributes, and the
// graph writes down which ones the rule read while it ran. A change to one
// attribute therefore knows exactly which values it spoiled: the ones that
// read it, and the ones that read those, and no others.
//
// Nothing is worked out before it is asked for, and nothing is worked out
// twice. A frame asks for the value at the root, and the answer pulls in the
// parts that changed and no more. The parts that did not change keep the
// value that they had, and with it everything that hangs off that value: a
// laid-out node, the glyphs of a line of text, the picture of that line.
//
// The graph also carries a move. A change made inside `withAnimation` marks
// what it spoils with that move, and the move is then in the air while those
// rules run again. An attribute that can move reads it and moves instead of
// jumping. See Motion.swift and AnimatedValue.swift.

/// A value in the graph, without its type.
public class AnyAttribute {
    /// What the rule read while it last ran. The graph writes this down as
    /// the rule runs, so a rule that reads a value only on one branch
    /// depends on that value only while it takes that branch.
    fileprivate var inputs: Set<ObjectIdentifier> = []
    /// The attributes whose rules read this one.
    fileprivate var outputs: Set<ObjectIdentifier> = []
    /// True when the value is out of date.
    fileprivate var isDirty = false
    /// True while the rule runs. A rule that reads its own attribute would
    /// otherwise never end.
    fileprivate var isRunning = false
    /// The move that the change belongs to, until the rule runs again.
    fileprivate var pendingAnimation: Animation?
    /// False until a value is worked out the first time.
    fileprivate var hasValue = false

    fileprivate init() {}

    /// Works the value out. `Attribute` does it; this class holds no value.
    fileprivate func run(_ graph: Graph) {}
}

/// A value in the graph.
///
/// A source holds a value that something outside the graph writes. A rule
/// works its value out from other attributes, and it runs again only after
/// one of those changes.
public final class Attribute<Value>: AnyAttribute {
    fileprivate var cached: Value?
    fileprivate let rule: ((Graph) -> Value)?

    fileprivate init(value: Value) {
        cached = value
        rule = nil
        super.init()
        hasValue = true
    }

    fileprivate init(rule: @escaping (Graph) -> Value) {
        cached = nil
        self.rule = rule
        super.init()
    }

    fileprivate override func run(_ graph: Graph) {
        guard let rule else { return }
        cached = rule(graph)
        hasValue = true
    }
}

/// The attributes, what they depend on, and what is out of date.
///
/// The toolkit keeps one graph for each view tree. It is not safe to use one
/// graph from two threads: the UI runs on one thread.
public final class Graph {
    /// Every attribute that the graph holds. The edges are the names of
    /// attributes and not the attributes themselves, so nothing in here
    /// keeps anything else alive and `forget(_:)` is the only way out.
    private var attributes: [ObjectIdentifier: AnyAttribute] = [:]
    /// The rules that are running now. The last one is the one that a read
    /// belongs to.
    private var running: [AnyAttribute] = []
    /// The moves that the running rules belong to.
    private var animations: [Animation?] = []
    /// The changes that a rule made while it ran. They land when the work
    /// is over. See `set(_:to:animation:)`.
    private var waiting: [() -> Void] = []

    /// How many rules have run. A test and the bench read it: a frame that
    /// changes nothing must run none.
    public private(set) var evaluations = 0

    public init() {}

    /// How many attributes the graph holds. Tests read it.
    public var count: Int { attributes.count }

    // MARK: - Making attributes

    /// A value that something outside the graph writes, such as `@State`.
    public func source<Value>(_ value: Value) -> Attribute<Value> {
        add(Attribute(value: value))
    }

    /// A value that the graph works out from other values. The rule runs
    /// when the value is first asked for, and again after something that it
    /// read changes.
    public func rule<Value>(_ body: @escaping (Graph) -> Value) -> Attribute<Value> {
        add(Attribute(rule: body))
    }

    private func add<Value>(_ attribute: Attribute<Value>) -> Attribute<Value> {
        attributes[ObjectIdentifier(attribute)] = attribute
        return attribute
    }

    /// Takes an attribute out of the graph, with every edge that reaches it.
    /// A view that leaves the tree takes its attributes with it.
    public func forget(_ attribute: AnyAttribute) {
        detach(attribute)
        let name = ObjectIdentifier(attribute)
        for key in attribute.outputs { attributes[key]?.inputs.remove(name) }
        attribute.outputs.removeAll()
        attributes[name] = nil
    }

    // MARK: - Reading and writing

    /// The value of an attribute.
    ///
    /// The rule of a running attribute that reads this one now depends on
    /// it. A value that is out of date is worked out again first.
    public func value<Value>(of attribute: Attribute<Value>) -> Value {
        record(attribute)
        if attribute.isDirty || !attribute.hasValue { evaluate(attribute) }
        guard let cached = attribute.cached else {
            preconditionFailure("an attribute with no value")
        }
        return cached
    }

    /// Writes a source, and marks what read it as out of date.
    ///
    /// A change made while a rule is running lands when the work is over,
    /// as a change of state does in SwiftUI. The values of this frame are
    /// therefore the values that the frame started with, whatever a body
    /// does while it runs, and the change is drawn in the frame after it.
    public func set<Value>(_ attribute: Attribute<Value>, to value: Value,
                           animation: Animation? = nil) {
        guard running.isEmpty else {
            waiting.append { [weak self] in
                self?.write(attribute, value, animation)
            }
            return
        }
        write(attribute, value, animation)
    }

    private func write<Value>(_ attribute: Attribute<Value>, _ value: Value,
                              _ animation: Animation?) {
        attribute.cached = value
        attribute.hasValue = true
        spoil(attribute, animation: animation)
    }

    /// Marks everything that read this attribute as out of date, and
    /// everything that read those.
    public func spoil(_ attribute: AnyAttribute, animation: Animation? = nil) {
        for key in attribute.outputs {
            guard let output = attributes[key] else { continue }
            // A move must reach a value that is already out of date, so a
            // dirty attribute is walked again when it carries no move yet.
            if output.isDirty, animation == nil || output.pendingAnimation != nil { continue }
            output.isDirty = true
            if let animation { output.pendingAnimation = animation }
            spoil(output, animation: animation)
        }
    }

    /// Marks this attribute out of date, and everything that read it. A
    /// view whose value changed marks its own attribute this way.
    public func invalidate(_ attribute: AnyAttribute, animation: Animation? = nil) {
        attribute.isDirty = true
        if let animation { attribute.pendingAnimation = animation }
        spoil(attribute, animation: animation)
    }

    /// True when the value of this attribute must be worked out again.
    public func isDirty(_ attribute: AnyAttribute) -> Bool {
        attribute.isDirty || !attribute.hasValue
    }

    // MARK: - Moves

    /// The move that the rule running now belongs to.
    public var animation: Animation? {
        animations.last ?? nil
    }

    /// Runs `body` with `animation` in the air, so that every value worked
    /// out inside it moves with that move. `.animation(_:value:)` uses it.
    public func animating<Result>(_ animation: Animation?, _ body: () -> Result) -> Result {
        animations.append(animation)
        defer { animations.removeLast() }
        return body()
    }

    // MARK: - The work

    /// Writes down that the rule running now read this attribute.
    private func record(_ attribute: AnyAttribute) {
        guard let reader = running.last else { return }
        reader.inputs.insert(ObjectIdentifier(attribute))
        attribute.outputs.insert(ObjectIdentifier(reader))
    }

    private func evaluate(_ attribute: AnyAttribute) {
        precondition(!attribute.isRunning, "an attribute asked for its own value")
        // The inputs are written down again while the rule runs, so the ones
        // from the last run go first.
        detach(attribute)
        attribute.isRunning = true
        running.append(attribute)
        // The move of the change is in the air for this rule, and for every
        // rule that this one reads.
        animations.append(attribute.pendingAnimation ?? animation)
        attribute.pendingAnimation = nil
        evaluations += 1

        attribute.run(self)

        animations.removeLast()
        running.removeLast()
        attribute.isRunning = false
        attribute.isDirty = false

        // The work is over, so the changes that it made can land.
        if running.isEmpty, !waiting.isEmpty {
            let changes = waiting
            waiting.removeAll()
            for change in changes { change() }
        }
    }

    /// Forgets what an attribute read, on both ends of each edge.
    private func detach(_ attribute: AnyAttribute) {
        let name = ObjectIdentifier(attribute)
        for key in attribute.inputs { attributes[key]?.outputs.remove(name) }
        attribute.inputs.removeAll()
    }
}
