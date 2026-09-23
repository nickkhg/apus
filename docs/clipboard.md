# The clipboard

One app copies, another pastes, and the same text is on the clipboard of the
Mac that runs the VM.

```
   Chromium ──┐                                         ┌── the Mac
              ├─ wl_data_device ─ apus-compositor ─ AF_VSOCK ─ apus-vm
   Terminal ──┘                                         └── NSPasteboard
```

## Between the apps

Wayland's answer is `wl_data_device_manager`, and
`ui/Sources/Compositor/Clipboard.swift` is the compositor's side of it.

1. The app that copies makes a `wl_data_source`, names the types it can give
   the text as, and calls `set_selection`.
2. The compositor tells the app that has the keyboard: it makes a
   `wl_data_offer`, lists the same types on it, and sends `selection`.
3. The app that pastes opens a pipe and calls `receive` with a type and one
   end of it. The compositor passes that end to the app that copied, which
   writes the text into it.

The text does not go through the compositor. The two apps share a pipe, so a
selection of any size, and of any type, costs the compositor nothing.

The clipboard follows the keyboard, as the protocol says: only the app whose
window has the keys is told what is on it.

## With the Mac

Wayland has no answer for this, because the Mac is not one of the apps of the
display server. So the compositor and `apus-vm` talk over a socket of the
virtual machine:

- `AF_VSOCK` needs no network and no addresses. The host is always CID 2, and
  `apus-vm` listens on port 1024 with a `VZVirtioSocketListener`.
- A message is four bytes of length, most significant first, then that many
  bytes of UTF-8. Nothing else goes over the socket, in either direction.
- The guest connects, because it is the side that knows when it is ready. It
  tries again every five seconds until it gets through, so the order in which
  the two start does not matter.
- Neither side sends back what it has just been told, or the two would answer
  each other for ever.

On real hardware there is no socket to connect to. The compositor says so once
in the journal and the apps go on sharing a clipboard between themselves.

`apus-vm` reads `NSPasteboard.general.changeCount` every 400 ms, because AppKit
has no notification for a change of the pasteboard.

### Neither side may wait

Both ends of the socket sit on a thread that has other work to do, and both
sides look the same when that thread stops.

- In the guest, the event loop of the compositor draws the screen. A read or
  a write that waited would stop the screen.
- On the Mac, the main queue draws the window of the guest and delivers its
  keys and its pointer. A read or a write that waited there would stop the
  guest being drawn and stop it answering, which looks exactly like a guest
  that has hung — and the only way out is to force quit the machine.

So both ends set the socket not to wait, and neither trusts what it was
given: `VZVirtioSocketConnection` does not say whether its file descriptor
waits, so `apus-vm` sets `O_NONBLOCK` on it before reading a byte. What does
not fit in the socket is kept, and a write source says when there is room.

The pipes between the apps are the same: the compositor never waits on one.

### Only text goes to the Mac

Between two apps of Apus, a copy of any type works: the compositor passes the
pipe through without looking at what goes down it. What crosses to the Mac is
plain text only. When an app copies, the compositor also asks it for
`text/plain;charset=utf-8` and keeps that copy for the Mac; an app that offers
no text type keeps its data to itself.

## In the terminal

| | |
|---|---|
| Drag with the left button | Select |
| `Ctrl+Shift+C` | Copy |
| `Ctrl+Shift+V` | Paste |
| `Shift+Page Up` / `Shift+Page Down` | Scroll back half a window |

`Ctrl+C` cannot be copy in a terminal: it is the byte that stops a program.
So copy and paste are the chords that a terminal uses, and the terminal reads
them before the key becomes bytes, because xkbcommon makes the same byte for
`Ctrl+C` and for `Ctrl+Shift+C`.

A selection is kept in the line numbers of `Screen.scrolledLines`, which never
repeat. The lines under it move — the program prints, the view scrolls — and
the selection stays on the words it was made on. The spaces that fill out a
line to the width of the window are not part of the text: a grid is always as
wide as the window, and a line ends where its text does.

A paste is written to the shell as if it had been typed. There is no bracketed
paste, so a paste of several lines runs all but the last.
