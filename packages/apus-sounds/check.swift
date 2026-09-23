// Checks the sounds with numbers, because a build cannot listen.
//
//     swiftc -O check.swift -o check
//     ./check <levels.tsv> <file.wav>...            what generate.swift wrote
//     ./check --decoded <levels.tsv> <file.wav>...  the same, after Vorbis
//
// For each file it prints the length, the peak, the RMS, the loudness, the
// offset from zero and the edges, and it fails when one of them is wrong.
// It shares no code with generate.swift, so a mistake in one is not the same
// mistake in the other. See docs/sounds.md.

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let rate = 48_000

// What a sound must be. Vorbis is lossy, so a decoded file gets more room.
var decoded = false
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--decoded" { decoded = true; arguments.removeFirst() }
guard arguments.count >= 2 else {
    fputs("usage: check [--decoded] <levels.tsv> <file.wav>...\n", stderr)
    exit(2)
}
/// The highest sample, in dBFS.
let ceiling = decoded ? -1.0 : -3.0
/// How far the loudness may be from its target, in LU.
let tolerance = decoded ? 1.0 : 0.1
/// The largest first and last sample. A step larger than this at an edge is
/// a click. 16-bit rounding is one step; Vorbis leaves some noise.
let edge = decoded ? 0.001 : 1.5 / 32768
/// The largest offset from zero: -80 dBFS.
let offset = 1e-4

func readFile(_ path: String) -> [UInt8] {
    guard let file = fopen(path, "rb") else { fatalError("can't read \(path)") }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = fread(&buffer, 1, buffer.count, file)
        if count == 0 { break }
        bytes += buffer[0..<count]
    }
    return bytes
}

struct WAV {
    var rate = 0, channels = 0, bits = 0
    var samples: [Double] = []
}

/// A PCM WAV file: the chunks `fmt ` and `data`, and any others skipped.
func readWAV(_ path: String) -> WAV {
    let b = readFile(path)
    func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
    func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    func tag(_ i: Int) -> String { String(decoding: b[i..<(i + 4)], as: UTF8.self) }
    guard b.count > 12, tag(0) == "RIFF", tag(8) == "WAVE" else { fatalError("\(path) is not a WAV file") }
    var wav = WAV()
    var i = 12
    while i + 8 <= b.count {
        let size = u32(i + 4)
        let body = i + 8
        if tag(i) == "fmt " {
            wav.channels = u16(body + 2); wav.rate = u32(body + 4); wav.bits = u16(body + 14)
        } else if tag(i) == "data" {
            guard wav.bits == 16 else { fatalError("\(path): \(wav.bits) bits; expected 16") }
            let end = min(body + size, b.count)
            var n = body
            // Only the first channel: the files are mono.
            while n + 2 * wav.channels <= end {
                wav.samples.append(Double(Int16(bitPattern: UInt16(u16(n)))) / 32768)
                n += 2 * wav.channels
            }
        }
        i = body + size + (size & 1)
    }
    return wav
}

/// ITU-R BS.1770 at 48 kHz: the K filter, then the loudest mean square in a
/// window of 400 ms, with the sound padded by silence.
func loudness(_ x: [Double]) -> Double {
    func biquad(_ x: [Double], _ b: (Double, Double, Double), _ a: (Double, Double)) -> [Double] {
        var y = x, x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in x.indices {
            y[n] = b.0 * x[n] + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
            x2 = x1; x1 = x[n]; y2 = y1; y1 = y[n]
        }
        return y
    }
    let window = rate * 4 / 10
    let padded = [Double](repeating: 0, count: window) + x + [Double](repeating: 0, count: window)
    let k = biquad(biquad(padded, (1.53512485958697, -2.69169618940638, 1.19839281085285),
                          (-1.69065929318241, 0.73248077421585)),
                   (1, -2, 1), (-1.99004745483398, 0.99007225036621))
    // A running sum, one sample at a time.
    var sum = 0.0, loudest = 0.0
    for n in k.indices {
        sum += k[n] * k[n]
        if n >= window { sum -= k[n - window] * k[n - window] }
        loudest = max(loudest, sum / Double(window))
    }
    return -0.691 + 10 * log10(loudest)
}

func dB(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }
func rounded(_ x: Double) -> String {
    let r = (x * 10).rounded() / 10
    return r == 0 ? "0.0" : "\(r)"
}

// levels.tsv: the id, the target loudness and the length in samples.
var targets: [String: (loudness: Double, length: Int)] = [:]
for line in String(decoding: readFile(arguments[0]), as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
    let fields = line.split(separator: "\t")
    targets[String(fields[0])] = (Double(fields[1])!, Int(fields[2])!)
}

var failures = 0
print("| Sound | Length | Peak | RMS | Loudness | Target | DC | First, last | Start | Onset | Tail |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for path in arguments.dropFirst() {
    let name = String(path.split(separator: "/").last!.split(separator: ".").first!)
    let wav = readWAV(path)
    let x = wav.samples
    var problems: [String] = []
    func require(_ condition: Bool, _ problem: String) { if !condition { problems.append(problem) } }

    require(wav.rate == rate, "rate \(wav.rate)")
    require(wav.channels == 1, "\(wav.channels) channels")
    guard let target = targets[name] else { fatalError("\(name) is not in \(arguments[0])") }
    require(x.count == target.length, "\(x.count) samples; expected \(target.length)")

    let peak = x.map(abs).max() ?? 0
    // The RMS of the part that sounds: from the onset to the last sample
    // that is within 40 dB of the peak.
    let threshold = peak / 100
    let onset = x.firstIndex { abs($0) >= threshold } ?? 0
    let last = x.lastIndex { abs($0) >= threshold } ?? 0
    let body = x[onset...last]
    let rms = (body.reduce(0) { $0 + $1 * $1 } / Double(body.count)).squareRoot()
    let mean = x.reduce(0, +) / Double(x.count)
    let measured = loudness(x)
    // The end: the last 5 ms must be 40 dB under the peak, or the fade did
    // not happen.
    let tailCount = rate / 200
    let tail = (x.suffix(tailCount).reduce(0) { $0 + $1 * $1 } / Double(tailCount)).squareRoot()
    // The start: a rise, not a step. A sound that starts at full level is a
    // click. Every sound here has 5 ms of silence and then takes at least
    // 1 ms to rise, so its first 2 ms stay 40 dB under the peak.
    let start = x.prefix(rate / 500).map(abs).max() ?? 0
    let first = abs(x.first ?? 0), end = abs(x.last ?? 0)

    require(dB(peak) <= ceiling, "peak \(rounded(dB(peak))) dBFS")
    require(abs(measured - target.loudness) <= tolerance, "loudness \(rounded(measured)) LUFS")
    require(abs(mean) <= offset, "offset \(mean)")
    require(first <= edge && end <= edge, "edges \(first), \(end)")
    require(dB(start) <= dB(peak) - 40, "the first 2 ms are \(rounded(dB(start) - dB(peak))) dB under the peak")
    require(dB(tail) <= dB(peak) - 40, "the last 5 ms are \(rounded(dB(tail) - dB(peak))) dB under the peak")
    // And no more silence in front than the 5 ms: a sound that is late is
    // a sound that does not belong to what caused it.
    require(Double(onset) / Double(rate) <= 0.008, "the sound starts after \(onset) samples")

    let ms = Double(x.count) * 1000 / Double(rate)
    print("| `\(name)` | \(Int(ms.rounded())) ms | \(rounded(dB(peak))) dBFS | \(rounded(dB(rms))) dBFS "
        + "| \(rounded(measured)) LUFS | \(rounded(target.loudness)) | \(rounded(dB(abs(mean)))) dBFS "
        + "| \(Int((first * 32768).rounded())), \(Int((end * 32768).rounded())) LSB "
        + "| \(rounded(dB(start) - dB(peak))) dB "
        + "| \(rounded(Double(onset) * 1000 / Double(rate))) ms | \(rounded(dB(tail) - dB(peak))) dB |")
    if !problems.isEmpty {
        failures += 1
        fputs("\(name): " + problems.joined(separator: "; ") + "\n", stderr)
    }
}
if failures > 0 {
    fputs("\(failures) sounds failed the check\n", stderr)
    exit(1)
}
