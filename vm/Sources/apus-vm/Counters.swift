import Foundation

/// What the machine is doing, for the Debug menu.
///
/// The device counts what the guest asks of it, and the console reader
/// reads what the compositor says about its own frames. Every part of this
/// is written from a thread that is not the main one, so a lock guards it.
final class Counters: @unchecked Sendable {
    /// One count, and the rate it is rising at.
    struct Rate {
        fileprivate var total = 0
        fileprivate var atLastRead = 0
        fileprivate var readAt = Date()
        /// Per second, over the time since the last read.
        private(set) var perSecond = 0.0

        fileprivate mutating func take() {
            let now = Date()
            let seconds = now.timeIntervalSince(readAt)
            guard seconds > 0.2 else { return }
            perSecond = Double(total - atLastRead) / seconds
            atLastRead = total
            readAt = now
        }
    }

    private let lock = NSLock()
    private var streams = Rate()
    private var fences = Rate()
    private var flushes = Rate()

    /// The last line the compositor wrote about its frames, and the one
    /// that says what draws them.
    private var frames: String?
    private var renderer: String?

    static let shared = Counters()

    func countStream() { lock.withLock { streams.total += 1 } }
    func countFence() { lock.withLock { fences.total += 1 } }
    func countFlush() { lock.withLock { flushes.total += 1 } }

    /// Reads a line of the guest console. Two of them are interesting.
    ///
    /// `FRAME gpu 1280x800 average 6.1ms longest 9.0ms worst gap 21.4ms (38 frames a second)`
    /// `GPU-RENDERER zink Vulkan 1.4(...) OpenGL ES 2.0 ... (offscreen)`
    func read(_ line: String) {
        guard let start = line.range(of: "FRAME ") ?? line.range(of: "GPU-RENDERER ") else {
            return
        }
        let text = String(line[start.lowerBound...])
        lock.withLock {
            if text.hasPrefix("FRAME ") {
                frames = String(text.dropFirst("FRAME ".count))
            } else {
                renderer = String(text.dropFirst("GPU-RENDERER ".count))
            }
        }
    }

    /// What to show now. Reading moves the rates on, so one reader only.
    struct Reading {
        let streams: Double
        let fences: Double
        let flushes: Double
        /// The line the compositor wrote, as it wrote it.
        let frames: String?
        let renderer: String?

        /// `gpu 1280x800 average 6.1ms longest 9.0ms worst gap 21.4ms (38 frames a second)`
        ///
        /// This one is measured against the clock: it is how often a frame
        /// reached the screen, and not 1 divided by the time one frame took
        /// to draw. See FrameTimer.
        var framesASecond: String? {
            guard let frames, let open = frames.lastIndex(of: "("),
                  let close = frames.lastIndex(of: ")"), open < close else { return nil }
            let inside = frames[frames.index(after: open)..<close]
            return inside.hasSuffix(" frames a second")
                ? String(inside.dropLast(" frames a second".count)) : String(inside)
        }

        /// How long the drawing of one frame took, on average.
        var frameTime: String? { word(after: "average ") }

        /// The longest the screen went without a new frame. A number much
        /// larger than the frame time is what a person sees as a stutter.
        var worstGap: String? { word(after: "worst gap ") }

        /// The word that comes after `phrase` in the line of the compositor.
        private func word(after phrase: String) -> String? {
            guard let frames, let found = frames.range(of: phrase) else { return nil }
            let rest = frames[found.upperBound...]
            guard let end = rest.firstIndex(of: " ") else { return String(rest) }
            return String(rest[..<end])
        }
    }

    func read() -> Reading {
        lock.withLock {
            streams.take()
            fences.take()
            flushes.take()
            return Reading(streams: streams.perSecond, fences: fences.perSecond,
                           flushes: flushes.perSecond, frames: frames, renderer: renderer)
        }
    }
}
