// The files of the system, as text in and values out.
//
// Every function here takes the text of a file rather than its path, so that
// the reading of a file and the understanding of it are two things, and the
// Mac can test the second.

public enum Parse {
    // MARK: - key=value files

    /// A file of `KEY=value` lines, such as /etc/os-release. A value may be
    /// in double or single quotes. A line that starts with `#` is a comment.
    public static func assignments(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let line = trimmed(line)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = trimmed(line[..<equals])
            let value = unquoted(trimmed(line[line.index(after: equals)...]))
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    // MARK: - The settings of the shell

    /// The file that Settings writes for the shell: a drop-in of
    /// apus-shell.service that sets its environment.
    public static let dropInDirectory = "/etc/systemd/system/apus-shell.service.d"
    public static let dropInPath = dropInDirectory + "/50-settings.conf"

    /// The variables of the environment that the lines of a unit file set.
    /// `Environment=A=1 "B=two words"` sets two.
    public static func unitEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let line = trimmed(line)
            guard line.hasPrefix("Environment=") else { continue }
            for word in words(line.dropFirst("Environment=".count)) {
                guard let equals = word.firstIndex(of: "=") else { continue }
                result[String(word[..<equals])] = String(word[word.index(after: equals)...])
            }
        }
        return result
    }

    /// The settings that an environment holds. A variable that is not
    /// there, or that has a value the shell does not read, is the default.
    public static func shellSettings(_ environment: [String: String]) -> ShellSettings {
        var settings = ShellSettings()
        settings.renderer = ShellSettings.Renderer(rawValue: environment["APUS_RENDERER"] ?? "")
            ?? .cpu
        settings.look = ShellSettings.Look(rawValue: environment["APUS_SHELL_MODE"] ?? "")
            ?? .automatic
        if let text = environment["APUS_SCALE"], let scale = Double(text), scale > 0 {
            settings.scale = scale
        }
        settings.layout = environment["XKB_DEFAULT_LAYOUT"] ?? ""
        settings.variant = environment["XKB_DEFAULT_VARIANT"] ?? ""
        settings.options = (environment["XKB_DEFAULT_OPTIONS"] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return settings
    }

    /// The drop-in for these settings. A setting at its default is left
    /// out, so that the shell decides it as it would with no file.
    public static func dropIn(for settings: ShellSettings) -> String {
        var lines = [
            "# Written by Settings (apus-settings). The shell reads its environment",
            "# when it starts, so a change here needs a new start of apus-shell.service.",
            "[Service]",
        ]
        func set(_ name: String, _ value: String) {
            lines.append("Environment=\(name)=\(value)")
        }
        if settings.renderer != .cpu { set("APUS_RENDERER", settings.renderer.rawValue) }
        if settings.look != .automatic { set("APUS_SHELL_MODE", settings.look.rawValue) }
        if let scale = settings.scale { set("APUS_SCALE", number(scale)) }
        if !settings.layout.isEmpty { set("XKB_DEFAULT_LAYOUT", settings.layout) }
        if !settings.variant.isEmpty { set("XKB_DEFAULT_VARIANT", settings.variant) }
        if !settings.options.isEmpty {
            set("XKB_DEFAULT_OPTIONS", settings.options.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 2 as "2", and 1.5 as "1.5".
    static func number(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : tenths(value)
    }

    // MARK: - Time zones

    /// The zones of zone1970.tab: one line for each zone, with the
    /// countries, the place, the name and a comment, split by tabs. UTC is
    /// not a place, so it comes first on its own.
    public static func timeZones(_ text: String) -> [TimeZoneEntry] {
        var zones: [TimeZoneEntry] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            zones.append(TimeZoneEntry(id: String(columns[2]),
                                       countries: columns[0].split(separator: ",").map(String.init)))
        }
        return [TimeZoneEntry(id: "UTC")] + zones.sorted { $0.id < $1.id }
    }

    /// The zone that /etc/localtime points at. The link is relative or
    /// absolute, and it goes through a directory called zoneinfo.
    public static func zone(fromLink target: String) -> String? {
        guard let range = target.firstRange(of: "zoneinfo/") else { return nil }
        let zone = String(target[range.upperBound...])
        return zone.isEmpty ? nil : zone
    }

    /// Does the query pick this zone? Every word of it must be somewhere in
    /// the name, as Summon matches.
    static func matches(_ zone: TimeZoneEntry, query: String) -> Bool {
        let text = (zone.id.replacing("_", with: " ").replacing("/", with: " ") + " "
            + zone.countries.joined(separator: " ")).lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { text.contains($0) }
    }

    // MARK: - Accounts

    /// What the line of root in /etc/shadow says about its password.
    public static func password(inShadow text: String) -> PasswordState {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("root:") })
        else { return .unknown }
        let fields = line.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count > 1 else { return .unknown }
        let hash = fields[1]
        if hash.isEmpty { return .none }
        if hash.hasPrefix("!") || hash.hasPrefix("*") { return .locked }
        return .set
    }

    /// Why a host name cannot be used, or nil when it can. A host name is a
    /// label of DNS: letters, digits and hyphens, and no hyphen at an end.
    public static func problem(withHostName name: String) -> String? {
        if name.isEmpty { return "A name needs at least one character" }
        if name.utf8.count > 63 { return "A name has 63 characters at most" }
        let allowed = name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-"
        }
        if !allowed { return "Use only letters, digits and hyphens" }
        if name.hasPrefix("-") || name.hasSuffix("-") { return "A name cannot start or end with a hyphen" }
        return nil
    }

    // MARK: - The network

    /// The name servers that a resolv.conf names. systemd-resolved writes
    /// the ones that it uses in /run/systemd/resolve/resolv.conf.
    public static func nameServers(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            return words.count >= 2 && words[0] == "nameserver" ? String(words[1]) : nil
        }
    }

    /// The default gateway of each interface, from /proc/net/route. The
    /// numbers there are hexadecimal, in the byte order of the machine,
    /// which is little-endian on aarch64.
    public static func gateways(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard columns.count >= 3, columns[1] == "00000000",
                  let value = UInt32(columns[2], radix: 16), value != 0 else { continue }
            let bytes = [value & 0xFF, value >> 8 & 0xFF, value >> 16 & 0xFF, value >> 24]
            result[String(columns[0])] = bytes.map { "\($0)" }.joined(separator: ".")
        }
        return result
    }

    // MARK: - Apps

    /// The group "[Desktop Entry]" of a desktop entry.
    public static func desktopEntry(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var inGroup = false
        for line in text.split(separator: "\n") {
            let line = trimmed(line)
            if line.hasPrefix("[") {
                inGroup = line == "[Desktop Entry]"
                continue
            }
            guard inGroup, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = trimmed(line[..<equals])
            // A key with a locale, such as Name[de], is not the key itself.
            guard !key.contains("[") else { continue }
            result[key] = trimmed(line[line.index(after: equals)...])
        }
        return result
    }

    /// The first line of a desktop entry that Settings writes to hide an
    /// app. A file that starts with it is one that Settings may take away.
    public static let hiddenMarker = "# Hidden by Settings. Remove this file to show the app again."

    /// A desktop entry that hides the app of `text` from Summon: the same
    /// entry, with NoDisplay set.
    public static func hiding(_ text: String) -> String {
        var lines = [hiddenMarker]
        var inGroup = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let clean = trimmed(line)
            if clean.hasPrefix("[") {
                inGroup = clean == "[Desktop Entry]"
                lines.append(String(line))
                if inGroup { lines.append("NoDisplay=true") }
                continue
            }
            if inGroup, clean.hasPrefix("NoDisplay") && !clean.hasPrefix("NoDisplay[") { continue }
            lines.append(String(line))
        }
        return lines.joined(separator: "\n")
    }

    /// The program of an Exec line, without its arguments.
    public static func program(ofExec exec: String) -> String {
        words(Substring(exec)).first.map(String.init) ?? exec
    }

    /// "RRGGBB" as a colour.
    public static func colour(_ text: String?) -> UInt32? {
        guard let text, text.count == 6 else { return nil }
        return UInt32(text, radix: 16)
    }

    // MARK: - Screens

    /// The first mode of a connector in /sys/class/drm, which is the one
    /// that the screen prefers: "1280x800".
    public static func preferredMode(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? ""
    }

    // MARK: - Words

    /// The words of a line, where a word in double quotes may hold spaces.
    static func words(_ text: Substring) -> [Substring] {
        var result: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " || text[index] == "\t" {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            if text[index] == "\"" {
                let start = text.index(after: index)
                let end = text[start...].firstIndex(of: "\"") ?? text.endIndex
                result.append(text[start..<end])
                index = end < text.endIndex ? text.index(after: end) : end
            } else {
                let end = text[index...].firstIndex { $0 == " " || $0 == "\t" } ?? text.endIndex
                result.append(text[index..<end])
                index = end
            }
        }
        return result
    }

    static func trimmed(_ text: some StringProtocol) -> String {
        let characters = Array(text)
        var start = 0, end = characters.count
        while start < end, characters[start] == " " || characters[start] == "\t" || characters[start] == "\r" {
            start += 1
        }
        while end > start, characters[end - 1] == " " || characters[end - 1] == "\t"
            || characters[end - 1] == "\r" {
            end -= 1
        }
        return String(characters[start..<end])
    }

    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last,
              first == "\"" || first == "'" else { return text }
        return String(text.dropFirst().dropLast())
    }
}

/// The layouts of the keys that Settings offers. xkb has many more; these
/// are the ones that most people look for.
public struct KeyboardLayout: Identifiable, Sendable, Equatable {
    public let layout: String
    public let variant: String
    public let name: String

    public var id: String { variant.isEmpty ? layout : "\(layout)(\(variant))" }

    public static let all: [KeyboardLayout] = [
        .init(layout: "us", variant: "", name: "English (US)"),
        .init(layout: "us", variant: "intl", name: "English (US, international)"),
        .init(layout: "us", variant: "dvorak", name: "English (Dvorak)"),
        .init(layout: "us", variant: "colemak", name: "English (Colemak)"),
        .init(layout: "gb", variant: "", name: "English (UK)"),
        .init(layout: "ie", variant: "", name: "Irish"),
        .init(layout: "de", variant: "", name: "German"),
        .init(layout: "at", variant: "", name: "German (Austria)"),
        .init(layout: "ch", variant: "", name: "German (Switzerland)"),
        .init(layout: "ch", variant: "fr", name: "French (Switzerland)"),
        .init(layout: "fr", variant: "", name: "French"),
        .init(layout: "be", variant: "", name: "Belgian"),
        .init(layout: "ca", variant: "", name: "French (Canada)"),
        .init(layout: "nl", variant: "", name: "Dutch"),
        .init(layout: "es", variant: "", name: "Spanish"),
        .init(layout: "latam", variant: "", name: "Spanish (Latin American)"),
        .init(layout: "pt", variant: "", name: "Portuguese"),
        .init(layout: "br", variant: "", name: "Portuguese (Brazil)"),
        .init(layout: "it", variant: "", name: "Italian"),
        .init(layout: "se", variant: "", name: "Swedish"),
        .init(layout: "no", variant: "", name: "Norwegian"),
        .init(layout: "dk", variant: "", name: "Danish"),
        .init(layout: "fi", variant: "", name: "Finnish"),
        .init(layout: "is", variant: "", name: "Icelandic"),
        .init(layout: "pl", variant: "", name: "Polish"),
        .init(layout: "cz", variant: "", name: "Czech"),
        .init(layout: "sk", variant: "", name: "Slovak"),
        .init(layout: "hu", variant: "", name: "Hungarian"),
        .init(layout: "ro", variant: "", name: "Romanian"),
        .init(layout: "tr", variant: "", name: "Turkish"),
        .init(layout: "gr", variant: "", name: "Greek"),
        .init(layout: "ru", variant: "", name: "Russian"),
        .init(layout: "ua", variant: "", name: "Ukrainian"),
        .init(layout: "il", variant: "", name: "Hebrew"),
        .init(layout: "ara", variant: "", name: "Arabic"),
        .init(layout: "jp", variant: "", name: "Japanese"),
        .init(layout: "kr", variant: "", name: "Korean"),
    ]

    /// The entry for these settings. No layout at all is what xkb gives by
    /// default, which is the first one.
    static func matching(_ settings: ShellSettings) -> KeyboardLayout? {
        let layout = settings.layout.isEmpty ? "us" : settings.layout
        return all.first { $0.layout == layout && $0.variant == settings.variant }
    }
}

extension Parse {
    /// The colour of an app that has none of its own: the one that Summon
    /// gives it, worked out from its id in the same way as
    /// DesktopEntries.color(for:) in the compositor.
    public static func colour(forID id: String) -> UInt32 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325              // FNV-1a
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        let hue = Double(hash % 360), saturation = 0.52, value = 0.78
        let sector = hue / 60
        let chroma = value * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        let base = value - chroma
        func byte(_ part: Double) -> UInt32 { UInt32(((part + base) * 255).rounded()) & 0xFF }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
