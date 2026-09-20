import Glibc

/// What the system monitor shows: the work of the processor, the memory in
/// use, and the space on the disk.
///
/// Every number comes from a file of the kernel or from a call of the C
/// library, and every function that reads one takes the text rather than the
/// path, so that the reading of a file and the understanding of it are two
/// things.
struct Readings {
    /// The part of the processor that is busy, from 0 to 1.
    var processor: Double = 0
    /// The last readings of the processor, oldest first. The tile draws them
    /// as a row of bars.
    var history: [Double] = []
    /// Bytes.
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0

    var memoryPart: Double { part(memoryUsed, of: memoryTotal) }
    var diskPart: Double { part(diskUsed, of: diskTotal) }

    private func part(_ value: UInt64, of total: UInt64) -> Double {
        total > 0 ? min(1, Double(value) / Double(total)) : 0
    }
}

/// Reads the numbers of the system, and remembers enough to tell how busy
/// the processor is between two readings.
struct SystemReader {
    /// How many readings the row of bars holds.
    static let historyLength = 19

    private var lastBusy: UInt64 = 0
    private var lastTotal: UInt64 = 0
    private var history: [Double] = []

    mutating func read() -> Readings {
        var readings = Readings()
        if let (busy, total) = SystemReader.processorTimes(contents("/proc/stat")) {
            // The first reading has nothing to compare with, so it is zero.
            let busyStep = busy >= lastBusy ? busy - lastBusy : 0
            let totalStep = total >= lastTotal ? total - lastTotal : 0
            readings.processor = totalStep > 0 ? Double(busyStep) / Double(totalStep) : 0
            (lastBusy, lastTotal) = (busy, total)
        }
        history.append(readings.processor)
        if history.count > SystemReader.historyLength { history.removeFirst() }
        readings.history = history

        let memory = SystemReader.memory(contents("/proc/meminfo"))
        readings.memoryUsed = memory.used
        readings.memoryTotal = memory.total

        let disk = SystemReader.disk(of: "/")
        readings.diskUsed = disk.used
        readings.diskTotal = disk.total
        return readings
    }

    /// The busy time and the whole time of the processor, in the units of
    /// the kernel. The first line of /proc/stat holds every processor
    /// together: `cpu user nice system idle iowait ...`.
    static func processorTimes(_ text: String) -> (busy: UInt64, total: UInt64)? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") })
        else { return nil }
        let numbers = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard numbers.count >= 4 else { return nil }
        let total = numbers.reduce(0, &+)
        // The fourth number is the idle time, and the fifth is the time that
        // the processor waited for a disk. Neither is work.
        let idle = numbers[3] + (numbers.count > 4 ? numbers[4] : 0)
        return (total >= idle ? total - idle : 0, total)
    }

    /// The memory in use and the memory of the machine, in bytes.
    /// MemAvailable is what a program can have without the machine reaching
    /// for the disk, which is the number a person means by "free".
    static func memory(_ text: String) -> (used: UInt64, total: UInt64) {
        var total: UInt64 = 0
        var available: UInt64 = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let value = UInt64(parts[1]) else { continue }
            // The values are in kibibytes.
            if parts[0] == "MemTotal:" { total = value * 1024 }
            if parts[0] == "MemAvailable:" { available = value * 1024 }
        }
        return (total > available ? total - available : 0, total)
    }

    /// The space in use and the whole space of the file system at `path`.
    static func disk(of path: String) -> (used: UInt64, total: UInt64) {
        var info = statvfs()
        guard statvfs(path, &info) == 0, info.f_frsize > 0 else { return (0, 0) }
        let unit = UInt64(info.f_frsize)
        let total = UInt64(info.f_blocks) * unit
        let free = UInt64(info.f_bavail) * unit
        return (total > free ? total - free : 0, total)
    }
}

/// The text of a file, or an empty string when it cannot be read.
private func contents(_ path: String) -> String {
    guard let file = fopen(path, "r") else { return "" }
    defer { fclose(file) }
    var text = ""
    var buffer = [CChar](repeating: 0, count: 4096)
    while fgets(&buffer, Int32(buffer.count), file) != nil {
        text += String(cString: buffer)
    }
    return text
}

/// A size in bytes, as a person reads it: "1.9 GB", "41 GB".
func humanSize(_ bytes: UInt64) -> String {
    let gigabyte = 1024.0 * 1024 * 1024
    let value = Double(bytes) / gigabyte
    if value >= 10 { return "\(Int(value.rounded())) GB" }
    if value >= 0.1 { return "\(tenths(value)) GB" }
    let megabytes = Double(bytes) / (1024 * 1024)
    return "\(Int(megabytes.rounded())) MB"
}

/// A number with one figure after the point, without Foundation.
private func tenths(_ value: Double) -> String {
    let scaled = Int((value * 10).rounded())
    return "\(scaled / 10).\(scaled % 10)"
}
