// The sounds of Apus, made from numbers.
//
//     swiftc -O generate.swift -o generate && ./generate <directory>
//
// writes one WAV file for each sound, 48 kHz, 16 bit, mono, and a file
// `levels.tsv` with the loudness that each sound must have. check.swift
// reads both. The PKGBUILD encodes the WAV files to Ogg Vorbis.
//
// To change a sound, change its line in `sounds` below and run the program
// again. Nothing here is random, except the noise of the screenshot, and that
// noise has a fixed seed. The same program therefore makes the same files.
// See docs/sounds.md.

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - The rules that every sound follows

/// Samples in a second.
let rate = 48_000.0

/// The loudness of a sound at level 0, in LUFS. It is the loudest value in
/// a window of 400 ms (the "momentary" loudness of ITU-R BS.1770), because a
/// sound of 100 ms has no integrated loudness to speak of. A sound at level
/// -6 is 6 LU below this.
let reference = -20.0

/// No sample goes above this, in dBFS. The space above it is for the
/// encoder: Vorbis can put a peak a little higher than the peak it was given.
let ceiling = -3.0

/// Silence before every sound, in seconds. Vorbis spreads an attack a few
/// milliseconds back in time (pre-echo). Without this silence, that spread
/// starts at the first sample, and the first sample is not zero.
let lead = 0.005

// MARK: - The notes

/// The tuning is equal temperament with A4 at 440 Hz, and the key is D major.
/// Every sound takes its notes from the pentatonic scale of that key,
/// D E F# A B, so that any two sounds that play together agree.
func hz(_ name: String) -> Double {
    let steps: [Character: Int] = ["C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2]
    var letters = Array(name)
    var semitone = steps[letters.removeFirst()]!
    if letters.first == "#" { semitone += 1; letters.removeFirst() }
    if letters.first == "b" { semitone -= 1; letters.removeFirst() }
    let octave = Int(String(letters))!
    semitone += (octave - 4) * 12
    return 440 * pow(2, Double(semitone) / 12)
}

// MARK: - The voices

/// One struck note. Every tonal sound of Apus is made of these.
///
/// The tone is two-operator FM with the modulator at the pitch of the
/// carrier: at a small index that is a soft, round tone with all the
/// harmonics, and the index falls faster than the level, so the note gets
/// darker as it dies, as a struck thing does. A second partial at 2.76 times
/// the pitch, the first overtone of a bar, gives the note a little glass,
/// and it dies three times as fast.
struct Chime {
    var pitch: String
    /// When the note starts, in seconds from the start of the sound.
    var at = 0.0
    /// A note can slide to a second pitch over `glide` seconds.
    var to: String? = nil
    var glide = 0.0
    /// The rise, in seconds. A few milliseconds is a soft strike, and it is
    /// never zero: a note that starts at full level is a click.
    var attack = 0.004
    /// The time constant of the fall, in seconds.
    var decay = 0.08
    /// The FM index at the strike. 0 is a sine.
    var bright = 0.9
    /// The level of the glass partial, against the fundamental.
    var glass = 0.12
    /// The level of the note, against the other notes of the sound.
    var gain = 1.0
}

/// Noise through a band-pass filter, for the one sound that is not a note:
/// the screenshot. It has a fixed seed, so that each run makes the same file.
struct Air {
    var at = 0.0
    var center = 3_500.0
    var q = 1.2
    var attack = 0.004
    var decay = 0.03
    var gain = 1.0
}

/// A soft tick: a short, bright chime. The volume, the devices and the
/// shutter use it.
func tick(_ pitch: String, at: Double = 0, decay: Double = 0.02, gain: Double = 1) -> Chime {
    Chime(pitch: pitch, at: at, attack: 0.0015, decay: decay, bright: 1.3, glass: 0, gain: gain)
}

/// One sound of the theme.
struct Sound {
    /// The name in the freedesktop sound naming specification.
    var id: String
    /// Its loudness against `reference`, in LU.
    var level: Double
    /// Its length in seconds. The notes ring on into the fade at the end.
    var length: Double
    /// The fade at the end, in seconds. It takes the sound to zero, so the
    /// last sample is silence and the speaker does not click.
    var fade: Double
    var chimes: [Chime] = []
    var air: [Air] = []
}

// MARK: - The sounds

let sounds: [Sound] = [
    // The session starts. The one long sound: it plays once, and it may take
    // a moment. D major, from the bottom up, over a low D.
    Sound(id: "desktop-login", level: -2, length: 1.0, fade: 0.30, chimes: [
        Chime(pitch: "D4", attack: 0.15, decay: 0.50, bright: 0.2, glass: 0, gain: 0.45),
        Chime(pitch: "D5", at: 0.00, decay: 0.28, bright: 0.8),
        Chime(pitch: "F#5", at: 0.07, decay: 0.28, bright: 0.8),
        Chime(pitch: "A5", at: 0.14, decay: 0.28, bright: 0.8),
        Chime(pitch: "D6", at: 0.21, decay: 0.36, bright: 0.7, gain: 0.9),
    ]),
    // The session ends: power off, restart, or the shell stops. The login,
    // down and shorter.
    Sound(id: "desktop-logout", level: -3, length: 0.60, fade: 0.20, chimes: [
        Chime(pitch: "A5", at: 0.00, decay: 0.16, bright: 0.7),
        Chime(pitch: "F#5", at: 0.07, decay: 0.16, bright: 0.7),
        Chime(pitch: "D5", at: 0.14, decay: 0.22, bright: 0.6),
        Chime(pitch: "D4", attack: 0.05, decay: 0.25, bright: 0.2, glass: 0, gain: 0.35),
    ]),
    // An app has a message for a person. Up a fifth: a question that is
    // pleasant to hear.
    Sound(id: "message-new-instant", level: 0, length: 0.28, fade: 0.04, chimes: [
        Chime(pitch: "A5", at: 0.000, decay: 0.06, bright: 1.0, glass: 0.2),
        Chime(pitch: "D6", at: 0.065, decay: 0.09, bright: 0.9, glass: 0.2),
    ]),
    // A notice of the system that only informs. One note, softer than a
    // message, because it asks for nothing.
    Sound(id: "dialog-information", level: -3, length: 0.22, fade: 0.05, chimes: [
        Chime(pitch: "F#5", decay: 0.07, bright: 0.8, glass: 0.15),
    ]),
    // Something is not right, and the system carries on. The same note twice:
    // it asks for attention, and it goes neither up nor down.
    Sound(id: "dialog-warning", level: 0, length: 0.30, fade: 0.04, chimes: [
        Chime(pitch: "E5", at: 0.00, decay: 0.045, bright: 1.1, glass: 0.1),
        Chime(pitch: "E5", at: 0.12, decay: 0.06, bright: 1.1, glass: 0.1),
    ]),
    // Something failed. Down a fourth, lower and darker than the others, but
    // not louder: a failure needs to be clear, not a fright.
    Sound(id: "dialog-error", level: 0, length: 0.32, fade: 0.05, chimes: [
        Chime(pitch: "D5", at: 0.00, decay: 0.05, bright: 0.7, glass: 0.05),
        Chime(pitch: "A4", at: 0.10, decay: 0.09, bright: 0.6, glass: 0.05),
    ]),
    // The bell of the terminal. It can come many times in a second, so it
    // is short and soft.
    Sound(id: "bell", level: -6, length: 0.15, fade: 0.03, chimes: [
        Chime(pitch: "B5", attack: 0.002, decay: 0.04, bright: 0.9, glass: 0.25),
    ]),
    // A step of the volume. It plays at the new volume, so that a person
    // hears what they chose. It is a tick, because a key that repeats plays
    // it ten times in a second.
    Sound(id: "audio-volume-change", level: -6, length: 0.07, fade: 0.015, chimes: [
        tick("D6", decay: 0.014),
    ]),
    // A picture of the screen: a shutter that opens and closes, with air.
    Sound(id: "screen-capture", level: -4, length: 0.20, fade: 0.03, chimes: [
        tick("F#6", at: 0.000, decay: 0.010),
        tick("A6", at: 0.075, decay: 0.012, gain: 0.8),
    ], air: [
        Air(at: 0.000, center: 2_800, q: 2, decay: 0.025),
        Air(at: 0.075, center: 3_400, q: 2, decay: 0.035, gain: 0.7),
    ]),
    // A device arrives: two ticks, up. It goes: the same two, down.
    Sound(id: "device-added", level: -4, length: 0.20, fade: 0.04, chimes: [
        tick("F#5", at: 0.000, decay: 0.030),
        tick("B5", at: 0.055, decay: 0.045),
    ]),
    Sound(id: "device-removed", level: -4, length: 0.20, fade: 0.04, chimes: [
        tick("B5", at: 0.000, decay: 0.030),
        tick("F#5", at: 0.055, decay: 0.045),
    ]),
    // The charger. A note that slides up, as a level that fills; when the
    // charger goes, it slides down.
    Sound(id: "power-plug", level: -4, length: 0.26, fade: 0.05, chimes: [
        Chime(pitch: "D5", to: "A5", glide: 0.09, decay: 0.08, bright: 0.9, glass: 0.1),
    ]),
    Sound(id: "power-unplug", level: -4, length: 0.26, fade: 0.05, chimes: [
        Chime(pitch: "A5", to: "D5", glide: 0.09, decay: 0.08, bright: 0.9, glass: 0.1),
    ]),
    // The battery is low. Down a fourth, twice: the only sound that repeats
    // itself, because a person must not miss it.
    Sound(id: "battery-low", level: -1, length: 0.46, fade: 0.05, chimes: [
        Chime(pitch: "B5", at: 0.00, decay: 0.04, bright: 1.0, glass: 0.1),
        Chime(pitch: "E5", at: 0.08, decay: 0.06, bright: 0.9, glass: 0.1),
        Chime(pitch: "B5", at: 0.22, decay: 0.04, bright: 1.0, glass: 0.1),
        Chime(pitch: "E5", at: 0.30, decay: 0.06, bright: 0.9, glass: 0.1),
    ]),
]

// MARK: - The synthesis

/// The rise of a note: half a cosine, from 0 to 1. It starts with a slope of
/// zero, so it adds no click.
func rise(_ t: Double, over length: Double) -> Double {
    t >= length ? 1 : 0.5 - 0.5 * cos(Double.pi * t / length)
}

func render(_ chime: Chime, into samples: inout [Double]) {
    let start = Int(((lead + chime.at) * rate).rounded())
    let from = hz(chime.pitch)
    let to = chime.to.map(hz) ?? from
    var carrier = 0.0, glass = 0.0
    for n in start..<samples.count {
        let t = Double(n - start) / rate
        // The pitch slides on a smooth step, so the slide has no corner.
        var f = from
        if chime.glide > 0 {
            let x = min(t / chime.glide, 1)
            f = from * pow(to / from, x * x * (3 - 2 * x))
        }
        let level = rise(t, over: chime.attack) * exp(-max(t - chime.attack, 0) / chime.decay)
        if level < 1e-6 && t > chime.attack { break }
        let index = chime.bright * exp(-t / (chime.decay * 0.5))
        let tone = sin(carrier + index * sin(carrier))
        let partial = chime.glass * sin(glass) * exp(-t / (chime.decay / 3))
        samples[n] += chime.gain * level * (tone + partial)
        carrier += 2 * Double.pi * f / rate
        glass += 2 * Double.pi * f * 2.76 / rate
    }
}

/// A random number generator with a fixed seed (xorshift64*).
struct Noise {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Double {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        let value = state &* 0x2545_F491_4F6C_DD1D
        return Double(value >> 11) / Double(1 << 53) * 2 - 1
    }
}

func render(_ air: Air, into samples: inout [Double], noise: inout Noise) {
    // A band-pass biquad (RBJ, constant peak gain).
    let w = 2 * Double.pi * air.center / rate
    let alpha = sin(w) / (2 * air.q)
    let a0 = 1 + alpha
    let b0 = alpha / a0, b2 = -alpha / a0
    let a1 = -2 * cos(w) / a0, a2 = (1 - alpha) / a0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    let start = Int(((lead + air.at) * rate).rounded())
    for n in start..<samples.count {
        let t = Double(n - start) / rate
        let level = rise(t, over: air.attack) * exp(-max(t - air.attack, 0) / air.decay)
        let x = noise.next() * level
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        samples[n] += air.gain * y
    }
}

// MARK: - The loudness

/// The loudness of ITU-R BS.1770: the K filter (a shelf and a high-pass;
/// these are the coefficients that the standard gives for 48 kHz), then the
/// loudest mean square in a window of 400 ms. The sound is padded with
/// silence, so a short sound is one window with the whole sound in it.
func loudness(_ samples: [Double]) -> Double {
    func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in x.indices {
            y[n] = b[0] * x[n] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x2 = x1; x1 = x[n]; y2 = y1; y1 = y[n]
        }
        return y
    }
    let window = Int(0.4 * rate), hop = Int(0.01 * rate)
    let padded = [Double](repeating: 0, count: window) + samples + [Double](repeating: 0, count: window)
    let shelf = biquad(padded, [1.53512485958697, -2.69169618940638, 1.19839281085285],
                       [1, -1.69065929318241, 0.73248077421585])
    let k = biquad(shelf, [1, -2, 1], [1, -1.99004745483398, 0.99007225036621])
    var loudest = 0.0
    var start = 0
    while start + window <= k.count {
        var sum = 0.0
        for n in start..<(start + window) { sum += k[n] * k[n] }
        loudest = max(loudest, sum / Double(window))
        start += hop
    }
    return -0.691 + 10 * log10(loudest)
}

// MARK: - The files

func writeWAV(_ samples: [Int16], to path: String) {
    var bytes: [UInt8] = []
    func put(_ text: String) { bytes += Array(text.utf8) }
    func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    let data = UInt32(samples.count * 2)
    put("RIFF"); put32(36 + data); put("WAVE")
    put("fmt "); put32(16); put16(1); put16(1)       // PCM, mono
    put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
    put("data"); put32(data)
    for sample in samples { put16(UInt16(bitPattern: sample)) }
    guard let file = fopen(path, "wb") else { fatalError("can't write \(path)") }
    fwrite(bytes, 1, bytes.count, file)
    fclose(file)
}

func make(_ sound: Sound) -> (samples: [Int16], loudness: Double, peak: Double) {
    var samples = [Double](repeating: 0, count: Int(((lead + sound.length) * rate).rounded()))
    var noise = Noise()
    for chime in sound.chimes { render(chime, into: &samples) }
    for air in sound.air { render(air, into: &samples, noise: &noise) }

    // Take away any offset from zero: a high-pass of one pole at 20 Hz.
    let r = 1 - 2 * Double.pi * 20 / rate
    var previous = 0.0, output = 0.0
    for n in samples.indices {
        output = samples[n] - previous + r * output
        previous = samples[n]
        samples[n] = output
    }

    // The fade at the end, down to exact silence.
    let fadeOut = Int(sound.fade * rate)
    for i in 0..<fadeOut {
        samples[samples.count - 1 - i] *= rise(Double(i), over: Double(fadeOut))
    }

    // The level: the loudness that the sound must have.
    let target = reference + sound.level
    let gain = pow(10, (target - loudness(samples)) / 20)
    samples = samples.map { $0 * gain }
    let peak = 20 * log10(samples.map(abs).max()!)
    guard peak <= ceiling else {
        fatalError("\(sound.id): the peak is \(peak) dBFS at \(target) LUFS; the ceiling is \(ceiling). Lower its level.")
    }
    let quantised = samples.map { Int16(($0 * 32767).rounded()) }
    return (quantised, loudness(samples), peak)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: generate <directory>\n", stderr)
    exit(2)
}
let directory = arguments[1]
var levels = "# id\ttarget LUFS (momentary, largest)\tlength in samples\n"
for sound in sounds {
    let (samples, measured, peak) = make(sound)
    writeWAV(samples, to: "\(directory)/\(sound.id).wav")
    levels += "\(sound.id)\t\(reference + sound.level)\t\(samples.count)\n"
    print(sound.id, "\(Int(((lead + sound.length) * 1000).rounded())) ms",
          "\((measured * 10).rounded() / 10) LUFS", "peak \((peak * 10).rounded() / 10) dBFS")
}
guard let file = fopen("\(directory)/levels.tsv", "w") else { fatalError("can't write levels.tsv") }
fputs(levels, file)
fclose(file)
