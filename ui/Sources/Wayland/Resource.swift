/// A Wayland interface. wayland-swift-scanner makes one enum for each
/// interface in a protocol XML file (see Protocols/).
public protocol Interface {
    associatedtype Request
    static var name: String { get }
    static var version: UInt32 { get }
    static func decode(opcode: UInt16, from message: inout MessageReader, version: UInt32) throws(ProtocolError) -> Request
    static func isDestructor(opcode: UInt16) -> Bool
}

/// A protocol object of one client (libwayland calls it a resource).
public class AnyResource {
    /// Nil after the client disconnects.
    public private(set) weak var client: Client?
    public let id: UInt32
    public let version: UInt32
    public let interfaceName: String
    /// True after the resource is destroyed, by a request or because its
    /// client disconnected. Events to a destroyed resource are not sent.
    public private(set) var isDestroyed = false
    /// The server's object for this resource, for example a surface. The
    /// resource keeps it until the resource is destroyed.
    public var data: AnyObject?

    private var destroyHandlers: [() -> Void] = []

    init(client: Client, id: UInt32, version: UInt32, interfaceName: String) {
        self.client = client
        self.id = id
        self.version = version
        self.interfaceName = interfaceName
    }

    /// Runs `handler` when the resource is destroyed.
    public func onDestroy(_ handler: @escaping () -> Void) {
        destroyHandlers.append(handler)
    }

    /// Destroys the resource: the client can use its ID again. A request that
    /// is a destructor in the protocol does this after its handler.
    public func destroy() {
        client?.destroy(self)
    }

    /// Makes an object that a request of this resource asked for.
    public func create<I: Interface>(_ newID: NewID<I>) -> Resource<I> {
        guard let client else { fatalError("create(\(I.name)) after the client disconnected") }
        return client.create(newID)
    }

    /// Sends a protocol error about this resource and disconnects the client.
    public func postError(code: UInt32, _ message: String) {
        client?.post(ProtocolError(objectID: id, code: code, message: message))
    }

    func dispatch(opcode: UInt16, message: inout MessageReader) throws(ProtocolError) {
        fatalError("AnyResource.dispatch is abstract")
    }

    func markDestroyed() {
        guard !isDestroyed else { return }
        isDestroyed = true
        let handlers = destroyHandlers
        destroyHandlers.removeAll()
        for handler in handlers { handler() }
        data = nil
    }

    /// Starts an event, or returns nil if the resource cannot get it.
    func beginEvent(opcode: UInt16, since: UInt32) -> MessageWriter? {
        guard !isDestroyed, version >= since, client != nil else { return nil }
        return MessageWriter(objectID: id, opcode: opcode)
    }

    func send(_ event: MessageWriter) {
        client?.queue(event)
    }
}

/// A protocol object of interface `I`. Its events are methods in the
/// generated code, for example `Resource<WlCallback>.sendDone(callbackData:)`.
public final class Resource<I: Interface>: AnyResource {
    /// Called for each request. A request that makes an object (a NewID
    /// argument) must make it with `create(_:)`. A request with a file
    /// descriptor gives it to the handler, which must close it.
    public var onRequest: ((I.Request) -> Void)?

    init(client: Client, id: UInt32, version: UInt32) {
        super.init(client: client, id: id, version: version, interfaceName: I.name)
    }

    override func dispatch(opcode: UInt16, message: inout MessageReader) throws(ProtocolError) {
        let request = try I.decode(opcode: opcode, from: &message, version: version)
        onRequest?(request)
        if I.isDestructor(opcode: opcode), !isDestroyed { destroy() }
    }
}
