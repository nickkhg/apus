import CLinux
import Glibc

/// A single-threaded event loop on epoll. It watches file descriptors and
/// signals, and runs every callback on the thread that calls `dispatch`.
public final class EventLoop {
    public enum Failure: Error { case epoll(Int32), signal(Int32) }

    /// What happened on a watched file descriptor.
    public struct Events: Sendable {
        public let readable: Bool
        public let writable: Bool
        /// The other end closed, or an error occurred.
        public let hangup: Bool
    }

    /// A watched file descriptor. It stays watched until `cancel()`.
    public final class Watch {
        public let fd: Int32
        fileprivate let token: UInt64
        fileprivate weak var loop: EventLoop?
        fileprivate let action: (Events) -> Void
        private var wantsWritable = false

        fileprivate init(fd: Int32, token: UInt64, loop: EventLoop, action: @escaping (Events) -> Void) {
            (self.fd, self.token, self.loop, self.action) = (fd, token, loop, action)
        }

        /// Also report when the file descriptor can be written (for output
        /// that did not fit into the socket buffer).
        public func setWantsWritable(_ wants: Bool) {
            guard wants != wantsWritable, let loop else { return }
            wantsWritable = wants
            loop.control(EPOLL_CTL_MOD, self, writable: wants)
        }

        /// Stops watching. The loop does not close the file descriptor.
        public func cancel() {
            guard let loop else { return }
            loop.control(EPOLL_CTL_DEL, self, writable: false)
            loop.watches[token] = nil
            self.loop = nil
        }
    }

    private let epollFD: Int32
    private var watches: [UInt64: Watch] = [:]
    private var nextToken: UInt64 = 1

    private var signalFD: Int32 = -1
    private var signalMask = sigset_t()
    private var signalHandlers: [Int32: () -> Void] = [:]
    private var signalWatch: Watch?

    public init() throws(Failure) {
        epollFD = epoll_create1(Int32(EPOLL_CLOEXEC))
        guard epollFD >= 0 else { throw .epoll(errno) }
        sigemptyset(&signalMask)
    }

    deinit {
        if signalFD >= 0 {
            pthread_sigmask(SIG_UNBLOCK, &signalMask, nil)
            close(signalFD)
        }
        close(epollFD)
    }

    /// Calls `action` when `fd` is readable, is closed, or has an error.
    @discardableResult
    public func watch(fd: Int32, _ action: @escaping (Events) -> Void) -> Watch {
        let watch = Watch(fd: fd, token: nextToken, loop: self, action: action)
        nextToken += 1
        watches[watch.token] = watch
        control(EPOLL_CTL_ADD, watch, writable: false)
        return watch
    }

    @discardableResult
    public func watch(fd: Int32, _ action: @escaping () -> Void) -> Watch {
        watch(fd: fd) { _ in action() }
    }

    private func control(_ operation: Int32, _ watch: Watch, writable: Bool) {
        var event = epoll_event()
        event.events = EPOLLIN.rawValue | EPOLLRDHUP.rawValue | (writable ? EPOLLOUT.rawValue : 0)
        event.data.u64 = watch.token
        if epoll_ctl(epollFD, operation, watch.fd, &event) != 0, operation != EPOLL_CTL_DEL {
            print("event loop: epoll_ctl(\(operation), fd \(watch.fd)) failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Calls `action` from the loop when the process receives `signal`. The
    /// signal is blocked for normal delivery (signalfd), so the action can do
    /// anything.
    public func onSignal(_ signal: Int32, _ action: @escaping () -> Void) throws(Failure) {
        signalHandlers[signal] = action
        sigaddset(&signalMask, signal)
        guard pthread_sigmask(SIG_BLOCK, &signalMask, nil) == 0 else { throw .signal(errno) }
        let fd = signalfd(signalFD, &signalMask, Int32(SFD_CLOEXEC | SFD_NONBLOCK))
        guard fd >= 0 else { throw .signal(errno) }
        if signalFD < 0 {
            signalFD = fd
            signalWatch = watch(fd: fd) { [unowned self] in readSignals() }
        }
    }

    private func readSignals() {
        var info = signalfd_siginfo()
        while read(signalFD, &info, MemoryLayout<signalfd_siginfo>.size) == MemoryLayout<signalfd_siginfo>.size {
            signalHandlers[Int32(info.ssi_signo)]?()
        }
    }

    /// Calls `action` every `milliseconds` from the loop, for a clock or
    /// another repeating job. The timer runs until the loop goes away.
    @discardableResult
    public func onTimer(milliseconds: Int, _ action: @escaping () -> Void) throws(Failure) -> Watch {
        let fd = timerfd_create(CLOCK_MONOTONIC, Int32(TFD_CLOEXEC | TFD_NONBLOCK))
        guard fd >= 0 else { throw .signal(errno) }
        let interval = timespec(tv_sec: milliseconds / 1000,
                                tv_nsec: (milliseconds % 1000) * 1_000_000)
        var timer = itimerspec(it_interval: interval, it_value: interval)
        guard timerfd_settime(fd, 0, &timer, nil) == 0 else {
            let error = errno
            close(fd)
            throw .signal(error)
        }
        return watch(fd: fd) {
            // Reading clears the count of ticks that went by.
            var ticks: UInt64 = 0
            _ = read(fd, &ticks, MemoryLayout<UInt64>.size)
            action()
        }
    }

    /// Waits up to `timeout` milliseconds (-1: no limit) for events, and runs
    /// their callbacks.
    public func dispatch(timeout: Int32 = -1) {
        var events = [epoll_event](repeating: epoll_event(), count: 32)
        let count = epoll_wait(epollFD, &events, Int32(events.count), timeout)
        guard count > 0 else { return }
        for event in events.prefix(Int(count)) {
            // A callback earlier in this batch can cancel a watch.
            guard let watch = watches[event.data.u64] else { continue }
            let flags = event.events
            watch.action(Events(
                readable: flags & EPOLLIN.rawValue != 0,
                writable: flags & EPOLLOUT.rawValue != 0,
                hangup: flags & (EPOLLHUP.rawValue | EPOLLERR.rawValue | EPOLLRDHUP.rawValue) != 0
            ))
        }
    }
}
