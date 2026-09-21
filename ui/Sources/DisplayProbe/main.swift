// apus-display-probe [--hold SECONDS] [--write PATH]
//
// Takes over the screen, draws a test pattern (a white square on Apus
// purple), holds it, then gives the screen back. Must run as root, or as
// the owner of the seat, with no other program using the display.
//
// --write puts the pattern in a file, as a PPM. tests/display.exp checks
// that file: no compositor runs during this test, so the probe itself must
// write the picture.

import DRMKit
import Glibc

let background: UInt32 = 0x965ADC   // matches ANSI_COLOR in os-release
let foreground: UInt32 = 0xFFFFFF

var holdSeconds: UInt32 = 5
var picturePath: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--hold":
        guard let value = arguments.popFirst().flatMap(UInt32.init) else {
            print("usage: apus-display-probe [--hold SECONDS] [--write PATH]")
            exit(2)
        }
        holdSeconds = value
    case "--write":
        guard let value = arguments.popFirst() else {
            print("usage: apus-display-probe [--hold SECONDS] [--write PATH]")
            exit(2)
        }
        picturePath = value
    default:
        print("usage: apus-display-probe [--hold SECONDS] [--write PATH]")
        exit(2)
    }
}

do {
    let device = try DRMDevice.firstWithOutput()
    let output = try device.connectedOutputs()[0]
    print("display: \(device.path), output \(output)")

    let (w, h) = (output.mode.width, output.mode.height)
    let framebuffer = try DumbFramebuffer(device: device, width: w, height: h)
    framebuffer.fill(color: background)
    framebuffer.fill(x: w / 4, y: h / 4, width: w / 2, height: h / 2, color: foreground)

    let screen = try device.show(framebuffer, on: output)
    if let picturePath {
        try framebuffer.writePPM(to: picturePath)
        print("PROBE-PICTURE \(picturePath)")
    }
    print("PROBE-READY \(w)x\(h)")
    sleep(holdSeconds)
    screen.restore()
    print("PROBE-DONE")
} catch {
    print("apus-display-probe: \(error)")
    exit(1)
}
