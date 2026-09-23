import Glibc

/// Times the frames, for a person who wants to know what a change cost.
///
/// APUS_FRAME_LOG turns it on, and says how many frames go into a line:
/// `1` reports every 20 frames, and a number reports every that many. The
/// line holds the cost of a frame, the longest wait between two frames, the
/// rate, and the size of the screen. Without the variable it does nothing at
/// all, so a frame costs one comparison.
///
/// Two different things are in the line, and a smooth screen needs both:
///
/// - `average` and `longest` are the cost of the drawing: the time from the
///   start of a frame to its end. They say what the work costs.
/// - The rate, and `worst gap`, are against the clock: how often a frame
///   reached the screen, and the longest the screen went without a new one.
///   The waiting for a page flip, for input, or for an app is in these and
///   not in the cost. They say what a person sees.
///
/// The rate is therefore not 1 divided by the average. A compositor that
/// draws a frame in 6 ms, and then waits 20 ms for the next thing to do,
/// costs 6 ms a frame and shows 38 frames a second, not 163. An idle screen
/// draws nothing, so an idle time between two frames lowers the rate of the
/// line that holds it, and `worst gap` says how long that idle time was.
///
/// `drew` is the part of the screen that the frames drew, on average. The
/// compositor draws only what changed (see ScreenDamage), so a frame that
/// changed a line of text costs that line and not the screen. A frame that
/// is drawn whole, such as the first, costs the number of pixels, and a
/// window on a Mac with small pixels gives the guest four times the pixels
/// of the same window in points. `APUS_DAMAGE=full` draws every frame whole,
/// to compare the two.
struct FrameTimer {
    /// How many frames go into one line, or 0 for no line at all.
    private static let every: Int = {
        guard let text = getenv("APUS_FRAME_LOG").map({ String(cString: $0) }),
              !text.isEmpty else { return 0 }
        if let count = Int(text), count > 1 { return count }
        return text == "0" ? 0 : 20
    }()

    private let name: String
    private var start = 0.0
    private var total = 0.0
    private var longest = 0.0
    private var frames = 0
    /// When the first frame of this line started, for the rate.
    private var windowStart = 0.0
    /// When the frame before this one started, and the longest there has
    /// been between two starts.
    private var lastStart = 0.0
    private var longestGap = 0.0
    /// The pixels that the frames of this line drew.
    private var drawn = 0

    init(name: String) { self.name = name }

    mutating func began() {
        guard FrameTimer.every > 0 else { return }
        let now = FrameTimer.now()
        if frames == 0 {
            windowStart = now
        } else {
            longestGap = max(longestGap, now - lastStart)
        }
        lastStart = now
        start = now
    }

    /// Counts the pixels that a frame drew.
    mutating func drew(pixels: Int) {
        guard FrameTimer.every > 0 else { return }
        drawn += pixels
    }

    mutating func ended(width: Int, height: Int) {
        guard FrameTimer.every > 0 else { return }
        let end = FrameTimer.now()
        let taken = end - start
        total += taken
        longest = max(longest, taken)
        frames += 1
        guard frames >= FrameTimer.every else { return }
        let average: Double = total / Double(frames)
        // The frames of this line, over the time they took, from the start
        // of the first to the end of the last.
        let span: Double = end - windowStart
        let rate: Double = span > 0 ? Double(frames) / span : 0
        log("FRAME \(name) \(width)x\(height)"
            + " average \(FrameTimer.milliseconds(average))ms"
            + " longest \(FrameTimer.milliseconds(longest))ms"
            + " worst gap \(FrameTimer.milliseconds(longestGap))ms"
            + " (\(FrameTimer.count(rate)) frames a second)"
            + " drew \(FrameTimer.share(drawn, of: frames * width * height))%")
        drawn = 0
        total = 0
        longest = 0
        longestGap = 0
        frames = 0
    }

    /// Seconds as milliseconds, to one place after the point.
    private static func milliseconds(_ seconds: Double) -> Double {
        (seconds * 10_000).rounded() / 10
    }

    /// A rate as a whole number, and a slow one with a place after the
    /// point, because 0 says less than 4.6 does.
    private static func count(_ rate: Double) -> String {
        rate >= 10 ? "\(Int(rate.rounded()))" : "\((rate * 10).rounded() / 10)"
    }

    /// A part of a whole, in per cent, to one place after the point.
    private static func share(_ part: Int, of whole: Int) -> Double {
        whole > 0 ? (Double(part) / Double(whole) * 1000).rounded() / 10 : 0
    }

    private static func now() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
