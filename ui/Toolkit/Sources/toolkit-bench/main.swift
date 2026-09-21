// toolkit-bench: how long one frame of the shell takes.
//
//   swift run -c release --package-path ui/Toolkit toolkit-bench
//
// It draws the shell into memory, so it needs no screen. The numbers are for
// the Mac; mydistro in a VM is slower.

import Foundation
import Render
import Shell
import Toolkit

let width = 1280
let height = 800
let screen = Rect(x: 0, y: 0, width: width, height: height)
let rounds = Int(ProcessInfo.processInfo.environment["ROUNDS"] ?? "") ?? 200

func measure(_ name: String, _ body: () -> Void) {
    body()   // warm up
    let start = Date()
    for _ in 0..<rounds { body() }
    let each = Date().timeIntervalSince(start) / Double(rounds) * 1000
    print(String(format: "%-28s %7.3f ms", (name as NSString).utf8String!, each))
}

// The same shell as on the screen: three apps, and two open windows.
let state = ShellState(
    apps: [
        AppEntry(id: "org.mydistro.files", name: "Files", color: Color(hex: 0x4C8DF6)),
        AppEntry(id: "org.mydistro.terminal", name: "Terminal", color: Color(hex: 0x3BB273)),
        AppEntry(id: "org.mydistro.settings", name: "Settings", color: Color(hex: 0xE0A458)),
    ],
    windows: [
        WindowEntry(id: "1", title: "Hello from Swift", appID: "org.mydistro.terminal",
                    place: .principal, hasFocus: true),
        WindowEntry(id: "2", title: "Files", appID: "org.mydistro.files", place: .widget),
    ],
    clock: Clock(hour: "14", minute: "05", weekday: "TUE"))
let host = ViewHost()
let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
let canvas = Canvas(pixels: pixels, width: width, height: height, stride: width)

var list = host.displayList(for: RootView(state: state), in: screen)
print("display list: \(list.count) items")

measure("lay out and lower") {
    list = host.displayList(for: RootView(state: state), in: screen)
}
measure("draw the items") {
    SoftwareRenderer.render(list, into: canvas)
}
measure("background fill only") {
    SoftwareRenderer.render([.fill(screen, color: 0xFF2B2340)], into: canvas)
}

// What depth costs the CPU. The shell asks for these three in GPU mode
// only, and this is why: each one is dearer than the surface it is for.
let surface = Rect(x: 320, y: 120, width: 640, height: 520)
var outline = Path()
outline.addRoundedRectangle(x: Double(surface.x), y: Double(surface.y),
                            width: Double(surface.width), height: Double(surface.height),
                            radius: 20)
let full: DisplayList = [.fill(screen, color: 0xFF2B2340)]
measure("a surface: fill") {
    SoftwareRenderer.render(full + [.path(outline, color: 0xFF12161A)], into: canvas)
}
measure("a surface: gradient") {
    SoftwareRenderer.render(full + [.gradient(outline, Gradient(
        from: 0xFF12161A, to: 0xFF0E1114,
        startX: Double(surface.y), startY: Double(surface.y),
        endX: Double(surface.x), endY: Double(surface.y + surface.height)))], into: canvas)
}
measure("a surface: shadow") {
    SoftwareRenderer.render(full + [.shadow(outline, Shadow(color: 0x8C000000,
                                                            radius: 28, dy: 10))],
                            into: canvas)
}
measure("a surface: blur") {
    SoftwareRenderer.render(full + [.blur(outline, radius: 20)], into: canvas)
}
// What one frame of a move costs. Summon opening in GPU mode is the
// heaviest frame the shell has: it has the blur, and a move draws it again
// for every frame until it arrives.
let open = ShellState(apps: state.apps, windows: state.windows,
                      clock: state.clock, mode: .gpu, summonIsOpen: true,
                      canvas: RootView.windowArea(screen: screen))
let openHost = ViewHost()
var openList = openHost.displayList(for: RootView(state: open), in: screen)
print("--- Summon open in GPU mode: \(openList.count) items")
measure("summon: lay out and lower") {
    openList = openHost.displayList(for: RootView(state: open), in: screen)
}
measure("summon: draw the items") {
    SoftwareRenderer.render(openList, into: canvas)
}

// Which item costs what.
print("--- each item")
for (index, item) in list.enumerated() {
    let name: String
    switch item {
    case .fill(let rect, _): name = "\(index) fill \(rect.width)x\(rect.height)"
    case .bitmap(let bitmap, _, _): name = "\(index) bitmap \(bitmap.width)x\(bitmap.height)"
    case .pushClip(let rect): name = "\(index) clip \(rect.width)x\(rect.height)"
    case .popClip: name = "\(index) clip ends"
    case .shadow(_, let shadow): name = "\(index) shadow, radius \(Int(shadow.radius))"
    case .blur(_, let radius): name = "\(index) blur, radius \(Int(radius))"
    case .gradient: name = "\(index) gradient"
    case .path(let path, _):
        var xs: [Double] = [], ys: [Double] = []
        for element in path.elements {
            switch element {
            case .move(let x, let y), .line(let x, let y): xs.append(x); ys.append(y)
            case .quadratic(_, _, let x, let y): xs.append(x); ys.append(y)
            case .cubic(_, _, _, _, let x, let y): xs.append(x); ys.append(y)
            case .close: break
            }
        }
        let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
        name = "\(index) path \(Int(w))x\(Int(h)) at \(Int(xs.min() ?? 0)),\(Int(ys.min() ?? 0))"
    }
    measure(name) { SoftwareRenderer.render([item], into: canvas) }
}

// Is the cost the edges or the pixels? Same area, different edge counts.
print("--- 192x64 shapes")
var plain = Path()
plain.addRectangle(x: 500, y: 700, width: 192, height: 64)
var rounded = Path()
rounded.addRoundedRectangle(x: 500, y: 700, width: 192, height: 64, radius: 18)
var thin = Path()
thin.addRoundedRectangle(x: 500, y: 700, width: 192, height: 64, radius: 2)
measure("rectangle path (4 edges)") { SoftwareRenderer.render([.path(plain, color: 0xFF804020)], into: canvas) }
measure("rounded, radius 18") { SoftwareRenderer.render([.path(rounded, color: 0xFF804020)], into: canvas) }
measure("rounded, radius 2") { SoftwareRenderer.render([.path(thin, color: 0xFF804020)], into: canvas) }

measure("whole frame") {
    let items = host.displayList(for: RootView(state: state), in: screen)
    SoftwareRenderer.render(items, into: canvas)
}
