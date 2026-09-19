import Glibc

/// wl_shm: buffers in shared memory. An app makes a pool from a memory file
/// descriptor, and buffers at offsets in the pool.
public final class Shm {
    /// The pixel formats that the server reads. Every server must support
    /// these two.
    public static let formats: [WlShm.Format] = [.argb8888, .xrgb8888]

    public init(display: Display) {
        display.addGlobal(WlShm.self, version: 2) { shm in
            for format in Shm.formats { shm.sendFormat(format: format.rawValue) }
            shm.onRequest = { [unowned shm] request in
                switch request {
                case .createPool(let id, let fd, let size):
                    Shm.createPool(for: shm, id: id, fd: fd, size: size)
                case .release:
                    break
                }
            }
        }
        ShmPool.installBusErrorHandler()
    }

    private static func createPool(for shm: Resource<WlShm>, id: NewID<WlShmPool>, fd: Int32, size: Int32) {
        let resource = shm.create(id)
        guard size > 0 else {
            close(fd)
            return shm.postError(code: WlShm.ErrorCode.invalidStride.rawValue, "invalid pool size \(size)")
        }
        guard let pool = ShmPool(fd: fd, size: Int(size)) else {
            let error = errno
            close(fd)
            return shm.postError(code: WlShm.ErrorCode.invalidFd.rawValue,
                                 "cannot map the pool: \(String(cString: strerror(error)))")
        }
        resource.data = pool
        resource.onRequest = { [unowned resource] request in
            switch request {
            case .createBuffer(let id, let offset, let width, let height, let stride, let format):
                let buffer = resource.create(id)
                guard Shm.formats.contains(where: { $0.rawValue == format }) else {
                    return resource.postError(code: WlShm.ErrorCode.invalidFormat.rawValue, "invalid format \(format)")
                }
                let (offset, width, height, stride) = (Int(offset), Int(width), Int(height), Int(stride))
                guard offset >= 0, width > 0, height > 0, stride >= width * 4,
                      offset + stride * height <= pool.size else {
                    return resource.postError(code: WlShm.ErrorCode.invalidStride.rawValue,
                                              "invalid buffer: offset \(offset), \(width)x\(height), stride \(stride)")
                }
                buffer.data = ShmBuffer(pool: pool, offset: offset, width: width, height: height,
                                        stride: stride, format: format)
            case .resize(let size):
                guard Int(size) >= pool.size else {
                    return resource.postError(code: WlShm.ErrorCode.invalidStride.rawValue, "pools cannot shrink")
                }
                if !pool.resize(to: Int(size)) {
                    resource.postError(code: WlShm.ErrorCode.invalidFd.rawValue, "cannot map the pool again")
                }
            case .destroy:
                break   // buffers keep the pool
            }
        }
    }
}

/// The memory of one wl_shm_pool, mapped read-only.
public final class ShmPool {
    private let fd: Int32
    private(set) var memory: UnsafeMutableRawPointer
    public private(set) var size: Int

    init?(fd: Int32, size: Int) {
        guard let memory = ShmPool.map(fd: fd, size: size) else { return nil }
        (self.fd, self.memory, self.size) = (fd, memory, size)
    }

    deinit {
        munmap(memory, size)
        close(fd)
    }

    private static func map(fd: Int32, size: Int) -> UnsafeMutableRawPointer? {
        let memory = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
        return memory == MAP_FAILED ? nil : memory
    }

    /// Maps the pool again at a larger size. (mremap is variadic in C, so
    /// Swift cannot call it.)
    func resize(to newSize: Int) -> Bool {
        guard let newMemory = ShmPool.map(fd: fd, size: newSize) else { return false }
        munmap(memory, size)
        (memory, size) = (newMemory, newSize)
        return true
    }

    // MARK: - Protection against a client that makes its file smaller

    // If the client truncates the file, reading the mapping raises SIGBUS.
    // During a read, the handler maps anonymous memory over the pool, so the
    // read gets zeros and the compositor does not stop. This is what
    // libwayland does (wl_shm_buffer_begin_access).
    nonisolated(unsafe) fileprivate static var accessStart: UInt = 0
    nonisolated(unsafe) fileprivate static var accessSize = 0
    nonisolated(unsafe) fileprivate static var accessFaulted = false

    fileprivate static func installBusErrorHandler() {
        var action = sigaction()
        action.__sigaction_handler.sa_sigaction = { signal, info, _ in
            let address = UInt(bitPattern: info?.pointee._sifields._sigfault.si_addr)
            let start = ShmPool.accessStart
            if start != 0, address >= start, address < start + UInt(ShmPool.accessSize),
               mmap(UnsafeMutableRawPointer(bitPattern: start), ShmPool.accessSize, PROT_READ,
                    MAP_PRIVATE | MAP_FIXED | MAP_ANONYMOUS, -1, 0) != MAP_FAILED {
                ShmPool.accessFaulted = true
                return
            }
            // Not a pool read: stop the process, as without the handler.
            Glibc.signal(signal, SIG_DFL)
            raise(signal)
        }
        action.sa_flags = SA_SIGINFO | Int32(SA_NODEFER)
        sigaction(SIGBUS, &action, nil)
    }

    /// Runs `body` with the pool memory. Returns false if the client made
    /// its file smaller during the read (the memory then reads as zeros).
    fileprivate func access(_ body: (UnsafeRawPointer) -> Void) -> Bool {
        ShmPool.accessStart = UInt(bitPattern: memory)
        ShmPool.accessSize = size
        ShmPool.accessFaulted = false
        body(memory)
        ShmPool.accessStart = 0
        return !ShmPool.accessFaulted
    }
}

/// A wl_buffer in a shared-memory pool. It is the `data` of the buffer's
/// resource.
public final class ShmBuffer {
    public let pool: ShmPool
    public let offset: Int
    public let width: Int
    public let height: Int
    public let stride: Int
    /// A wl_shm.format value.
    public let format: UInt32

    init(pool: ShmPool, offset: Int, width: Int, height: Int, stride: Int, format: UInt32) {
        (self.pool, self.offset, self.width, self.height, self.stride, self.format) =
            (pool, offset, width, height, stride, format)
    }

    public var hasAlpha: Bool { format == WlShm.Format.argb8888.rawValue }

    /// Copies the pixels (32 bits each) into an array of width × height.
    /// Returns nil if the client damaged the pool during the copy.
    public func copyPixels() -> [UInt32]? {
        var pixels = [UInt32](repeating: 0, count: width * height)
        let intact = pool.access { memory in
            pixels.withUnsafeMutableBufferPointer { destination in
                for row in 0..<height {
                    let source = (memory + offset + row * stride).assumingMemoryBound(to: UInt32.self)
                    (destination.baseAddress! + row * width).update(from: source, count: width)
                }
            }
        }
        return intact ? pixels : nil
    }
}
