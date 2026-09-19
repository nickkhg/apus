import Glibc

// The Wayland wire format. A message is:
//
//   object ID (32 bits) | size in bytes << 16 | opcode (32 bits) | arguments
//
// Every argument is a multiple of 32 bits, in the byte order of the machine.
// Strings and arrays have a 32-bit length, then the data, padded to 32 bits.
// File descriptors do not go in the message: they go with it, as ancillary
// data (SCM_RIGHTS) on the socket.

/// The codes of wl_display.error, for errors that are not in a protocol's
/// own error enum.
public enum DisplayErrorCode {
    public static let invalidObject: UInt32 = 0
    public static let invalidMethod: UInt32 = 1
    public static let noMemory: UInt32 = 2
    public static let implementation: UInt32 = 3
}

/// A fatal protocol error. The server sends it to the client as
/// wl_display.error, then disconnects the client.
public struct ProtocolError: Error, CustomStringConvertible {
    public let objectID: UInt32
    public let code: UInt32
    public let message: String

    public init(objectID: UInt32, code: UInt32, message: String) {
        (self.objectID, self.code, self.message) = (objectID, code, message)
    }

    public var description: String { "object \(objectID), code \(code): \(message)" }
}

/// A new object that a request asks the server to make. Call
/// `Resource.create(_:)` to make it.
public struct NewID<I: Interface>: Sendable {
    public let id: UInt32
    public let version: UInt32
}

/// A new object of an interface that the request names (wl_registry.bind).
public struct UntypedNewID: Sendable {
    public let interface: String
    public let version: UInt32
    public let id: UInt32
}

/// Reads the arguments of one request.
public struct MessageReader {
    let client: Client
    let objectID: UInt32
    private let bytes: [UInt8]
    private var position = 0

    init(client: Client, objectID: UInt32, bytes: [UInt8]) {
        (self.client, self.objectID, self.bytes) = (client, objectID, bytes)
    }

    private func invalid(_ message: String) -> ProtocolError {
        // libwayland reports bad arguments on the display object.
        ProtocolError(objectID: 1, code: DisplayErrorCode.invalidMethod,
                      message: "invalid arguments for object \(objectID): \(message)")
    }

    public func invalidOpcode(_ opcode: UInt16) -> ProtocolError {
        ProtocolError(objectID: objectID, code: DisplayErrorCode.invalidMethod,
                      message: "invalid method \(opcode) for object \(objectID)")
    }

    private mutating func word() throws(ProtocolError) -> UInt32 {
        guard position + 4 <= bytes.count else { throw invalid("message too short") }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: UInt32.self) }
        position += 4
        return value
    }

    /// Reads a length and that many bytes, padded to 32 bits.
    private mutating func block() throws(ProtocolError) -> ArraySlice<UInt8> {
        let length = Int(try word())
        let padded = (length + 3) & ~3
        guard padded >= length, position + padded <= bytes.count else { throw invalid("length \(length) too large") }
        defer { position += padded }
        return bytes[position..<position + length]
    }

    public mutating func int() throws(ProtocolError) -> Int32 { Int32(bitPattern: try word()) }

    public mutating func uint() throws(ProtocolError) -> UInt32 { try word() }

    /// A signed 24.8 fixed-point number.
    public mutating func fixed() throws(ProtocolError) -> Double { Double(try int()) / 256 }

    public mutating func optionalString() throws(ProtocolError) -> String? {
        let data = try block()
        guard let last = data.last else { return nil }   // length 0: a null string
        guard last == 0 else { throw invalid("string not terminated") }
        return String(decoding: data.dropLast(), as: UTF8.self)
    }

    public mutating func string() throws(ProtocolError) -> String {
        guard let string = try optionalString() else { throw invalid("null string") }
        return string
    }

    public mutating func array() throws(ProtocolError) -> [UInt8] { Array(try block()) }

    /// A file descriptor. The caller owns it and must close it.
    public mutating func fd() throws(ProtocolError) -> Int32 {
        guard let fd = client.takeReceivedFD() else { throw invalid("missing file descriptor") }
        return fd
    }

    public mutating func optionalAnyObject() throws(ProtocolError) -> AnyResource? {
        let id = try word()
        guard id != 0 else { return nil }
        guard let object = client.object(id) else {
            throw ProtocolError(objectID: 1, code: DisplayErrorCode.invalidObject, message: "invalid object \(id)")
        }
        return object
    }

    public mutating func anyObject() throws(ProtocolError) -> AnyResource {
        guard let object = try optionalAnyObject() else { throw invalid("null object") }
        return object
    }

    public mutating func optionalObject<I: Interface>(_: I.Type) throws(ProtocolError) -> Resource<I>? {
        guard let object = try optionalAnyObject() else { return nil }
        guard let typed = object as? Resource<I> else {
            throw invalid("object \(object.id) is a \(object.interfaceName), not a \(I.name)")
        }
        return typed
    }

    public mutating func object<I: Interface>(_ interface: I.Type) throws(ProtocolError) -> Resource<I> {
        guard let object = try optionalObject(interface) else { throw invalid("null \(I.name)") }
        return object
    }

    public mutating func newID<I: Interface>(_: I.Type, version: UInt32) throws(ProtocolError) -> NewID<I> {
        let id = try word()
        try client.checkNewID(id)
        return NewID(id: id, version: version)
    }

    public mutating func untypedNewID() throws(ProtocolError) -> UntypedNewID {
        let interface = try string()
        let version = try uint()
        let id = try word()
        try client.checkNewID(id)
        return UntypedNewID(interface: interface, version: version, id: id)
    }
}

/// Writes the arguments of one event.
public struct MessageWriter {
    private(set) var bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]   // the header, set by finish()
    private(set) var fds: [Int32] = []
    private let objectID: UInt32
    private let opcode: UInt16

    init(objectID: UInt32, opcode: UInt16) {
        (self.objectID, self.opcode) = (objectID, opcode)
    }

    public mutating func uint(_ value: UInt32) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    public mutating func int(_ value: Int32) { uint(UInt32(bitPattern: value)) }

    public mutating func fixed(_ value: Double) { int(Int32((value * 256).rounded())) }

    private mutating func block(_ data: some Collection<UInt8>, length: Int) {
        uint(UInt32(length))
        bytes.append(contentsOf: data)
        bytes.append(contentsOf: repeatElement(0, count: (4 - length % 4) % 4))
    }

    public mutating func string(_ value: String?) {
        guard let value else { return uint(0) }
        let data = Array(value.utf8) + [0]
        block(data, length: data.count)
    }

    public mutating func array(_ value: [UInt8]) { block(value, length: value.count) }

    /// Sends a copy of `fd`. The caller keeps its own.
    public mutating func fd(_ fd: Int32) {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        if copy >= 0 { fds.append(copy) }
    }

    public mutating func object(_ value: AnyResource?) { uint(value?.id ?? 0) }

    public mutating func newID(_ value: AnyResource) { uint(value.id) }

    /// The message with its header.
    func finish() -> (bytes: [UInt8], fds: [Int32]) {
        var message = bytes
        let header = (objectID, UInt32(message.count) << 16 | UInt32(opcode))
        withUnsafeBytes(of: header.0) { message.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: header.1) { message.replaceSubrange(4..<8, with: $0) }
        return (message, fds)
    }
}
