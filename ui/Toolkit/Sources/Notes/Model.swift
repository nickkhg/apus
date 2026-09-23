import Toolkit

// What Notes knows about the notes, and how it asks for them.
//
// A note is a plain file of text in one folder, ~/Notes. There is nothing
// else: no database, no file of the app beside them. So a note that a
// person writes with an editor in the terminal is a note in the app, and a
// note of the app is a file that every program can read.
//
// The views never read a file themselves. The app (ui/Sources/NotesApp)
// reads the folder, because only it runs on Apus: this module also builds
// on the Mac, where the tests give it a folder of their own.

public protocol NotesFolder: AnyObject {
    /// Where the notes are, as a person reads it: "~/Notes".
    var place: String { get }
    /// Makes the folder when it is not there. The words of a failure, or nil.
    func prepare() -> String?
    /// The notes in the folder: the files that end in .txt or .md.
    func list() -> [NoteFile]
    /// The text of a note, or nil when it cannot be read.
    func read(_ name: String) -> String?
    /// Writes a note in one step. A reader sees the old text or the new
    /// one, never a part of one.
    func write(_ name: String, _ text: String) -> Saved
    /// Takes a note away. The words of a failure, or nil.
    func remove(_ name: String) -> String?
}

/// A file of the folder.
public struct NoteFile: Sendable, Equatable {
    public var name: String
    /// When the file last changed, in seconds since 1970.
    public var modified: Double

    public init(name: String, modified: Double) {
        self.name = name
        self.modified = modified
    }
}

/// What came of a write.
public enum Saved: Sendable, Equatable {
    /// The time that the file has now.
    case saved(modified: Double)
    case failed(String)
}

/// A note, as the list shows it.
public struct Note: Sendable, Equatable {
    public var name: String
    public var modified: Double
    /// The first line of the text that has something in it.
    public var title: String
    /// The line after it, for the second line of the list.
    public var excerpt: String

    init(file: NoteFile, text: String) {
        name = file.name
        modified = file.modified
        (title, excerpt) = Note.heading(of: text)
    }

    /// The first two lines of a text that are not empty.
    static func heading(of text: String) -> (title: String, excerpt: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingSpaces }
            .filter { !$0.isEmpty }
            .makeIterator()
        let title = lines.next().map { String($0.prefix(80)) } ?? "New note"
        let excerpt = lines.next().map { String($0.prefix(120)) } ?? ""
        return (title, excerpt)
    }

    /// Whether a name is a note: a file of text that is not hidden.
    static func isNote(_ name: String) -> Bool {
        !name.hasPrefix(".") && (name.hasSuffix(".txt") || name.hasSuffix(".md"))
    }
}

extension Substring {
    /// The line without the spaces and the tabs at its ends. A heading of
    /// Markdown loses its marks too, so "# Plans" is "Plans".
    var trimmingSpaces: String {
        var line = self
        while let first = line.first, first == " " || first == "\t" || first == "#" {
            line = line.dropFirst()
        }
        while let last = line.last, last == " " || last == "\t" || last == "\r" {
            line = line.dropLast()
        }
        return String(line)
    }
}

/// How much a text holds, as the foot of the editor says it.
func count(of text: String) -> String {
    let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    let characters = text.count
    let w = words == 1 ? "1 word" : "\(words) words"
    let c = characters == 1 ? "1 character" : "\(characters) characters"
    return "\(w) · \(c)"
}
