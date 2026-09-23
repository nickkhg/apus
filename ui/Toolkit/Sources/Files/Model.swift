import Toolkit

// What Files knows about a folder, and how it asks for one.
//
// The views read a list of entries, and they never open a folder
// themselves. The app (ui/Sources/FilesApp) reads the folders of the system,
// because only it runs on Apus: this module also builds on the Mac, where
// the tests give it a disk of their own.

/// What the app can ask of the disk.
public protocol FileSystem: AnyObject {
    /// The folder of the person: $HOME, which is /root on Apus now.
    var home: String { get }
    /// What is in a folder, or why it cannot be read.
    func list(_ path: String) -> Listing
    /// Whether a folder is there, for the places in the sidebar.
    func isFolder(_ path: String) -> Bool
}

/// The answer of `FileSystem.list`.
public enum Listing: Sendable, Equatable {
    case entries([FileEntry])
    /// The words to show: "You may not read /root".
    case failed(String)
}

/// One thing in a folder.
public struct FileEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case folder
        case file
        /// A file that the machine can run.
        case program
        /// A device, a socket or a pipe: a name in a folder that holds no
        /// bytes of its own.
        case special
        /// A link that points nowhere.
        case brokenLink
    }

    public var name: String
    public var kind: Kind
    /// Bytes, for a file. A folder has none that a person means.
    public var size: UInt64
    /// The entry is a symbolic link. `kind` is what it points to.
    public var isLink: Bool

    public init(name: String, kind: Kind, size: UInt64 = 0, isLink: Bool = false) {
        self.name = name
        self.kind = kind
        self.size = size
        self.isLink = isLink
    }

    /// A name that starts with a dot is hidden, as in every Unix.
    public var isHidden: Bool { name.hasPrefix(".") }

    /// What the entry is, in the words of the Kind column.
    public var kindText: String {
        let what: String = switch kind {
        case .folder: "Folder"
        case .program: "Program"
        case .special: "Special file"
        case .brokenLink: "Broken link"
        case .file: FileEntry.kind(ofExtension: fileExtension)
        }
        return isLink && kind != .brokenLink ? "Link to \(what.lowercasedFirst)" : what
    }

    /// The part of the name after its last dot, in small letters, or empty.
    /// A name that starts with its only dot (".bashrc") has none.
    public var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// The size as the Size column shows it. A folder shows none.
    public var sizeText: String {
        switch kind {
        case .file, .program: FileEntry.size(size)
        default: "—"
        }
    }

    /// The kind of a file, from the end of its name. The machine does not
    /// open the file to find out: a list of a large folder must stay fast.
    static func kind(ofExtension ext: String) -> String {
        switch ext {
        case "": "File"
        case "txt", "text", "log": "Text"
        case "md", "markdown": "Markdown text"
        case "swift": "Swift source"
        case "c", "h", "cpp", "hpp", "cc", "m": "C source"
        case "py": "Python script"
        case "sh", "bash", "zsh": "Shell script"
        case "json": "JSON"
        case "xml", "plist": "XML"
        case "conf", "cfg", "ini", "toml", "yaml", "yml": "Settings"
        case "html", "htm", "css", "js": "Web page"
        case "png", "jpg", "jpeg", "gif", "webp", "ppm", "bmp", "svg": "Image"
        case "pdf": "PDF document"
        case "mp3", "ogg", "flac", "wav", "m4a": "Sound"
        case "mp4", "mkv", "mov", "webm", "avi": "Video"
        case "tar", "gz", "tgz", "xz", "zst", "bz2", "zip", "7z": "Archive"
        case "so", "a", "dylib": "Library"
        case "ttf", "otf", "woff", "woff2": "Font"
        case "img", "iso", "raw": "Disk image"
        default: "\(ext.uppercased()) file"
        }
    }

    /// A size in bytes as a person reads it: "812 bytes", "4.1 KB", "38 MB".
    public static func size(_ bytes: UInt64) -> String {
        if bytes == 1 { return "1 byte" }
        if bytes < 1024 { return "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if value >= 10 { return "\(Int(value.rounded())) \(units[unit])" }
        let tenths = Int((value * 10).rounded())
        // 9.96 rounds to 10.0, which reads better as 10.
        if tenths >= 100 { return "10 \(units[unit])" }
        return "\(tenths / 10).\(tenths % 10) \(units[unit])"
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// The order of a folder: the folders first, then the rest, each by name
/// with no difference between capitals and small letters.
func sorted(_ entries: [FileEntry]) -> [FileEntry] {
    entries.sorted { a, b in
        let aFolder = a.kind == .folder
        let bFolder = b.kind == .folder
        if aFolder != bFolder { return aFolder }
        let (x, y) = (a.name.lowercased(), b.name.lowercased())
        return x == y ? a.name < b.name : x < y
    }
}

/// A place in the sidebar: a folder that a person goes to often.
public struct Place: Sendable, Equatable {
    public var title: String
    public var path: String
    public var mark: Color
}

/// The paths of the system, as strings. There is no Foundation here.
enum Paths {
    /// The folder that holds `path`. The top of the tree holds itself.
    static func parent(of path: String) -> String {
        let trimmed = normal(path)
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return "/" }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    /// A name inside a folder.
    static func join(_ folder: String, _ name: String) -> String {
        normal(folder) == "/" ? "/" + name : normal(folder) + "/" + name
    }

    /// The last name of a path, or "/" for the top.
    static func name(of path: String) -> String {
        let trimmed = normal(path)
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return "/" }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// A path with no slash at its end and no empty names in it.
    static func normal(_ path: String) -> String {
        let names = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + names.joined(separator: "/")
    }

    /// The folders from the top down to `path`, for the bar over the list.
    /// A path in the home folder starts at the home folder, as a person
    /// thinks of it, and not at "/".
    static func trail(of path: String, home: String) -> [(title: String, path: String)] {
        let path = normal(path)
        let home = normal(home)
        var trail: [(title: String, path: String)]
        var rest: Substring
        if home != "/", path == home || path.hasPrefix(home + "/") {
            trail = [("Home", home)]
            rest = path.dropFirst(home.count)
        } else {
            trail = [("Computer", "/")]
            rest = Substring(path)
        }
        var current = trail[0].path
        for name in rest.split(separator: "/") {
            current = join(current, String(name))
            trail.append((String(name), current))
        }
        return trail
    }
}
