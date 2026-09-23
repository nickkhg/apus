// A key that is held down repeats.
//
// Wayland leaves the repeat to the app. The compositor sends one press and
// one release, and `wl_keyboard.repeat_info` says how a held key repeats: it
// waits `delay` milliseconds, then goes `rate` times a second. A rate of zero
// means no repeat.
//
// This is the clock of it, and nothing else: it knows no Wayland and no
// keymap, so the Mac tests it. The app says which keys go down and up, and
// whether the keymap lets a key repeat (a modifier does not). The app's loop
// asks how long it can wait, and asks after the wait whether the held key is
// due again. The times are in seconds, on a clock of the app's choice.

/// The key that is held, and when it goes again.
public struct KeyRepeat: Equatable, Sendable {
    /// Repeats a second. Zero means none.
    public private(set) var rate = 0
    /// Milliseconds from the press to the first repeat.
    public private(set) var delay = 0
    /// The key that repeats, as the compositor numbers it, if one does.
    public private(set) var key: UInt32?
    /// When the key goes next.
    private var next = 0.0

    /// Until the compositor says how, no key repeats.
    public init() {}

    public init(rate: Int32, delay: Int32) {
        set(rate: rate, delay: delay)
    }

    /// What `wl_keyboard.repeat_info` says. A key that is repeating stops if
    /// the rate is now zero, and keeps its time otherwise.
    public mutating func set(rate: Int32, delay: Int32) {
        self.rate = max(0, Int(rate))
        self.delay = max(0, Int(delay))
        if self.rate == 0 { stop() }
    }

    /// A key went down. Another key that was repeating stops: a person who
    /// presses a second key means that one. `repeats` is what the keymap
    /// says of the key.
    public mutating func pressed(_ key: UInt32, repeats: Bool, at now: Double) {
        guard repeats, rate > 0 else {
            stop()
            return
        }
        self.key = key
        next = now + Double(delay) / 1000
    }

    /// A key went up. Only the key that repeats stops the repeat.
    public mutating func released(_ key: UInt32) {
        if self.key == key { stop() }
    }

    /// Stops the repeat: the window lost the keys, for example.
    public mutating func stop() {
        key = nil
    }

    /// How long the loop can wait before the key is due, in milliseconds as
    /// `poll` takes them, or nil when no key repeats. It rounds up, so that
    /// a wait never ends just before the key is due.
    public func wait(at now: Double) -> Int32? {
        guard key != nil else { return nil }
        let milliseconds = ((next - now) * 1000).rounded(.up)
        return Int32(min(max(0, milliseconds), Double(Int32.max)))
    }

    /// The key, if it is due to go again, and the time of the next one.
    ///
    /// It gives one repeat for each call. A loop that was late does not get
    /// the ones it missed in one burst: the next one is an interval from now.
    public mutating func due(at now: Double) -> UInt32? {
        guard let key, rate > 0, now >= next else { return nil }
        let interval = 1 / Double(rate)
        next += interval
        if next <= now { next = now + interval }
        return key
    }
}
