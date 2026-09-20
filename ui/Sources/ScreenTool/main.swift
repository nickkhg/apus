// mydistro-screen: what a test on the Mac uses to see and to touch the
// screen of the guest.
//
//   mydistro-screen shot PATH            write the screen to PATH (a PPM)
//   mydistro-screen input [options]      move the pointer, click, type
//   mydistro-screen size                 print the size of the screen
//
// Options of `input`, in the order that they happen:
//   --pointer X,Y   put the pointer on this pixel
//   --click         press the left button and release it
//   --type TEXT     type the text ("\n" is the Enter key)
//
// Virtualization has no screenshot and no way to send input to a guest, as
// QEMU had with its monitor and QMP. So the guest does both itself: the
// compositor writes the pixels that it shows, and this program makes a
// pointer and a keyboard with uinput. The events therefore still go through
// evdev, libinput and xkbcommon, exactly as the events of a real keyboard
// and a real mouse do.

import CUinput
import Glibc

let socketPath = getenv("MYDISTRO_SCREENSHOT_SOCKET").map { String(cString: $0) }
    ?? "/run/mydistro-screenshot.sock"

func fail(_ message: String) -> Never {
    FileHandle.error("mydistro-screen: \(message)\n")
    exit(1)
}

enum FileHandle {
    static func error(_ text: String) {
        _ = text.withCString { write(2, $0, strlen($0)) }
    }
}

/// Sends one line to the compositor and gives the answer.
func ask(_ request: String) -> String {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    guard fd >= 0 else { fail("cannot make a socket") }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        socketPath.utf8.enumerated().forEach { raw[$0.offset] = $0.element }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let joined = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard joined == 0 else { fail("no compositor on \(socketPath) (errno \(errno))") }

    let line = request + "\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }

    var buffer = [UInt8](repeating: 0, count: 256)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { fail("the compositor said nothing") }
    var text = Array(buffer[0..<count])
    while let last = text.last, last == 0x0A || last == 0x0D { text.removeLast() }
    let answer = String(decoding: text, as: UTF8.self)
    guard answer.hasPrefix("ok ") else { fail(answer) }
    return answer
}

/// The size of the screen, from the compositor.
func screenSize() -> (width: Int, height: Int) {
    let parts = ask("size").split(separator: " ")
    guard parts.count == 3, let w = Int(parts[1]), let h = Int(parts[2]) else {
        fail("cannot read the size of the screen")
    }
    return (w, h)
}

// The evdev key of each character, and whether Shift is down. The tests type
// shell commands, so this covers the small letters, the digits and the
// punctuation that a command line needs.
let keys: [Character: (UInt16, Bool)] = {
    var table: [Character: (UInt16, Bool)] = [:]
    let rows: [(String, UInt16)] = [
        ("1234567890", 2), ("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44),
    ]
    for (letters, first) in rows {
        for (index, character) in letters.enumerated() {
            table[character] = (first + UInt16(index), false)
        }
    }
    for (character, key) in [("-", 12), ("=", 13), ("\t", 15), ("[", 26), ("]", 27),
                             ("\n", 28), (";", 39), ("'", 40), ("`", 41), ("\\", 43),
                             (",", 51), (".", 52), ("/", 53), (" ", 57)] {
        table[Character(character)] = (UInt16(key), false)
    }
    // With Shift: the capitals, and the second character of a key.
    for (character, plain) in [("A", "a"), ("B", "b"), ("C", "c"), ("D", "d"), ("E", "e"),
                               ("F", "f"), ("G", "g"), ("H", "h"), ("I", "i"), ("J", "j"),
                               ("K", "k"), ("L", "l"), ("M", "m"), ("N", "n"), ("O", "o"),
                               ("P", "p"), ("Q", "q"), ("R", "r"), ("S", "s"), ("T", "t"),
                               ("U", "u"), ("V", "v"), ("W", "w"), ("X", "x"), ("Y", "y"),
                               ("Z", "z"), ("_", "-"), ("+", "="), (":", ";"), ("\"", "'"),
                               ("~", "`"), ("|", "\\"), ("<", ","), (">", "."), ("?", "/"),
                               ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"),
                               ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"), (")", "0")] {
        if let key = table[Character(plain)]?.0 { table[Character(character)] = (key, true) }
    }
    return table
}()

let keyLeftShift: UInt16 = 42

/// Turns the two-character forms \n and \t into the characters they name,
/// so that a test can ask for the Enter key on a command line.
func unescape(_ text: String) -> String {
    var result = ""
    var escaped = false
    for character in text {
        if escaped {
            switch character {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            default: result.append("\\"); result.append(character)
            }
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else {
            result.append(character)
        }
    }
    if escaped { result.append("\\") }
    return result
}

/// A pointer and a keyboard, made with uinput and removed at the end.
final class Devices {
    let pointer: Int32
    let keyboard: Int32

    init() {
        pointer = mydistro_uinput_open()
        keyboard = mydistro_uinput_open()
        guard pointer >= 0, keyboard >= 0 else {
            fail("cannot open /dev/uinput (errno \(errno)); run as root")
        }
        guard mydistro_uinput_make_pointer(pointer) == 0 else { fail("cannot make the pointer") }
        guard mydistro_uinput_make_keyboard(keyboard) == 0 else { fail("cannot make the keyboard") }
        // udev must see the new devices and libinput must open them before
        // the first event, or the compositor never gets it.
        usleep(700_000)
    }

    deinit {
        mydistro_uinput_remove(pointer)
        mydistro_uinput_remove(keyboard)
        close(pointer)
        close(keyboard)
    }

    private func send(_ fd: Int32, _ type: UInt16, _ code: UInt16, _ value: Int32) {
        guard mydistro_uinput_send(fd, type, code, value) == 0 else { fail("cannot send an event") }
    }

    private func report(_ fd: Int32) {
        send(fd, mydistro_ev_syn, mydistro_syn_report, 0)
    }

    func move(toPixel x: Int, _ y: Int, on screen: (width: Int, height: Int)) {
        let scale = { (value: Int, size: Int) -> Int32 in
            Int32(max(0, min(Int(mydistro_abs_maximum),
                             value * Int(mydistro_abs_maximum) / max(1, size - 1))))
        }
        send(pointer, mydistro_ev_abs, mydistro_abs_x, scale(x, screen.width))
        send(pointer, mydistro_ev_abs, mydistro_abs_y, scale(y, screen.height))
        report(pointer)
        usleep(1_000_000)   // the compositor draws the next frame
    }

    func click() {
        send(pointer, mydistro_ev_key, mydistro_btn_left, 1)
        report(pointer)
        usleep(300_000)
        send(pointer, mydistro_ev_key, mydistro_btn_left, 0)
        report(pointer)
        usleep(1_000_000)
    }

    func type(_ text: String) {
        for character in text {
            guard let (code, shifted) = keys[character] else {
                fail("cannot type \(character)")
            }
            if shifted { send(keyboard, mydistro_ev_key, keyLeftShift, 1); report(keyboard) }
            send(keyboard, mydistro_ev_key, code, 1)
            report(keyboard)
            usleep(20_000)
            send(keyboard, mydistro_ev_key, code, 0)
            report(keyboard)
            if shifted { send(keyboard, mydistro_ev_key, keyLeftShift, 0); report(keyboard) }
            usleep(30_000)
        }
        usleep(1_500_000)   // the program answers and the compositor draws
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: mydistro-screen shot PATH | input [--pointer X,Y] [--click] [--type TEXT] | size")
}
arguments.removeFirst()

switch command {
case "size":
    let screen = screenSize()
    print("\(screen.width) \(screen.height)")

case "shot":
    guard let path = arguments.first else { fail("shot needs a file name") }
    print(ask(path))

case "input":
    var pointerAt: (Int, Int)?
    var clicking = false
    var text: String?
    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        switch option {
        case "--pointer":
            guard !arguments.isEmpty else { fail("--pointer needs X,Y") }
            let parts = arguments.removeFirst().split(separator: ",")
            guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else {
                fail("--pointer needs X,Y")
            }
            pointerAt = (x, y)
        case "--click":
            clicking = true
        case "--type":
            guard !arguments.isEmpty else { fail("--type needs text") }
            text = unescape(arguments.removeFirst())
        default:
            fail("\(option) is not an option")
        }
    }
    let screen = screenSize()
    let devices = Devices()
    if let (x, y) = pointerAt { devices.move(toPixel: x, y, on: screen); print("pointer at \(x),\(y)") }
    if clicking { devices.click(); print("clicked") }
    if let text { devices.type(text); print("typed \(text.debugDescription)") }

default:
    fail("\(command) is not a command")
}
