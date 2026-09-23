import Glibc

/// Prints a line and flushes it, so that the message is in the log of the
/// system even when the terminal ends at once.
func report(_ message: String) {
    print("apus-terminal: \(message)")
    fflush(nil)
}

/// Allocates a value that never moves. libwayland keeps the pointers to the
/// listener tables, so they live here.
func permanent<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    pointer.initialize(to: value)
    return pointer
}

/// Seconds since the machine started. The repeat of a held key reads it.
func monotonic() -> Double {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000
}
