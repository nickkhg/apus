import Foundation

/// Where the time of a frame goes on the Mac, for a person who wants to know
/// why a frame that the guest drew with the GPU costs what it costs.
///
/// APUS_VM_TIMING=N writes a line for each N fences. The line holds:
///
/// - `submit`: the time inside virglrenderer for one stream of commands.
///   That is the decode, MoltenVK, and the Metal encoding, on this thread.
/// - `fence`: the time from the moment the guest asked for a fence to the
///   moment this program saw that the work behind it was finished. The GPU
///   is in that number, and so is the wait for the poll that finds it.
/// - `poll`: how much of `fence` is the poll and not the work. The renderer
///   would ring an eventfd, and macOS has none, so this program asks again
///   and again. APUS_VM_POLL says how often, in microseconds.
///
/// A `fence` much larger than `submit`, with `poll` most of it, says that
/// the machine waits for the question and not for the GPU.
final class HostTiming: @unchecked Sendable {
    static let shared = HostTiming()

    /// How many fences go into one line, or 0 for no line at all.
    static let every: Int = {
        guard let text = ProcessInfo.processInfo.environment["APUS_VM_TIMING"],
              let count = Int(text), count > 0 else { return 0 }
        return count
    }()

    /// How often to ask the renderer which fences are finished.
    static let pollMicroseconds: Int = {
        guard let text = ProcessInfo.processInfo.environment["APUS_VM_POLL"],
              let value = Int(text), value > 0 else { return 1000 }
        return value
    }()

    private let lock = NSLock()
    private var submitSeconds = 0.0
    private var submits = 0
    private var fenceSeconds = 0.0
    private var longestFence = 0.0
    private var polls = 0
    private var fences = 0

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    static func addSubmit(_ seconds: Double) { shared.addSubmit(seconds) }
    static func addPoll() { shared.addPoll() }
    static func addFence(_ seconds: Double) { shared.addFence(seconds) }

    private func addSubmit(_ seconds: Double) {
        guard HostTiming.every > 0 else { return }
        lock.withLock { submitSeconds += seconds; submits += 1 }
    }

    /// One turn of the poll timer, whether or not it found anything.
    private func addPoll() {
        guard HostTiming.every > 0 else { return }
        lock.withLock { polls += 1 }
    }

    private func addFence(_ seconds: Double) {
        guard HostTiming.every > 0 else { return }
        let line: String? = lock.withLock {
            fenceSeconds += seconds
            longestFence = max(longestFence, seconds)
            fences += 1
            guard fences >= HostTiming.every else { return nil }
            func ms(_ total: Double, _ count: Int) -> Double {
                count == 0 ? 0 : (total / Double(count) * 10_000).rounded() / 10
            }
            let text = "HOST-TIMING submit \(ms(submitSeconds, submits))ms x\(submits)"
                + "  fence \(ms(fenceSeconds, fences))ms"
                + " longest \((longestFence * 10_000).rounded() / 10)ms x\(fences)"
                + "  poll every \(HostTiming.pollMicroseconds)us x\(polls)"
            submitSeconds = 0; submits = 0
            fenceSeconds = 0; longestFence = 0; polls = 0; fences = 0
            return text
        }
        if let line { log(line) }
    }
}
