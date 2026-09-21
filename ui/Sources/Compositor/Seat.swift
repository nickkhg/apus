import CSeat
import Glibc

/// Access to the seat's devices (screen, keyboard, mouse) through libseat.
///
/// libseat picks a backend: logind or seatd for a normal user session, or
/// `LIBSEAT_BACKEND=noop` to open devices directly as root (used by the
/// automated tests, which run on the serial console with no seat).
final class Seat {
    enum Failure: Error, CustomStringConvertible {
        case open, dispatch, device(String, Int32)
        var description: String {
            switch self {
            case .open: "libseat can't open a seat (try LIBSEAT_BACKEND=noop as root)"
            case .dispatch: "libseat dispatch failed"
            case .device(let path, let err): "libseat can't open \(path): \(String(cString: strerror(err)))"
            }
        }
    }

    private(set) var handle: OpaquePointer?
    private(set) var isActive = false
    /// libseat device IDs, by file descriptor.
    private var devices: [Int32: Int32] = [:]

    nonisolated(unsafe) private static let listener = permanent(libseat_seat_listener(
        enable_seat: { _, data in
            Unmanaged<Seat>.fromOpaque(data!).takeUnretainedValue().isActive = true
        },
        disable_seat: { seat, data in
            // Another session takes the devices (e.g. a VT switch). Accept.
            Unmanaged<Seat>.fromOpaque(data!).takeUnretainedValue().isActive = false
            libseat_disable_seat(seat)
        }
    ))

    init() throws(Failure) {
        if getenv("APUS_DEBUG") != nil { libseat_set_log_level(LIBSEAT_LOG_LEVEL_DEBUG) }
        handle = libseat_open_seat(Seat.listener, Unmanaged.passUnretained(self).toOpaque())
        guard let handle else { throw .open }
        // Devices can be opened once the seat is enabled. Dispatch without
        // blocking (the noop backend enables the seat inside a dispatch call
        // and would then block forever), and wait on the fd ourselves.
        while true {
            guard libseat_dispatch(handle, 0) >= 0 else { throw .dispatch }
            if isActive { break }
            var pending = pollfd(fd: libseat_get_fd(handle), events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, -1) >= 0 || errno == EINTR else { throw .dispatch }
        }
    }

    deinit {
        for id in devices.values { libseat_close_device(handle, id) }
        if let handle { libseat_close_seat(handle) }
    }

    var name: String { String(cString: libseat_seat_name(handle)) }
    var fd: Int32 { libseat_get_fd(handle) }

    func dispatch() {
        _ = libseat_dispatch(handle, 0)
    }

    func openDevice(_ path: String) throws(Failure) -> Int32 {
        var fd: Int32 = -1
        let id = libseat_open_device(handle, path, &fd)
        guard id >= 0 else { throw .device(path, errno) }
        devices[fd] = id
        return fd
    }

    func closeDevice(_ fd: Int32) {
        guard let id = devices.removeValue(forKey: fd) else { return }
        libseat_close_device(handle, id)
    }
}
