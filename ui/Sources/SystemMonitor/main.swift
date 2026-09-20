// mydistro-system
//
// The system monitor: what this machine is doing now. It is the second app
// written with the toolkit, and the first one written with AppClient, so it
// is also the proof that an app needs no Wayland code of its own.
//
// It has two user interfaces. In a tile of 256 points it keeps the one
// number that a person wants from the corner of an eye. In a window with
// room it says more.

import AppClient
import Glibc
import Toolkit

let window = AppWindow(title: "System", appID: "org.mydistro.system")
var reader = SystemReader()
var readings = reader.read()

window.body = {
    window.sizeClass == .widget
        ? AnyMonitor(MonitorTile(readings: readings))
        : AnyMonitor(MonitorWindow(readings: readings))
}

/// Holds either user interface, because `body` gives one type.
struct AnyMonitor: View {
    public typealias Body = Never
    let content: any View

    init(_ content: any View) {
        self.content = content
    }

    func makeNodes(into nodes: inout [LayoutNode], environment: EnvironmentValues) {
        content.makeNodes(into: &nodes, environment: environment)
    }
}

// The numbers are read again every second. The window wakes up often
// enough to carry a move, so it calls this without a timer of its own. The
// first reading of the processor has nothing to compare with, so the second
// one is the first that says anything.
window.everySecond = {
    readings = reader.read()
    window.setNeedsDraw()
}

print("SYSTEM-MONITOR-READY")
fflush(nil)
window.run()
