import AppKit

/// The numbers, drawn over the screen of the guest.
///
/// It sits above every other view of the window and takes no events, so a
/// click goes through it to the guest. The Debug menu says what it shows.
@MainActor
final class Overlay: NSView {
    /// How many frames a second reach the screen, how long the drawing of
    /// one takes, and the longest the screen went without a new one.
    var showsFrames = true { didSet { refresh() } }
    /// What the guest asks of the virtio-gpu device that this tool makes.
    var showsDevice = false { didSet { refresh() } }

    private var timer: Timer?
    private var lines: [String] = []

    private static let inset = CGSize(width: 10, height: 6)
    private static let margin = 12.0
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The window lives as long as the tool, so the timer goes when the
    /// view leaves it.
    override func viewDidMoveToWindow() {
        if window == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Events belong to the views below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func refresh() {
        let reading = Counters.shared.read()
        var lines: [String] = []

        if showsFrames {
            let rate = reading.framesASecond.map { "\($0) fps" }
            let time = reading.frameTime.map { "\($0) to draw" }
            // The number that a stutter is in: the frames a second can stay
            // high while one gap of 150 ms holds the screen still.
            let gap = reading.worstGap.map { "worst gap \($0)" }
            let line = [rate, time, gap].compactMap { $0 }.joined(separator: "   ")
            lines.append(line.isEmpty ? "no frame times yet" : line)
        }
        if showsDevice {
            lines.append(String(format: "%@ streams   %@ fences   %@ flushes",
                                Overlay.number(reading.streams),
                                Overlay.number(reading.fences),
                                Overlay.number(reading.flushes)))
            if let renderer = reading.renderer { lines.append(renderer) }
        }

        guard lines != self.lines else { return }
        self.lines = lines
        isHidden = lines.isEmpty
        place()
        needsDisplay = true
    }

    private static func number(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    /// The top left of the window, below the title bar.
    private func place() {
        guard let parent = superview else { return }
        let size = textSize()
        let box = NSSize(width: size.width + Overlay.inset.width * 2,
                         height: size.height + Overlay.inset.height * 2)
        frame = NSRect(x: Overlay.margin,
                       y: parent.bounds.height - box.height - Overlay.margin,
                       width: box.width, height: box.height)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Overlay.font, .foregroundColor: NSColor.white]
    }

    private func textSize() -> NSSize {
        var width = 0.0
        var height = 0.0
        for line in lines {
            let size = (line as NSString).size(withAttributes: attributes)
            width = max(width, size.width)
            height += size.height
        }
        return NSSize(width: width, height: height)
    }

    override func draw(_ dirty: NSRect) {
        guard !lines.isEmpty else { return }
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let height = (lines.first as NSString?)?.size(withAttributes: attributes).height ?? 0
        var y = bounds.height - Overlay.inset.height - height
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: Overlay.inset.width, y: y),
                                    withAttributes: attributes)
            y -= height
        }
    }

    /// The window changed size, so the box moves with its corner.
    override func viewDidMoveToSuperview() { place() }
}
