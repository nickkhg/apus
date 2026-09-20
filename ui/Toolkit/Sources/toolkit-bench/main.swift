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

let state = ShellState(windowTitles: ["Hello from Swift"], clock: "14:05")
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
    SoftwareRenderer.render([.fill(screen, color: 0x2B2340)], into: canvas)
}
// Which item costs what.
print("--- each item")
for (index, item) in list.enumerated() {
    let name: String
    switch item {
    case .fill(let rect, _): name = "\(index) fill \(rect.width)x\(rect.height)"
    case .bitmap(let bitmap, _, _): name = "\(index) bitmap \(bitmap.width)x\(bitmap.height)"
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
