import Toolkit

// What Settings knows about the machine, and what it can ask the machine to
// do.
//
// The views read a snapshot, and they never read a file themselves. The app
// (ui/Sources/SettingsApp) reads the files of the system into the snapshot
// and carries out the changes, because only it runs on Apus: this module
// also builds on the Mac, where the tests give it a machine of their own.

/// One part of Settings: a line in the sidebar and the pane that it opens.
public enum Pane: String, CaseIterable, Sendable {
    case about, time, password, display, keyboard, network, apps, power

    public var title: String {
        switch self {
        case .about: "About"
        case .time: "Date & Time"
        case .password: "Password"
        case .display: "Display"
        case .keyboard: "Keyboard"
        case .network: "Network"
        case .apps: "Apps"
        case .power: "Power"
        }
    }

    /// What the pane is for, under its title.
    var subtitle: String {
        switch self {
        case .about: "This machine, and the name that it gives the network"
        case .time: "The clock, and the place whose time it keeps"
        case .password: "Who can log in as root"
        case .display: "How the shell draws the screen"
        case .keyboard: "What each key writes"
        case .network: "The connections of this machine"
        case .apps: "What Summon lists"
        case .power: "Start the shell or the machine again, or stop it"
        }
    }

    /// The group of the sidebar that the pane is in.
    var group: String {
        switch self {
        case .about, .time, .password: "System"
        case .display, .keyboard, .network: "Devices"
        case .apps: "Software"
        case .power: ""
        }
    }

    /// The colour of the mark in the sidebar.
    var mark: Color {
        switch self {
        case .about: Color(hex: 0xA3AEB4)
        case .time: Color(hex: 0x3BB273)
        case .password: Color(hex: 0xE0574B)
        case .display: Color(hex: 0x7C6CF0)
        case .keyboard: Color(hex: 0xE0A458)
        case .network: Color(hex: 0x49C7C7)
        case .apps: Color(hex: 0x3070F0)
        case .power: Color(hex: 0xA9E34B)
        }
    }
}

/// Everything that Settings shows, as the app read it.
public struct Snapshot: Sendable {
    public var about = About()
    public var time = TimeSettings()
    public var password = PasswordState.unknown
    public var screens: [ScreenInfo] = []
    /// What the shell runs with now: its own environment, which every app
    /// that it starts inherits.
    public var running = ShellSettings()
    /// What the shell will run with when systemd starts it again.
    public var saved = ShellSettings()
    /// Whether systemd runs the shell, so that it can start it again.
    public var shellIsService = false
    public var interfaces: [NetworkInterface] = []
    public var nameServers: [String] = []
    public var apps: [AppInfo] = []
    public var load: [Double] = []

    public init() {}
}

public struct About: Sendable, Equatable {
    public var hostName = ""
    public var system = "Apus"
    public var build = ""
    public var kernel = ""
    public var architecture = ""
    public var processors = 0
    /// Bytes.
    public var memory: UInt64 = 0
    public var diskUsed: UInt64 = 0
    public var diskTotal: UInt64 = 0
    /// The date that the installer wrote, or nil.
    public var installed: String?
    /// The live image, which keeps nothing when it stops.
    public var isLive = false
    /// Seconds since the machine started.
    public var uptime: Double = 0
    public var machineID = ""
    /// What the machine runs on: "apple" in a VM of a Mac, or empty.
    public var virtualization = ""

    public init() {}
}

public struct TimeSettings: Sendable, Equatable {
    /// The zone of /etc/localtime, for example "Europe/Berlin".
    public var zone = "UTC"
    /// systemd-timesyncd sets the clock from the network.
    public var networkTime = false
    /// It has done so since it started.
    public var synchronized = false
    public var zones: [TimeZoneEntry] = []

    public init() {}
}

/// The time, read again every second.
public struct ClockReading: Sendable, Equatable {
    public var hour = 0
    public var minute = 0
    public var second = 0
    /// "Wednesday 23 September 2026".
    public var date = ""
    /// "CEST", as the zone names it.
    public var abbreviation = ""
    /// Seconds east of UTC.
    public var offset = 0

    public init(hour: Int = 0, minute: Int = 0, second: Int = 0, date: String = "",
                abbreviation: String = "", offset: Int = 0) {
        self.hour = hour
        self.minute = minute
        self.second = second
        self.date = date
        self.abbreviation = abbreviation
        self.offset = offset
    }

    var time: String { "\(twoDigits(hour)):\(twoDigits(minute))" }
    var seconds: String { twoDigits(second) }

    /// "UTC+02:00".
    var offsetText: String {
        let sign = offset < 0 ? "−" : "+"
        let minutes = abs(offset) / 60
        return "UTC\(sign)\(twoDigits(minutes / 60)):\(twoDigits(minutes % 60))"
    }
}

public struct TimeZoneEntry: Identifiable, Sendable, Equatable {
    /// "America/Argentina/Buenos_Aires".
    public let id: String
    /// The countries that keep this time, as ISO codes.
    public let countries: [String]

    public init(id: String, countries: [String] = []) {
        self.id = id
        self.countries = countries
    }

    /// "Buenos Aires".
    public var city: String {
        String(id.split(separator: "/").last ?? Substring(id)).replacing("_", with: " ")
    }

    /// "America / Argentina".
    public var region: String {
        let parts = id.split(separator: "/")
        return parts.dropLast().joined(separator: " / ").replacing("_", with: " ")
    }
}

public enum PasswordState: Sendable, Equatable {
    /// Anyone can log in as root without one.
    case none
    case set
    /// No password opens the account.
    case locked
    case unknown
}

public struct ScreenInfo: Identifiable, Sendable, Equatable {
    /// The connector, for example "Virtual-1".
    public let id: String
    /// "1280x800".
    public let mode: String

    public init(id: String, mode: String) {
        self.id = id
        self.mode = mode
    }
}

/// What the shell reads from its environment when it starts.
public struct ShellSettings: Sendable, Equatable {
    public enum Renderer: String, Sendable, CaseIterable {
        case cpu, gpu
    }

    /// How the shell draws its surfaces: the renderer decides, or a person.
    public enum Look: String, Sendable, CaseIterable {
        case automatic, cpu, gpu
    }

    public var renderer = Renderer.cpu
    public var look = Look.automatic
    /// Pixels to the point, or nil for what the screen says.
    public var scale: Double?
    /// The layout of the keys, as xkb names it: "us", "de".
    public var layout = ""
    /// A variant of the layout: "dvorak", "intl".
    public var variant = ""
    /// Options of xkb: "ctrl:nocaps", "altwin:swap_alt_win".
    public var options: [String] = []

    public init(renderer: Renderer = .cpu, look: Look = .automatic, scale: Double? = nil,
                layout: String = "", variant: String = "", options: [String] = []) {
        self.renderer = renderer
        self.look = look
        self.scale = scale
        self.layout = layout
        self.variant = variant
        self.options = options
    }

    /// What Caps Lock does. The four choices are options of xkb that
    /// exclude one another.
    public var capsLock: String {
        options.first { $0.hasPrefix("caps:") || $0 == "ctrl:nocaps" } ?? ""
    }

    public mutating func setCapsLock(_ option: String) {
        options.removeAll { $0.hasPrefix("caps:") || $0 == "ctrl:nocaps" }
        if !option.isEmpty { options.append(option) }
    }

    public func has(_ option: String) -> Bool { options.contains(option) }

    public mutating func set(_ option: String, _ on: Bool) {
        options.removeAll { $0 == option }
        if on { options.append(option) }
    }

    /// The settings of the display alone, so that a change to the keyboard
    /// is not a change to the display.
    var display: ShellSettings {
        ShellSettings(renderer: renderer, look: look, scale: scale)
    }

    var keyboard: ShellSettings {
        ShellSettings(layout: layout, variant: variant, options: options)
    }
}

public struct NetworkInterface: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable { case wired, wireless, other }

    public let id: String
    public var kind = Kind.wired
    /// The kernel's operstate: "up", "down", "dormant", "unknown".
    public var state = ""
    public var hardwareAddress = ""
    public var ipv4: [String] = []
    public var ipv6: [String] = []
    public var gateway = ""
    /// Megabits a second, or 0 when the device does not say.
    public var speed = 0

    public init(id: String) {
        self.id = id
    }

    var isConnected: Bool { state == "up" }
}

public struct AppInfo: Identifiable, Sendable, Equatable {
    public enum Source: Sendable { case bundle, package }

    public let id: String
    public var name: String
    public var color: Color
    public var source: Source
    /// The program that the app runs.
    public var program: String
    /// Summon lists it.
    public var isShown = true

    public init(id: String, name: String, color: Color, source: Source, program: String,
                isShown: Bool = true) {
        self.id = id
        self.name = name
        self.color = color
        self.source = source
        self.program = program
        self.isShown = isShown
    }
}

/// What came of a change.
public enum Outcome: Sendable, Equatable {
    case done(String)
    case failed(String)
}

/// What Settings asks of the machine. The app does it, and a test gives a
/// machine of its own.
public protocol SettingsSystem: AnyObject {
    /// Everything that the panes show. The list of the zones is long and
    /// does not change, so `zones` says whether to read it again.
    func read(zones: Bool) -> Snapshot
    func clock() -> ClockReading
    func setHostName(_ name: String) -> Outcome
    func setTimeZone(_ zone: String) -> Outcome
    func setNetworkTime(_ on: Bool) -> Outcome
    /// A password for root, or nil for none.
    func setPassword(_ password: String?) -> Outcome
    func saveShellSettings(_ settings: ShellSettings) -> Outcome
    func renew(_ interface: String) -> Outcome
    func setShown(_ app: AppInfo, _ shown: Bool) -> Outcome
    func restartShell() -> Outcome
    func restartMachine() -> Outcome
    func powerOff() -> Outcome
}

func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
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
func tenths(_ value: Double) -> String {
    let scaled = Int((value * 10).rounded())
    return "\(scaled / 10).\(scaled % 10)"
}

/// "3 days, 4 hours", "12 minutes".
func duration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let days = total / 86_400, hours = total / 3600 % 24, minutes = total / 60 % 60
    func unit(_ value: Int, _ name: String) -> String {
        "\(value) \(name)\(value == 1 ? "" : "s")"
    }
    if days > 0 { return unit(days, "day") + ", " + unit(hours, "hour") }
    if hours > 0 { return unit(hours, "hour") + ", " + unit(minutes, "minute") }
    return unit(max(minutes, 0), "minute")
}
