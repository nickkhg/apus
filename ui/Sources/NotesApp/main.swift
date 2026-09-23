// apus-notes
//
// Notes: short texts, kept as plain files in ~/Notes. A note is saved on
// every change, so there is no Save to forget, and a note is a file that
// every other program can read.
//
// The list, the editor and the keys are the Notes module of the toolkit
// package, which the Mac tests. This program is what runs them on Apus: the
// window, and the folder that the notes are in (Folder.swift).

import AppClient
import Glibc
import Notes
import Toolkit

let store = NotesStore(folder: Folder())
let window = AppWindow(title: "Notes", appID: "org.apus.notes")
store.changed = { window.setNeedsDraw() }

window.body = {
    window.sizeClass == .widget
        ? AnyView(NotesTile(store: store))
        : AnyView(NotesView(store: store, sizeClass: window.sizeClass))
}

// A note can come from the terminal, or change there, so the folder is read
// again every few seconds.
window.everySecond = {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    store.tick(now: Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000)
}

print("NOTES-READY")
fflush(nil)
window.run()
