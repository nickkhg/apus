@testable import Notes
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Render
import Toolkit

/// A folder of notes for the tests, in memory. It writes down every write,
/// and its clock moves one second for each.
final class Folder: NotesFolder {
    var files: [String: (text: String, modified: Double)] = [
        "Shopping.txt": ("Shopping\nMilk\nEggs\nBread", 100),
        "Plans.md": ("# Plans for the week\n\nFinish the notes app\nCall the bank", 200),
        ".hidden.txt": ("not a note", 300),
        "picture.png": ("not a note either", 400),
    ]
    var writes: [String] = []
    var failWrites = false
    var clock = 1000.0

    var place: String { "~/Notes" }

    func prepare() -> String? { nil }

    func list() -> [NoteFile] {
        files.map { NoteFile(name: $0.key, modified: $0.value.modified) }
    }

    func read(_ name: String) -> String? { files[name]?.text }

    func write(_ name: String, _ text: String) -> Saved {
        if failWrites { return .failed("~/Notes/\(name) cannot be written") }
        clock += 1
        files[name] = (text, clock)
        writes.append(name)
        return .saved(modified: clock)
    }

    func remove(_ name: String) -> String? {
        files[name] = nil
        return nil
    }
}

extension KeyEvent {
    static let up = KeyEvent(keysym: 0xFF52)
    static let down = KeyEvent(keysym: 0xFF54)
    static let enter = KeyEvent(keysym: 0xFF0D)
    static let escape = KeyEvent(keysym: 0xFF1B)
    static let backspace = KeyEvent(keysym: 0xFF08)
    static let delete = KeyEvent(keysym: 0xFFFF)
    static let end = KeyEvent(keysym: 0xFF57)
    static let newNote = KeyEvent(keysym: 0x6E, control: true)
    static let selectAll = KeyEvent(keysym: 0x61, control: true)
    static let shiftUp = KeyEvent(keysym: 0xFF52, shift: true)
}

extension NotesStore {
    func type(_ text: String) {
        for character in text {
            key(character == "\n" ? .enter : KeyEvent(keysym: 0x61, characters: String(character)))
        }
    }
}

/// Draws a view into pixels. When APUS_PREVIEWS names a folder, the
/// picture is also written there as a PPM. See docs/toolkit.md#tests.
@discardableResult
func preview(_ view: some View, width: Int, height: Int, name: String) -> [UInt32] {
    let list = ViewRenderer.displayList(for: view, in: Rect(x: 0, y: 0, width: width, height: height))
    var pixels = [UInt32](repeating: 0xFF000000, count: width * height)
    pixels.withUnsafeMutableBufferPointer { memory in
        SoftwareRenderer.render(list, into: Canvas(pixels: memory.baseAddress!, width: width,
                                                   height: height, stride: width))
    }
    if let folder = getenv("APUS_PREVIEWS").map({ String(cString: $0) }),
       let file = fopen("\(folder)/\(name).ppm", "wb") {
        defer { fclose(file) }
        let head = Array("P6\n\(width) \(height)\n255\n".utf8)
        fwrite(head, 1, head.count, file)
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 3)
        for pixel in pixels {
            bytes += [UInt8((pixel >> 16) & 0xFF), UInt8((pixel >> 8) & 0xFF), UInt8(pixel & 0xFF)]
        }
        fwrite(bytes, 1, bytes.count, file)
    }
    return pixels
}
