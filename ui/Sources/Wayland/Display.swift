import Glibc

/// A Wayland server: the listening socket, the connected clients, and the
/// globals that clients can bind. It implements wl_display and wl_registry.
public final class Display {
    public enum Failure: Error, CustomStringConvertible {
        case noRuntimeDirectory
        case noFreeSocket
        case socket(String, Int32)

        public var description: String {
            switch self {
            case .noRuntimeDirectory: "XDG_RUNTIME_DIR is not set"
            case .noFreeSocket: "no free Wayland socket name (wayland-0 to wayland-31)"
            case .socket(let step, let error): "socket \(step): \(String(cString: strerror(error)))"
            }
        }
    }

    public let loop: EventLoop
    /// The socket name for WAYLAND_DISPLAY, for example "wayland-0".
    public let socketName: String
    /// Called for each new client, before it sends a request.
    public var clientConnected: (Client) -> Void = { _ in }

    private let socketPath: String
    private let lockPath: String
    private let socketFD: Int32
    private let lockFD: Int32
    private var socketWatch: EventLoop.Watch?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var globals: [Global] = []
    private var nextGlobalName: UInt32 = 1
    private var serial: UInt32 = 0
    private var needsFlush = false

    private struct Global {
        let name: UInt32
        let interface: String
        let version: UInt32
        let bind: (Client, UInt32, UInt32) -> Void   // client, id, version
    }

    /// Opens the first free socket $XDG_RUNTIME_DIR/wayland-N. A lock file
    /// next to it (wayland-N.lock) shows that a server uses the name, as
    /// libwayland does.
    public init(loop: EventLoop) throws(Failure) {
        self.loop = loop
        guard let runtime = getenv("XDG_RUNTIME_DIR").map({ String(cString: $0) }) else {
            throw .noRuntimeDirectory
        }
        for number in 0..<32 {
            let name = "wayland-\(number)"
            let path = "\(runtime)/\(name)"
            let lock = open("\(path).lock", O_CREAT | O_CLOEXEC | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
            guard lock >= 0 else { continue }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                close(lock)
                continue
            }
            // The lock is ours, so a socket file here is left from a server
            // that stopped.
            unlink(path)
            let socket = try Display.listen(on: path)
            (socketName, socketPath, lockPath, socketFD, lockFD) = (name, path, "\(path).lock", socket, lock)
            socketWatch = loop.watch(fd: socket) { [unowned self] in accept() }
            return
        }
        throw .noFreeSocket
    }

    deinit {
        // This display is going away, so a client must not reach back into
        // it to take itself out of a table that goes with it.
        for client in Array(clients.values) { client.disconnect(displayIsGoing: true) }
        clients.removeAll()
        socketWatch?.cancel()
        close(socketFD)
        unlink(socketPath)
        unlink(lockPath)
        close(lockFD)
    }

    private static func listen(on path: String) throws(Failure) -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue) | Int32(SOCK_NONBLOCK.rawValue), 0)
        guard fd >= 0 else { throw .socket("create", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw .socket("path too long", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw .socket("bind \(path)", error)
        }
        guard Glibc.listen(fd, 128) == 0 else {
            let error = errno
            close(fd)
            throw .socket("listen", error)
        }
        return fd
    }

    // MARK: - Globals

    /// Adds a global: an object that every client can bind with
    /// wl_registry.bind. `bind` gets the new resource.
    public func addGlobal<I: Interface>(_: I.Type, version: UInt32, bind: @escaping (Resource<I>) -> Void) {
        precondition(version <= I.version, "\(I.name) version \(version) is newer than the protocol file")
        globals.append(Global(name: nextGlobalName, interface: I.name, version: version) { client, id, version in
            bind(client.create(NewID<I>(id: id, version: version)))
        })
        nextGlobalName += 1
    }

    public func nextSerial() -> UInt32 {
        serial &+= 1
        return serial
    }

    // MARK: - Clients

    /// Sends queued events to all clients. Call this before the loop waits.
    public func flushClients() {
        guard needsFlush else { return }
        needsFlush = false
        for client in Array(clients.values) { client.flush() }
    }

    func scheduleFlush() { needsFlush = true }

    func remove(_ client: Client) {
        clients[ObjectIdentifier(client)] = nil
    }

    private func accept() {
        while true {
            let fd = Glibc.accept(socketFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                return   // EAGAIN: no more waiting connections
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let client = Client(display: self, fd: fd)
            clients[ObjectIdentifier(client)] = client
            let display = client.create(NewID<WlDisplay>(id: 1, version: 1))
            display.onRequest = { [unowned self, unowned client] request in
                switch request {
                case .sync(let callbackID):
                    let callback = client.create(callbackID)
                    callback.sendDone(callbackData: nextSerial())
                    callback.destroy()
                case .getRegistry(let registryID):
                    addRegistry(client.create(registryID))
                }
            }
            clientConnected(client)
        }
    }

    private func addRegistry(_ registry: Resource<WlRegistry>) {
        registry.onRequest = { [unowned self, unowned registry] request in
            switch request {
            case .bind(let name, let id):
                guard let global = globals.first(where: { $0.name == name }) else {
                    return registry.postError(code: DisplayErrorCode.invalidObject, "invalid global \(name)")
                }
                guard id.interface == global.interface else {
                    return registry.postError(code: DisplayErrorCode.invalidObject,
                                              "invalid interface for global \(name): have \(id.interface), wanted \(global.interface)")
                }
                guard id.version >= 1, id.version <= global.version else {
                    return registry.postError(code: DisplayErrorCode.invalidObject,
                                              "invalid version for global \(global.interface) (\(name)): have \(id.version), wanted 1 to \(global.version)")
                }
                if let client = registry.client { global.bind(client, id.id, id.version) }
            }
        }
        for global in globals {
            registry.sendGlobal(name: global.name, interface: global.interface, version: global.version)
        }
    }
}
