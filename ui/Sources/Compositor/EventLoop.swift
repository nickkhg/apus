import CWaylandServer
import Glibc

/// The compositor's single-threaded main loop: libwayland's event loop,
/// which also serves the Wayland clients. Every callback runs on this thread.
final class EventLoop {
    let loop: OpaquePointer
    private var sources: [Source] = []

    /// Keeps a Swift closure alive while libwayland holds a pointer to it.
    private final class Source {
        let action: () -> Void
        var handle: OpaquePointer?
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    init(loop: OpaquePointer) {
        self.loop = loop
    }

    deinit {
        for source in sources {
            if let handle = source.handle { wl_event_source_remove(handle) }
        }
    }

    /// Calls `action` whenever `fd` is readable.
    func watch(fd: Int32, _ action: @escaping () -> Void) {
        let source = Source(action)
        source.handle = wl_event_loop_add_fd(
            loop, fd, UInt32(WL_EVENT_READABLE),
            { _, _, data in
                Unmanaged<Source>.fromOpaque(data!).takeUnretainedValue().action()
                return 0
            },
            Unmanaged.passUnretained(source).toOpaque()
        )
        sources.append(source)
    }

    /// Calls `action` when the process receives `signal` (delivered through
    /// the loop, so it's safe to do anything in it).
    func onSignal(_ signal: Int32, _ action: @escaping () -> Void) {
        let source = Source(action)
        source.handle = wl_event_loop_add_signal(
            loop, signal,
            { _, data in
                Unmanaged<Source>.fromOpaque(data!).takeUnretainedValue().action()
                return 0
            },
            Unmanaged.passUnretained(source).toOpaque()
        )
        sources.append(source)
    }

    /// Waits for events and runs their callbacks once.
    func dispatch(timeout: Int32 = -1) {
        wl_event_loop_dispatch(loop, timeout)
    }
}

/// Prints a line and flushes, so output is visible even when stdout is a
/// pipe or file.
func log(_ message: String) {
    print(message)
    fflush(nil)
}

/// Logs only when MYDISTRO_DEBUG is set.
func debug(_ message: @autoclosure () -> String) {
    if getenv("MYDISTRO_DEBUG") != nil { log("compositor: \(message())") }
}

/// Milliseconds on the monotonic clock, as Wayland timestamps use.
func monotonicMilliseconds() -> UInt32 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt32(truncatingIfNeeded: Int(now.tv_sec) * 1000 + Int(now.tv_nsec) / 1_000_000)
}

/// Allocates a value that never moves or goes away. libwayland and libseat
/// keep pointers to handler tables, so those live here.
func permanent<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    pointer.initialize(to: value)
    return pointer
}
