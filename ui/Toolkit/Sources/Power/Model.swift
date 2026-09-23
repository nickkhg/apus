import Toolkit

// What Power knows about where the power of the machine comes from.
//
// The kernel says it in /sys/class/power_supply: one folder for each
// battery and each adapter, and in each a file `uevent` with every value of
// it as `POWER_SUPPLY_KEY=value`. The app (ui/Sources/PowerApp) reads those
// files, and this module makes sense of the text, so that the Mac tests it
// with the text of real machines and with none at all.

public protocol PowerSource: AnyObject {
    /// The folders of /sys/class/power_supply: the name of each, and the
    /// text of its `uevent`.
    func supplies() -> [(name: String, uevent: String)]
    /// What the machine is. It does not change while the machine runs.
    var machine: MachineKind { get }
}

/// What kind of machine this is, as far as the power goes.
public enum MachineKind: Sendable, Equatable {
    /// A virtual machine of Apple's Virtualization framework: the Mac has
    /// the battery.
    case appleVM
    /// Another virtual machine, with its name.
    case virtualMachine(String)
    /// A container, which sees none of the power of the machine under it.
    case container
    /// Real hardware, or nothing that says otherwise.
    case unknown

    /// The kind from what `systemd-detect-virt` printed: "apple" in a VM of
    /// Apple's Virtualization framework, "none" on real hardware. Settings
    /// asks the same program (docs/settings.md).
    public static func from(detectVirt output: String) -> MachineKind {
        let word = output.split(separator: "\n").first.map(String.init) ?? ""
        switch word {
        case "apple": return .appleVM
        case "", "none": return .unknown
        // The program names a container before the machine under it.
        case "docker", "podman", "lxc", "lxc-libvirt", "systemd-nspawn", "rkt", "wsl",
             "proot", "pouch", "openvz", "container-other":
            return .container
        default: return .virtualMachine(word)
        }
    }
}

/// One battery or one adapter.
public struct PowerSupply: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case battery
        /// An adapter from the wall.
        case mains
        /// A USB port that gives power.
        case usb
        /// Anything else the kernel names: UPS, Wireless.
        case other(String)
    }

    /// Charging, Discharging, Full, Not charging, or Unknown, as the
    /// kernel says it.
    public enum Status: Sendable, Equatable {
        case charging, discharging, full, notCharging, unknown
    }

    public var name: String
    public var kind: Kind
    public var status = Status.unknown
    /// For a battery: it is in the machine. For an adapter: it is plugged in.
    public var isPresent = true
    public var isOnline = false
    /// The part that is left, from 0 to 100.
    public var capacity: Double?
    /// Watts that go in or come out now.
    public var watts: Double?
    /// Watt hours now, when full, and when the battery was new.
    public var energy: Double?
    public var energyFull: Double?
    public var energyDesign: Double?
    public var volts: Double?
    /// Seconds, when the battery itself says it.
    public var timeToEmpty: Double?
    public var timeToFull: Double?
    public var cycles: Int?
    /// Degrees Celsius.
    public var temperature: Double?
    public var technology = ""
    public var model = ""
    public var manufacturer = ""
    /// The battery of a mouse or a pad says `Device`: it is not the power
    /// of the machine.
    public var isOfADevice = false

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// The values of a `uevent` file. The numbers of the kernel are in
    /// millionths: µW, µWh, µAh, µA and µV.
    public static func parse(_ uevent: String, name: String) -> PowerSupply {
        var values: [String: String] = [:]
        for line in uevent.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            var key = line[..<equals]
            if key.hasPrefix("POWER_SUPPLY_") { key = key.dropFirst("POWER_SUPPLY_".count) }
            values[String(key)] = String(line[line.index(after: equals)...])
        }
        func number(_ key: String) -> Double? { values[key].flatMap { Double($0) } }
        func millionths(_ key: String) -> Double? { number(key).map { $0 / 1_000_000 } }

        let kind: Kind = switch values["TYPE"] ?? "" {
        case "Battery": .battery
        case "Mains": .mains
        case "USB", "USB_C", "USB_PD", "USB_DCP", "USB_CDP": .usb
        case let other: .other(other.isEmpty ? "Unknown" : other)
        }
        var supply = PowerSupply(name: values["NAME"] ?? name, kind: kind)
        supply.status = switch values["STATUS"] ?? "" {
        case "Charging": .charging
        case "Discharging": .discharging
        case "Full": .full
        case "Not charging": .notCharging
        default: .unknown
        }
        supply.isPresent = (number("PRESENT") ?? 1) != 0
        supply.isOnline = (number("ONLINE") ?? 0) != 0
        supply.isOfADevice = values["SCOPE"] == "Device"
        supply.volts = millionths("VOLTAGE_NOW")

        // A battery counts in energy (µWh) or in charge (µAh). Charge times
        // the voltage is energy.
        let volts = supply.volts ?? millionths("VOLTAGE_MIN_DESIGN")
        func energy(_ name: String) -> Double? {
            if let value = millionths("ENERGY_\(name)") { return value }
            if let charge = millionths("CHARGE_\(name)"), let volts { return charge * volts }
            return nil
        }
        supply.energy = energy("NOW")
        supply.energyFull = energy("FULL")
        supply.energyDesign = energy("FULL_DESIGN")

        if let power = millionths("POWER_NOW") {
            supply.watts = abs(power)
        } else if let current = millionths("CURRENT_NOW"), let volts = supply.volts {
            // Some batteries give a current below zero while they empty.
            supply.watts = abs(current * volts)
        }
        if let capacity = number("CAPACITY") {
            supply.capacity = min(100, max(0, capacity))
        } else if let now = supply.energy, let full = supply.energyFull, full > 0 {
            supply.capacity = min(100, now / full * 100)
        }
        supply.timeToEmpty = number("TIME_TO_EMPTY_NOW").flatMap { $0 > 0 ? $0 : nil }
        supply.timeToFull = number("TIME_TO_FULL_NOW").flatMap { $0 > 0 ? $0 : nil }
        supply.cycles = values["CYCLE_COUNT"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        supply.temperature = number("TEMP").map { $0 / 10 }
        supply.technology = values["TECHNOLOGY"].flatMap { $0 == "Unknown" ? nil : $0 } ?? ""
        supply.model = values["MODEL_NAME"] ?? ""
        supply.manufacturer = values["MANUFACTURER"] ?? ""
        return supply
    }

    /// Seconds until the battery is empty, from its own number or from the
    /// energy that is left and the power that goes out.
    public var secondsLeft: Double? {
        guard status == .discharging else { return nil }
        if let timeToEmpty { return timeToEmpty }
        guard let energy, let watts, watts > 0.05 else { return nil }
        return energy / watts * 3600
    }

    /// Seconds until the battery is full.
    public var secondsToFull: Double? {
        guard status == .charging else { return nil }
        if let timeToFull { return timeToFull }
        guard let energy, let energyFull, let watts, watts > 0.05, energyFull > energy else {
            return nil
        }
        return (energyFull - energy) / watts * 3600
    }

    /// What is left of the battery that it was when it was new, from 0 to 100.
    public var health: Double? {
        guard let energyFull, let energyDesign, energyDesign > 0 else { return nil }
        return min(100, energyFull / energyDesign * 100)
    }
}

/// Everything that Power shows at one moment.
public struct PowerReading: Sendable, Equatable {
    /// The batteries of the machine. The battery of a mouse is not one.
    public var batteries: [PowerSupply] = []
    /// The adapters and the ports that give power.
    public var adapters: [PowerSupply] = []
    /// A battery of a device: a mouse, a pad.
    public var devices: [PowerSupply] = []

    public init() {}

    public init(_ supplies: [PowerSupply]) {
        for supply in supplies.sorted(by: { $0.name < $1.name }) {
            if supply.isOfADevice {
                devices.append(supply)
            } else if supply.kind == .battery {
                if supply.isPresent { batteries.append(supply) }
            } else {
                adapters.append(supply)
            }
        }
    }

    /// Where the power comes from now.
    public enum Source: Sendable, Equatable {
        /// The kernel names no battery and no adapter.
        case nothingReported
        /// An adapter, and no battery.
        case mains
        case battery
        /// A battery that an adapter keeps full or charges.
        case batteryOnMains
    }

    public var source: Source {
        let plugged = adapters.contains { $0.isOnline }
            || batteries.contains { $0.status == .charging || $0.status == .full
                || $0.status == .notCharging }
        if batteries.isEmpty { return adapters.isEmpty ? .nothingReported : .mains }
        return plugged ? .batteryOnMains : .battery
    }

    /// The part that is left of every battery together, from 0 to 100.
    public var capacity: Double? {
        let energies = batteries.compactMap { battery in
            battery.energy.flatMap { now in battery.energyFull.map { (now, $0) } }
        }
        if energies.count == batteries.count, !energies.isEmpty {
            let full = energies.reduce(0) { $0 + $1.1 }
            return full > 0 ? min(100, energies.reduce(0) { $0 + $1.0 } / full * 100) : nil
        }
        let parts = batteries.compactMap(\.capacity)
        return parts.isEmpty ? nil : parts.reduce(0, +) / Double(parts.count)
    }

    /// The watts that go through the batteries now: out while they empty,
    /// in while they charge.
    public var watts: Double? {
        let values = batteries.compactMap(\.watts)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var isCharging: Bool { batteries.contains { $0.status == .charging } }
    public var isFull: Bool { !batteries.isEmpty && batteries.allSatisfy { $0.status == .full } }

    /// The longest time that the batteries say: the time of the one that
    /// lasts, when a machine has two.
    public var secondsLeft: Double? { batteries.compactMap(\.secondsLeft).max() }
    public var secondsToFull: Double? { batteries.compactMap(\.secondsToFull).max() }

    /// The state in a few words, for the head of the window and the tile.
    public var state: String {
        switch source {
        case .nothingReported: return "No battery"
        case .mains: return "On AC power"
        case .battery:
            if let seconds = secondsLeft { return "On battery · \(Words.duration(seconds)) left" }
            return "On battery"
        case .batteryOnMains:
            if isFull { return "Full, on AC power" }
            if isCharging {
                if let seconds = secondsToFull { return "Charging · \(Words.duration(seconds)) to full" }
                return "Charging"
            }
            return "On AC power, not charging"
        }
    }
}

/// Numbers in the words of a person. There is no Foundation here.
public enum Words {
    /// "3 h 05 min", "45 min", "under a minute".
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return "\(minutes / 60) h \(rest < 10 ? "0" : "")\(rest) min"
    }

    /// "7.4 W", "12 W", "0.4 W".
    public static func watts(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded())) W" : "\(tenths(value)) W"
    }

    /// "41.2 Wh".
    public static func wattHours(_ value: Double) -> String { "\(tenths(value)) Wh" }

    public static func volts(_ value: Double) -> String { "\(tenths(value)) V" }

    public static func percent(_ value: Double) -> String { "\(Int(value.rounded())) %" }

    /// A number with one figure after the point.
    static func tenths(_ value: Double) -> String {
        let scaled = Int((value * 10).rounded())
        return "\(scaled / 10).\(scaled % 10)"
    }
}
