# Notes

`apus-notes` keeps short texts: a list for the day, a command to remember, a plan. Press Super, type `notes`, and press Enter.

A note is a plain file of text in `~/Notes` (`/root/Notes` while Apus runs everything as root). There is no database and no file of the app beside the notes. A note that you write with an editor in the terminal is a note in the app, and a note of the app is a file that every program can read, copy or keep in git.

A note is saved on every change. There is no Save, and nothing to lose when the window closes.

## The parts

| Part | Where | What it holds |
|---|---|---|
| The views | `ui/Toolkit/Sources/Notes/` | The list, the editor pane and the keys. The Mac tests them (`make test-ui`). |
| The editor | `ui/Toolkit/Sources/Toolkit/TextEditing.swift`, `TextEditor.swift` | The text, the caret, the selection, and the view that draws them. Any app can use them. See [toolkit.md](toolkit.md#text-that-a-person-types). |
| The app | `ui/Sources/NotesApp/` | The window, and `Folder`: what reads and writes `~/Notes`. |
| The bundle | `ui/Apps/Notes.app` | `org.apus.notes`, colour `F2C94C`. |

The views ask for the notes through the `NotesFolder` protocol. `Folder` is the one that runs on Apus. The tests give a folder of their own (`ui/Toolkit/Tests/NotesTests/Folder.swift`), which writes down every write.

## The files

| | |
|---|---|
| A note | A file of `~/Notes` whose name ends in `.txt` or `.md` and does not start with a dot. |
| The title in the list | The first line that has something in it. A `#` at its start, as in a Markdown heading, is left out. |
| The second line in the list | The next line that has something in it, or the name of the file. |
| The order | The note that changed last is first. |
| A new note | `Untitled.txt`, or `Untitled 2.txt` and on when that name is taken. The file keeps its name when its title changes. |
| A write | The text goes to a hidden file beside the note, which then takes the name of the note. A program that reads the note sees the old text or the new one, and never a part of one. |

The app makes `~/Notes` when it is not there. It reads the folder again every three seconds, so a note that a program writes there comes into the list. A note that changed on the disk comes into the editor too, unless the editor has the keys: then the person who is typing wins, and the next key writes their text over the other one.

A write that fails says so over the editor, and the head says NOT SAVED. The text stays on the screen, and the next key tries again.

## The keys

The toolkit has no focus, so Notes keeps its own: the list or the editor has the keys, and the accent marks the one that has them.

| Key | In the list | In the editor |
|---|---|---|
| Up, Down, Home, End | Open another note | Move the caret. Up and Down keep the column over a short line. |
| Enter, Right, Tab | Give the keys to the editor | Enter starts a new line |
| A letter | Give the keys to the editor, and write the letter | Write it |
| Delete, Backspace | Ask to remove the note. A second press within five seconds removes it. | Take away the character after or before the caret, or the selection |
| Shift with a move | | Select |
| Control or Alt with Left, Right | | Move by a word |
| Control with Home, End | | Go to the start or the end of the note |
| Control+A | | Select the whole note |
| Escape, Tab | Forget a Delete that asked | Give the keys back to the list |
| Control+N | Make a new note | Make a new note |

A click on a note opens it, and a click on the editor gives it the keys. The Delete button asks in the same way as the key.

## Three sizes

| Size class | What Notes draws |
|---|---|
| `large` | The list of 260 points, and the editor |
| `compact` | A list of 196 points, and less space around the editor |
| `widget` | A tile: the title of the open note, and its next seven lines |

## Limits

- The editor is the smallest one that a notes app needs. Its font is monospaced, and it has no styles. See [toolkit.md](toolkit.md#text-that-a-person-types) for what it cannot do: a click cannot place the caret, and Up and Down move by the lines of the text, not by the rows that a wrap makes.
- There is no copy and paste. An app of `AppClient` has no clipboard yet; the terminal has one of its own. See [clipboard.md](clipboard.md).
- There is no undo.
- A note cannot be renamed in the app. Its title is its first line, and its file keeps the name that it was made with. Rename the file in the terminal.
- A key does not repeat while it stays down, as in every app of Apus. See [next-steps.md](next-steps.md).
- There is no search, and no folder inside `~/Notes`.
