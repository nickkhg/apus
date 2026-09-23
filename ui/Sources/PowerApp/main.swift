// apus-power
//
// Power: where the power of this machine comes from, how much of the
// battery is left, and how many watts go out of it now. A VM on a Mac has
// no battery and no adapter, and Power says so and says why.
//
// The views and the reading of the kernel's files are the Power module of
// the toolkit package, which the Mac tests. This program is what runs them
// on Apus: the window, and the files of /sys/class/power_supply
// (Supplies.swift).

import AppClient
import Glibc
import Power
import Toolkit

// systemd-detect-virt is waited for, and a program that inherits an
// ignored SIGCHLD cannot wait. The compositor gives an app its signals back
// already (AppCatalog.resetSignals); a start by hand might not.
signal(SIGCHLD, SIG_DFL)

let store = PowerStore(source: Supplies())
let window = AppWindow(title: "Power", appID: "org.apus.power")
store.changed = { window.setNeedsDraw() }

window.body = {
    window.sizeClass == .widget
        ? AnyView(PowerTile(store: store))
        : AnyView(PowerView(store: store, sizeClass: window.sizeClass))
}

window.everySecond = {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    store.tick(now: Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000)
}

print("POWER-READY")
fflush(nil)
window.run()
