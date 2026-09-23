# Files

`apus-files` shows the folders of the machine and what is in them. Press Super, type `files`, and press Enter. It opens in the home folder, which is `/root` while Apus runs everything as root.

A folder opens in the same window. The list shows the name, the kind and the size of each thing in the folder, with the folders first. The bar over the list has a button for each folder on the way to this one, and Up.

## The parts

| Part | Where | What it holds |
|---|---|---|
| The views | `ui/Toolkit/Sources/Files/` | The list, the places, the keys, the kinds and the sizes. The Mac tests them (`make test-ui`). |
| The app | `ui/Sources/FilesApp/` | The window, and `Disk`: what reads a folder with `opendir`, `lstat` and `stat`. |
| The bundle | `ui/Apps/Files.app` | `org.apus.files`, colour `E0A458`. |

The views read a list of `FileEntry` values, and they ask for a folder through the `FileSystem` protocol. `Disk` is the one that runs on Apus. The tests give a disk of their own (`ui/Toolkit/Tests/FilesTests/Disk.swift`), with a folder of 3000 names and a folder that may not be read.

`apus-files PATH` opens another folder.

## What the columns say

| Column | Where it comes from |
|---|---|
| Name | `readdir`. A name that starts with a dot is hidden until you ask for it. |
| Kind | A folder, a program (a file that someone may run), a special file (a device, a socket or a pipe), a broken link, or the kind of a file from the end of its name: `.txt` is Text, `.swift` is Swift source, `.tar.zst` is Archive. A link says what it points to: "Link to folder". Files does not open a file to find its kind, so that a large folder lists at once. |
| Size | `st_size`, in bytes, KB, MB or GB of 1024. A folder has no size here: the size of what is in it needs a walk of the whole tree. |

The folder is read again every two seconds, because a program or a terminal can change it while the window is open. The selection stays on the same name.

## The places

The sidebar has Home, Notes (`~/Notes`, where the Notes app keeps its notes), Applications, Temporary (`/tmp`) and Computer (`/`). A place that is not a folder on this machine is left out. A narrow window has no sidebar; the bar over the list does the same work.

## The keys and the pointer

| Key | What it does |
|---|---|
| Up, Down, Home, End | Move in the list |
| A letter or a digit | Go to the next name that starts with it |
| Enter, Right | Open the selected folder |
| Backspace, Left | Go up. The folder that you came from is selected. |
| `~`, `/` | Go to the home folder, or to the top |
| `.`, Control+H | Show or hide the hidden files |
| Escape | Take the notice away |

A click selects a line, and a click on the line that is selected opens it. The toolkit tells a view about a click, and not about two clicks in a row, so there is no double click.

## Three sizes

| Size class | What Files draws |
|---|---|
| `large` | The places, and the list with its three columns |
| `compact` | The list, with a narrower Kind column |
| `widget` | A tile: the name of the folder, how much is in it, and its first five names |

## Limits

- **A file does not open yet.** Enter on a file says so in a notice, and names the Terminal. An app of Apus cannot ask the compositor to start another app with a file, and a bundle does not say which kinds of file its app can open. Both are needed first.
- Files cannot copy, move, rename or remove anything, and it cannot make a folder.
- A folder of thousands of names lists at once, but the list is read again every two seconds, so a folder such as `/usr/lib` costs a `stat` of each name that often.
- The list has one order: the folders first, then by name. It has no search.
