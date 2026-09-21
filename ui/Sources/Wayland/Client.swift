import Glibc

/// One connected app: its socket, its protocol objects, and the queues of
/// bytes and file descriptors in each direction.
public final class Client {
    public unowned let display: Display
    /// The process on the other end of the socket.
    public let pid: pid_t
    public let uid: uid_t

    private let fd: Int32
    private var watch: EventLoop.Watch?
    private var objects: [UInt32: AnyResource] = [:]
    private var input: [UInt8] = []
    private var receivedFDs: [Int32] = []
    private var output: [UInt8] = []
    private var outputFDs: [Int32] = []
    private var nextServerID: UInt32 = Client.firstServerID
    /// Set by a protocol error: the error is sent, then the client is closed.
    private var isClosing = false
    public private(set) var isDisconnected = false

    /// IDs from here up are for objects that the server makes.
    static let firstServerID: UInt32 = 0xFF00_0000
    /// A client that does not read its events is disconnected at this size.
    private static let maxOutput = 4 << 20
    /// The kernel accepts up to 253 descriptors in one message. libwayland
    /// sends at most 28, and so do we.
    private static let maxFDsPerMessage = 28

    init(display: Display, fd: Int32) {
        self.display = display
        self.fd = fd
        var credentials = PeerCredentials()
        var length = socklen_t(MemoryLayout<PeerCredentials>.size)
        getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length)
        pid = credentials.pid
        uid = credentials.uid
        watch = display.loop.watch(fd: fd) { [unowned self] events in handle(events) }
    }

    deinit {
        precondition(isDisconnected, "a client must be disconnected before it is released")
    }

    // MARK: - Objects

    func object(_ id: UInt32) -> AnyResource? { objects[id] }

    func checkNewID(_ id: UInt32) throws(ProtocolError) {
        guard id != 0, id < Client.firstServerID, objects[id] == nil else {
            throw ProtocolError(objectID: 1, code: DisplayErrorCode.invalidObject, message: "invalid new id \(id)")
        }
    }

    func create<I: Interface>(_ newID: NewID<I>) -> Resource<I> {
        let resource = Resource<I>(client: self, id: newID.id, version: newID.version)
        objects[newID.id] = resource
        return resource
    }

    /// Makes an object with an ID from the server's range, for an event that
    /// gives the client a new object.
    public func createServerObject<I: Interface>(_: I.Type, version: UInt32) -> Resource<I> {
        let resource = Resource<I>(client: self, id: nextServerID, version: version)
        objects[nextServerID] = resource
        nextServerID += 1
        return resource
    }

    func destroy(_ resource: AnyResource) {
        guard objects[resource.id] === resource else { return }
        objects[resource.id] = nil
        // The client can use the ID again after delete_id.
        if resource.id < Client.firstServerID, let display = objects[1] as? Resource<WlDisplay> {
            display.sendDeleteId(id: resource.id)
        }
        resource.markDestroyed()
    }

    // MARK: - Errors and disconnection

    /// Sends a protocol error. The client is disconnected after the error
    /// is sent.
    public func post(_ error: ProtocolError) {
        guard !isClosing, !isDisconnected else { return }
        print("wayland: client \(pid): protocol error: \(error)")
        // Written directly, because the object in the error can be unknown.
        var event = MessageWriter(objectID: 1, opcode: 0)   // wl_display.error
        event.uint(error.objectID)
        event.uint(error.code)
        event.string(error.message)
        queue(event)
        isClosing = true
        display.scheduleFlush()
    }

    /// Closes the connection. Destroys every object of the client, newest
    /// first, and runs their destroy handlers.
    /// Closes the connection and lets every object of this client go.
    ///
    /// `displayIsGoing` is true only while the display tears itself down.
    /// A client must not reach back into the display then, and the handlers
    /// that its objects registered must not run: both belong to things that
    /// are already on their way out, and a client holds them without owning
    /// them, because they outlive a client in every other case.
    public func disconnect(displayIsGoing: Bool = false) {
        guard !isDisconnected else { return }
        isDisconnected = true
        watch?.cancel()
        watch = nil
        close(fd)
        (receivedFDs + outputFDs).forEach { close($0) }
        receivedFDs.removeAll()
        outputFDs.removeAll()
        let resources = objects.values.sorted { $0.id > $1.id }
        objects.removeAll()
        for resource in resources { resource.markDestroyed(tellingHandlers: !displayIsGoing) }
        if !displayIsGoing { display.remove(self) }
    }

    // MARK: - Input

    func takeReceivedFD() -> Int32? {
        receivedFDs.isEmpty ? nil : receivedFDs.removeFirst()
    }

    private func handle(_ events: EventLoop.Events) {
        if events.writable { flush() }
        if events.readable || events.hangup {
            let open = receive()
            process()
            if !open { disconnect() }
        }
    }

    /// Reads all available bytes and file descriptors. Returns false when
    /// the connection is closed.
    private func receive() -> Bool {
        let fdSpace = Client.controlSpace(fds: Client.maxFDsPerMessage)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var control = [UInt8](repeating: 0, count: fdSpace)
        while !isDisconnected {
            let count = buffer.withUnsafeMutableBytes { data in
                control.withUnsafeMutableBytes { controlBytes in
                    var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var header = msghdr()
                        header.msg_iov = vectorPointer
                        header.msg_iovlen = 1
                        header.msg_control = controlBytes.baseAddress
                        header.msg_controllen = controlBytes.count
                        let count = recvmsg(fd, &header, Int32(MSG_DONTWAIT) | Int32(MSG_CMSG_CLOEXEC))
                        if count >= 0 { receivedFDs += Client.fds(in: header) }
                        return count
                    }
                }
            }
            if count > 0 {
                input += buffer.prefix(count)
            } else if count == 0 {
                return false
            } else if errno == EINTR {
                continue
            } else {
                return errno == EAGAIN
            }
        }
        return false
    }

    /// Dispatches every complete message in the input.
    private func process() {
        var offset = 0
        defer { input.removeFirst(min(offset, input.count)) }
        while input.count - offset >= 8, !isClosing, !isDisconnected {
            let (objectID, sizeAndOpcode) = input.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self),
                 $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            }
            let size = Int(sizeAndOpcode >> 16)
            let opcode = UInt16(sizeAndOpcode & 0xFFFF)
            guard size >= 8, size % 4 == 0 else {
                post(ProtocolError(objectID: 1, code: DisplayErrorCode.invalidMethod, message: "bad message size \(size)"))
                return
            }
            guard input.count - offset >= size else { break }
            let arguments = Array(input[offset + 8..<offset + size])
            offset += size

            guard let object = objects[objectID] else {
                post(ProtocolError(objectID: 1, code: DisplayErrorCode.invalidObject,
                                   message: "invalid object \(objectID)"))
                return
            }
            var message = MessageReader(client: self, objectID: objectID, bytes: arguments)
            do {
                try object.dispatch(opcode: opcode, message: &message)
            } catch {
                post(error)
            }
        }
    }

    // MARK: - Output

    func queue(_ event: MessageWriter) {
        guard !isDisconnected else { return }
        let (bytes, fds) = event.finish()
        output += bytes
        outputFDs += fds
        display.scheduleFlush()
        if output.count > Client.maxOutput {
            print("wayland: client \(pid) does not read its events; disconnecting it")
            disconnect()
        }
    }

    /// Sends as much of the output as the socket accepts. When the socket is
    /// full, the loop reports when it can be written again.
    func flush() {
        while !output.isEmpty, !isDisconnected {
            let fds = Array(outputFDs.prefix(Client.maxFDsPerMessage))
            var control = [UInt8](repeating: 0, count: fds.isEmpty ? 0 : Client.controlSpace(fds: fds.count))
            if !fds.isEmpty { Client.write(fds: fds, into: &control) }
            let sent = output.withUnsafeMutableBytes { data in
                control.withUnsafeMutableBytes { controlBytes in
                    var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var header = msghdr()
                        header.msg_iov = vectorPointer
                        header.msg_iovlen = 1
                        if !fds.isEmpty {
                            header.msg_control = controlBytes.baseAddress
                            header.msg_controllen = controlBytes.count
                        }
                        return sendmsg(fd, &header, Int32(MSG_NOSIGNAL) | Int32(MSG_DONTWAIT))
                    }
                }
            }
            if sent < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    watch?.setWantsWritable(true)
                    return
                }
                disconnect()
                return
            }
            fds.forEach { close($0) }
            outputFDs.removeFirst(fds.count)
            output.removeFirst(sent)
        }
        watch?.setWantsWritable(false)
        if isClosing { disconnect() }
    }

    /// struct ucred (SO_PEERCRED). glibc declares it only with _GNU_SOURCE.
    private struct PeerCredentials {
        var pid: pid_t = 0
        var uid: uid_t = 0
        var gid: gid_t = 0
    }

    // MARK: - SCM_RIGHTS (the CMSG_* macros, which Swift cannot import)

    private static let headerSize = align(MemoryLayout<cmsghdr>.size)

    private static func align(_ length: Int) -> Int {
        let unit = MemoryLayout<Int>.size
        return (length + unit - 1) & ~(unit - 1)
    }

    private static func controlSpace(fds: Int) -> Int {
        headerSize + align(fds * MemoryLayout<Int32>.size)
    }

    private static func write(fds: [Int32], into control: inout [UInt8]) {
        control.withUnsafeMutableBytes { bytes in
            var header = cmsghdr()
            header.cmsg_len = headerSize + fds.count * MemoryLayout<Int32>.size
            header.cmsg_level = SOL_SOCKET
            header.cmsg_type = Int32(SCM_RIGHTS)
            bytes.storeBytes(of: header, as: cmsghdr.self)
            for (index, fd) in fds.enumerated() {
                bytes.storeBytes(of: fd, toByteOffset: headerSize + index * 4, as: Int32.self)
            }
        }
    }

    private static func fds(in message: msghdr) -> [Int32] {
        guard let control = message.msg_control else { return [] }
        let bytes = UnsafeRawBufferPointer(start: control, count: message.msg_controllen)
        var fds: [Int32] = []
        var offset = 0
        while offset + headerSize <= bytes.count {
            let header = bytes.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            guard header.cmsg_len >= headerSize, offset + header.cmsg_len <= bytes.count else { break }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == Int32(SCM_RIGHTS) {
                let count = (header.cmsg_len - headerSize) / MemoryLayout<Int32>.size
                for index in 0..<count {
                    fds.append(bytes.loadUnaligned(fromByteOffset: offset + headerSize + index * 4, as: Int32.self))
                }
            }
            offset += align(header.cmsg_len)
        }
        return fds
    }
}
