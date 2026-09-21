import Glibc

/// Prints a line and flushes, so output is visible even when stdout is a
/// pipe or file.
func log(_ message: String) {
    print(message)
    fflush(nil)
}

/// Logs only when APUS_DEBUG is set.
func debug(_ message: @autoclosure () -> String) {
    if getenv("APUS_DEBUG") != nil { log("compositor: \(message())") }
}

/// Milliseconds on the monotonic clock, as Wayland timestamps use.
func monotonicMilliseconds() -> UInt32 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt32(truncatingIfNeeded: Int(now.tv_sec) * 1000 + Int(now.tv_nsec) / 1_000_000)
}

/// Allocates a value that never moves or goes away. libseat and libinput
/// keep pointers to handler tables, so those live here.
func permanent<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    pointer.initialize(to: value)
    return pointer
}
