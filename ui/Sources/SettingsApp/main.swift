// apus-settings
//
// Settings: the name of this machine, its clock, the password of root, the
// screen, the keys, the network, the apps that Summon lists, and the power.
//
// The panes and the keys are the Settings module of the toolkit package,
// which the Mac tests. This program is what runs them on Apus: the window,
// and the machine that the panes read and change (Machine.swift).
//
//     apus-settings                 opens on About
//     apus-settings --pane time     opens on another pane

import AppClient
import Glibc
import Settings
import Toolkit

// The programs that Settings runs wait for their children, and a program
// that inherits an ignored SIGCHLD cannot. The compositor gives an app its
// signals back already (AppCatalog.resetSignals); a start by hand might not.
signal(SIGCHLD, SIG_DFL)

let store = SettingsStore(system: Machine())
let window = AppWindow(title: "Settings", appID: "org.apus.settings")
store.changed = { window.setNeedsDraw() }

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--pane"), index + 1 < arguments.count {
    guard let pane = Pane(rawValue: arguments[index + 1]) else {
        fail("apus-settings: no pane '\(arguments[index + 1])'; the panes are "
            + Pane.allCases.map(\.rawValue).joined(separator: ", "))
    }
    store.select(pane)
}

window.body = {
    window.sizeClass == .widget
        ? AnyView(SettingsTile(store: store))
        : AnyView(SettingsView(store: store, sizeClass: window.sizeClass,
                               height: window.size.height))
}

// The clock is read every second, and the rest of the machine every few,
// because a cable, a time server or pacman can change it while the window
// is open.
window.everySecond = {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    store.tick(now: Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000)
}

print("SETTINGS-READY")
fflush(nil)
window.run()
