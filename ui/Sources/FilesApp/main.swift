// apus-files
//
// Files: the folders of this machine, and what is in them. It opens in the
// home folder; a folder opens in the same window, and Up goes back.
//
// The views and the keys are the Files module of the toolkit package, which
// the Mac tests. This program is what runs them on Apus: the window, and
// the disk that the list reads (Disk.swift).
//
//     apus-files            opens the home folder
//     apus-files PATH       opens another folder

import AppClient
import Files
import Glibc
import Toolkit

let arguments = CommandLine.arguments
let start = arguments.count > 1 ? arguments[1] : nil
let store = FilesStore(system: Disk(), path: start)
let window = AppWindow(title: "Files", appID: "org.apus.files")
store.changed = { window.setNeedsDraw() }

window.body = {
    window.sizeClass == .widget
        ? AnyView(FilesTile(store: store))
        : AnyView(FilesView(store: store, sizeClass: window.sizeClass,
                            height: window.size.height))
}

// A program or a terminal can change a folder while it is open, so the
// folder is read again every few seconds.
window.everySecond = {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    store.tick(now: Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000)
}

print("FILES-READY")
fflush(nil)
window.run()
