import Glibc

// The apps that come from packages.
//
// An app of Apus is a bundle in /Applications (AppCatalog.swift). Every
// other program on the machine comes from pacman, and pacman installs the
// desktop entry that the program ships: a file in /usr/share/applications
// that says what the program is called and how to start it.
//
//     /usr/share/applications/chromium.desktop
//         [Desktop Entry]
//         Type=Application
//         Name=Chromium
//         Exec=/usr/bin/chromium %U
//
// Summon lists those next to the bundles, so `pacman -S chromium` is enough
// to put Chromium in the list. The format is the freedesktop.org Desktop
// Entry Specification; this reads the part of it that starting a program
// needs. See docs/applications.md.

enum DesktopEntries {
    /// Where the desktop entries are, in the order that the specification
    /// gives them: the ones of this user first, then the ones of the system.
    /// A file that a later directory repeats is the same app, and the first
    /// one wins.
    static func directories() -> [String] {
        var result: [String] = []
        if let home = value(of: "XDG_DATA_HOME"), !home.isEmpty {
            result.append("\(home)/applications")
        } else if let home = value(of: "HOME"), !home.isEmpty {
            result.append("\(home)/.local/share/applications")
        }
        let shared = value(of: "XDG_DATA_DIRS").flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/local/share:/usr/share"
        result += shared.split(separator: ":").map { "\($0)/applications" }
        return result
    }

    /// The apps of these directories, as bundles. A file that says nothing
    /// useful, or that names a program which is not there, is left out.
    static func apps(in directories: [String]) -> [AppBundle] {
        var found: [AppBundle] = []
        var taken = Set<String>()
        for directory in directories {
            for name in files(in: directory) where name.hasSuffix(".desktop") {
                let id = String(name.dropLast(".desktop".count))
                guard taken.insert(id).inserted else { continue }
                if let app = read(entryAt: "\(directory)/\(name)", id: id) {
                    found.append(app)
                }
            }
        }
        return found
    }

    /// One desktop entry, or nothing when it is not an app that Apus can
    /// start.
    static func read(entryAt path: String, id: String) -> AppBundle? {
        guard let text = AppCatalog.contents(of: path) else { return nil }
        let settings = group("Desktop Entry", of: text)
        // Only a program, only one that wants to be listed, and only one
        // that does not need a terminal to run in: Apus has no way to give
        // a program a terminal to start in.
        guard settings["Type"] == "Application",
              !isTrue(settings["NoDisplay"]), !isTrue(settings["Hidden"]),
              !isTrue(settings["Terminal"]),
              let name = settings["Name"], !name.isEmpty else { return nil }
        // TryExec names the program that says whether the app is installed,
        // for an entry that is shipped separately from what it starts.
        if let tryExec = settings["TryExec"], !tryExec.isEmpty, resolve(tryExec) == nil {
            return nil
        }
        let arguments = command(settings["Exec"])
        guard let program = arguments.first.flatMap(resolve) else { return nil }
        return AppBundle(id: id, name: name, color: color(for: id),
                         arguments: [program] + arguments.dropFirst())
    }

    /// The keys of one group of the file. A desktop entry is groups of
    /// "key=value" lines, each under a "[name]" heading, and everything this
    /// needs is in the first group.
    ///
    /// A key can carry a language, as in `Name[de]`. Apus has one language,
    /// so those are left out and the plain key stands.
    static func group(_ wanted: String, of text: String) -> [String: String] {
        var settings: [String: String] = [:]
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let statement = line.trimmed
            if statement.hasPrefix("[") {
                inside = statement == "[\(wanted)]"
                continue
            }
            guard inside, !statement.hasPrefix("#"),
                  let separator = statement.firstIndex(of: "=") else { continue }
            let key = statement[..<separator].trimmed
            guard !key.isEmpty, !key.contains("[") else { continue }
            settings[key] = statement[statement.index(after: separator)...].trimmed
        }
        return settings
    }

    /// The words of an `Exec` line.
    ///
    /// A value can quote a word that holds a space, and it can carry the
    /// field codes of the specification — `%u` for a address to open, `%f`
    /// for a file, and so on. Apus starts an app with nothing to open, so a
    /// field code stands for nothing and goes. `%%` is one per cent sign.
    static func command(_ exec: String?) -> [String] {
        guard let exec else { return [] }
        var words: [String] = []
        var word = ""
        var quoted = false
        var escaped = false
        var wasQuoted = false
        for character in exec {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                wasQuoted = true
            } else if character == " ", !quoted {
                if !word.isEmpty || wasQuoted { words.append(word) }
                word = ""
                wasQuoted = false
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty || wasQuoted { words.append(word) }
        return words.compactMap(withoutFieldCodes).filter { !$0.isEmpty }
    }

    /// One word of an `Exec` line without its field codes.
    private static func withoutFieldCodes(_ word: String) -> String? {
        guard word.contains("%") else { return word }
        var result = ""
        let characters = Array(word)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%", index + 1 < characters.count else {
                result.append(characters[index])
                index += 1
                continue
            }
            let code = characters[index + 1]
            if code == "%" { result.append("%") }
            index += 2
        }
        return result
    }

    /// The program that a word names: the word itself when it is a path, or
    /// the first program of that name in PATH.
    static func resolve(_ program: String) -> String? {
        guard !program.isEmpty else { return nil }
        if program.contains("/") {
            return access(program, X_OK) == 0 ? program : nil
        }
        let path = value(of: "PATH") ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(program)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    /// A colour for an app that has no colour of its own.
    ///
    /// A desktop entry names an icon of a theme, which Apus does not draw,
    /// so the tile of the app is a colour. It comes from the id, so that an
    /// app keeps its colour from one boot to the next, and it is of the
    /// family that the design uses: bright enough to read on the dark
    /// background, and not fully saturated.
    static func color(for id: String) -> UInt32 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325              // FNV-1a
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return rgb(hue: Double(hash % 360), saturation: 0.52, value: 0.78)
    }

    /// A colour of the wheel as 0xRRGGBB.
    private static func rgb(hue: Double, saturation: Double, value: Double) -> UInt32 {
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

    /// "true" and nothing else is true, as the specification says.
    private static func isTrue(_ value: String?) -> Bool { value == "true" }

    private static func value(of name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    /// The names in a directory. A directory that is not there is empty.
    private static func files(in directory: String) -> [String] {
        guard let handle = opendir(directory) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let record = readdir(handle) {
            var entry = record.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) { String(cString: $0) }
            }
            names.append(name)
        }
        return names.sorted()
    }
}

private extension StringProtocol {
    /// The text without the spaces and tabs at its ends.
    var trimmed: String {
        String(drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
