import Synchronization
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// The sounds of the system. An app or the shell asks for an event by its
// name in the freedesktop sound naming specification, and the toolkit finds
// the file of the theme and gives it to `pw-play`.
//
// The toolkit links no audio library, so it builds with none, on the Mac
// too. A machine with no PipeWire, or with no file for the event, plays
// nothing, and that is not a fault: a sound is never the only way that
// Apus says something. See docs/sounds.md.

/// An event that can have a sound: a name of the freedesktop sound naming
/// specification. Any name works. These are the names that the Apus theme
/// has a file for, and `bellTerminal`, which the theme answers with `bell`.
public struct SystemSound: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let desktopLogin = SystemSound(rawValue: "desktop-login")
    public static let desktopLogout = SystemSound(rawValue: "desktop-logout")
    public static let messageNewInstant = SystemSound(rawValue: "message-new-instant")
    public static let dialogInformation = SystemSound(rawValue: "dialog-information")
    public static let dialogWarning = SystemSound(rawValue: "dialog-warning")
    public static let dialogError = SystemSound(rawValue: "dialog-error")
    public static let bell = SystemSound(rawValue: "bell")
    /// The bell of a terminal. The theme has no file of this name, so the
    /// lookup falls back to `bell`, as the specification says.
    public static let bellTerminal = SystemSound(rawValue: "bell-terminal")
    public static let audioVolumeChange = SystemSound(rawValue: "audio-volume-change")
    public static let screenCapture = SystemSound(rawValue: "screen-capture")
    public static let deviceAdded = SystemSound(rawValue: "device-added")
    public static let deviceRemoved = SystemSound(rawValue: "device-removed")
    public static let powerPlug = SystemSound(rawValue: "power-plug")
    public static let powerUnplug = SystemSound(rawValue: "power-unplug")
    public static let batteryLow = SystemSound(rawValue: "battery-low")
}

/// Plays the sound of an event, and returns at once. It answers whether a
/// player started: false when sounds are off, when the event has no file,
/// or when the machine has no `pw-play`.
@discardableResult
public func playSound(_ sound: SystemSound) -> Bool {
    SoundTheme.play(sound)
}

/// What a person chose for the sounds of the system. Settings writes it, and
/// every program that plays a sound reads it again at each sound, so a
/// change counts at once and nothing has to start again.
///
/// It is a file of the person, `$XDG_CONFIG_HOME/apus/sounds.conf` (or
/// `~/.config/apus/sounds.conf`), with lines such as `enabled=no` and
/// `volume=0.5`. No file is the default: sounds on, at full volume.
public struct SoundSettings: Sendable, Equatable {
    public var enabled = true
    /// How loud an event sound is, from 0 to 1. It scales the stream of the
    /// player, so the volume of the machine still sets the loudest sound.
    public var volume = 1.0

    public init(enabled: Bool = true, volume: Double = 1) {
        self.enabled = enabled
        self.volume = min(1, max(0, volume))
    }

    /// Where the file is.
    public static func path() -> String {
        if let home = environment("XDG_CONFIG_HOME") { return "\(home)/apus/sounds.conf" }
        return "\(environment("HOME") ?? "/root")/.config/apus/sounds.conf"
    }

    /// The settings of a file. A line that it does not know, or a value that
    /// does not parse, keeps the default.
    public init(parsing text: String) {
        self.init()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingSpaces, value = parts[1].trimmingSpaces
            switch key {
            case "enabled":
                if ["no", "false", "off", "0"].contains(value) { enabled = false }
                if ["yes", "true", "on", "1"].contains(value) { enabled = true }
            case "volume":
                if let number = Double(value) { volume = min(1, max(0, number)) }
            default: break
            }
        }
    }

    /// The text of the file.
    public var text: String {
        "enabled=\(enabled ? "yes" : "no")\nvolume=\(volume)\n"
    }

    /// The settings of the file, or the default when there is none.
    public static func load(from path: String = SoundSettings.path()) -> SoundSettings {
        guard let file = fopen(path, "r") else { return SoundSettings() }
        defer { fclose(file) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 512)
        while bytes.count < 4096 {
            let count = fread(&buffer, 1, buffer.count, file)
            guard count > 0 else { break }
            bytes += buffer[..<count]
        }
        return SoundSettings(parsing: String(decoding: bytes, as: UTF8.self))
    }
}

/// The volume of the machine: the default output of PipeWire, through
/// `wpctl`. The volume keys ask for it. Each change plays
/// `audio-volume-change` after it, at the new volume, so a person hears how
/// loud the machine is now.
public enum SystemVolume {
    /// One press of a volume key.
    public static let step = 5

    public static func raise() {
        // -l 1.0: a key never goes past 100%, where sound starts to clip.
        change("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ \(step)%+")
    }

    public static func lower() {
        change("wpctl set-volume @DEFAULT_AUDIO_SINK@ \(step)%-")
    }

    /// Mutes the output, or gives it its sound back. Only the second makes
    /// a sound: a muted output has nothing to play it on.
    public static func toggleMute() {
        change("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
               then: "wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -qv MUTED")
    }

    /// Runs the change and then the sound in one shell, so the sound comes
    /// after the change and the caller does not wait for either.
    private static func change(_ command: String, then condition: String? = nil) {
        var script = command
        if let player = SoundTheme.player(for: .audioVolumeChange) {
            let play = player.map(SoundTheme.quoted).joined(separator: " ")
            script += " && " + (condition.map { "\($0) && " } ?? "") + play
        }
        SoundTheme.spawn(["sh", "-c", script])
    }
}

private func environment(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    let text = String(cString: raw)
    return text.isEmpty ? nil : text
}

private extension Substring {
    var trimmingSpaces: String {
        String(drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}

/// How the toolkit finds and plays a sound of a theme.
public enum SoundTheme {
    /// The theme of Apus, in /usr/share/sounds/apus.
    public static let name = "apus"
    /// The theme that every lookup ends with, as the specification says.
    static let fallback = "freedesktop"
    /// The file types of the specification, in the order it gives.
    static let extensions = ["oga", "ogg", "wav"]

    /// Where themes are: `$XDG_DATA_HOME/sounds` (or `~/.local/share/sounds`),
    /// then `sounds` in each directory of `$XDG_DATA_DIRS`.
    public static func directories() -> [String] {
        let value = environment
        var result: [String] = []
        if let home = value("XDG_DATA_HOME") {
            result.append("\(home)/sounds")
        } else if let home = value("HOME") {
            result.append("\(home)/.local/share/sounds")
        }
        let shared = value("XDG_DATA_DIRS") ?? "/usr/local/share:/usr/share"
        result += shared.split(separator: ":").map { "\($0)/sounds" }
        return result
    }

    /// The file for an event, or nil for silence.
    ///
    /// The lookup of the specification: the full name first, then the name
    /// without its last part (`bell-terminal`, then `bell`), each in the
    /// theme and then in `freedesktop`. A file `<name>.disabled` stops the
    /// lookup with silence, so a person can turn one sound off.
    public static func file(for sound: SystemSound, theme: String = SoundTheme.name,
                            in directories: [String] = SoundTheme.directories()) -> String? {
        let themes = theme == fallback ? [theme] : [theme, fallback]
        var name = Substring(sound.rawValue)
        while !name.isEmpty {
            for theme in themes {
                for directory in directories {
                    let base = "\(directory)/\(theme)/stereo/\(name)"
                    if exists("\(base).disabled") { return nil }
                    for type in extensions where exists("\(base).\(type)") {
                        return "\(base).\(type)"
                    }
                }
            }
            guard let dash = name.lastIndex(of: "-") else { break }
            name = name[..<dash]
        }
        return nil
    }

    static func exists(_ path: String) -> Bool {
        access(path, R_OK) == 0
    }

    /// The players that are still running. Each call waits for the ones that
    /// ended, so that none of them stays a zombie for long. A program that
    /// ignores SIGCHLD, as the compositor does, has none to wait for.
    private static let players = Mutex<[pid_t]>([])

    /// The command that plays the sound of an event as the settings say, or
    /// nil when it is silence.
    public static func player(for sound: SystemSound,
                              settings: SoundSettings = SoundSettings.load(),
                              in directories: [String] = SoundTheme.directories()) -> [String]? {
        guard settings.enabled, settings.volume > 0,
              let path = file(for: sound, in: directories) else { return nil }
        var arguments = ["pw-play", "--media-role=Notification"]
        if settings.volume < 1 { arguments.append("--volume=\(settings.volume)") }
        arguments.append(path)
        return arguments
    }

    /// Starts `pw-play` with the file of the event, and does not wait for it.
    @discardableResult
    public static func play(_ sound: SystemSound) -> Bool {
        guard let arguments = player(for: sound) else { return false }
        return spawn(arguments)
    }

    /// A word that the shell reads as it is.
    static func quoted(_ word: String) -> String {
        "'" + word.replacing("'", with: "'\\''") + "'"
    }

    /// Starts a program and does not wait for it.
    @discardableResult
    static func spawn(_ arguments: [String]) -> Bool {
        players.withLock { pids in
            pids.removeAll { pid in
                var status: Int32 = 0
                return waitpid(pid, &status, WNOHANG) != 0
            }
        }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        // The player gets the signals as a program expects them: the
        // compositor blocks SIGTERM and ignores SIGCHLD, and neither belongs
        // to the player. These two flags have the same values on glibc and
        // on Darwin, and glibc does not give them to Swift.
        #if canImport(Glibc)
        var attributes = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #else
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        sigdelset(&defaulted, SIGKILL)
        sigdelset(&defaulted, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        let setSigDefault: Int16 = 0x04, setSigMask: Int16 = 0x08
        posix_spawnattr_setflags(&attributes, setSigDefault | setSigMask)

        // A machine with no PipeWire makes the player complain. That is not
        // a message for the log of the app.
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null",
                                             descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        var pid: pid_t = 0
        guard posix_spawnp(&pid, arguments[0], &actions, &attributes, argv, environ) == 0 else {
            return false
        }
        players.withLock { $0.append(pid) }
        return true
    }
}
