import Glibc

/// Times the frames, for a person who wants to know what a change cost.
///
/// MYDISTRO_FRAME_LOG turns it on, and says how many frames go into a line:
/// `1` reports every 20 frames, and a number reports every that many. The
/// line holds the average, the longest, and the size of the screen. Without
/// the variable it does nothing at all, so a frame costs one comparison.
///
/// The compositor draws the whole screen for each frame, so the cost rises
/// with the number of pixels. A window on a Mac with small pixels gives the
/// guest four times the pixels of the same window in points.
struct FrameTimer {
    /// How many frames go into one line, or 0 for no line at all.
    private static let every: Int = {
        guard let text = getenv("MYDISTRO_FRAME_LOG").map({ String(cString: $0) }),
              !text.isEmpty else { return 0 }
        if let count = Int(text), count > 1 { return count }
        return text == "0" ? 0 : 20
    }()

    private let name: String
    private var start = 0.0
    private var total = 0.0
    private var longest = 0.0
    private var frames = 0

    init(name: String) { self.name = name }

    mutating func began() {
        guard FrameTimer.every > 0 else { return }
        start = FrameTimer.now()
    }

    mutating func ended(width: Int, height: Int) {
        guard FrameTimer.every > 0 else { return }
        let taken = FrameTimer.now() - start
        total += taken
        longest = max(longest, taken)
        frames += 1
        guard frames >= FrameTimer.every else { return }
        let average: Double = total / Double(frames)
        let averageMilliseconds: Double = average * 1000
        let longestMilliseconds: Double = longest * 1000
        let rate: Double = average > 0 ? 1 / average : 0
        log("FRAME \(name) \(width)x\(height)"
            + " average \(round(averageMilliseconds * 10) / 10)ms"
            + " longest \(round(longestMilliseconds * 10) / 10)ms"
            + " (\(Int(rate.rounded())) frames a second)")
        total = 0
        longest = 0
        frames = 0
    }

    private static func now() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
