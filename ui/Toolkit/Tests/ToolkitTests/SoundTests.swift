import Testing
@testable import Toolkit
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// The lookup of the freedesktop sound theme specification, in a directory of
// the test's own. Nothing here plays a sound.

@Suite("The sounds of the system")
struct SoundTests {
    /// A directory of sound themes, with empty files where the test puts them.
    final class Themes {
        let root: String
        /// What the test made, in the order it made it.
        private var made: [String] = []

        init(_ files: [String]) {
            var template = Array("/tmp/apus-sounds-XXXXXX".utf8CString)
            root = String(cString: mkdtemp(&template)!)
            for file in files {
                var path = root
                for part in file.split(separator: "/").dropLast() {
                    path += "/\(part)"
                    if mkdir(path, 0o755) == 0 { made.append(path) }
                }
                fclose(fopen("\(root)/\(file)", "w"))
                made.append("\(root)/\(file)")
            }
        }

        deinit {
            // A directory is made before what is in it, so it goes after.
            for path in made.reversed() { remove(path) }
            rmdir(root)
        }
    }

    @Test("A sound of the theme is its file")
    func found() {
        let themes = Themes(["apus/stereo/bell.oga"])
        #expect(SoundTheme.file(for: .bell, in: [themes.root]) == "\(themes.root)/apus/stereo/bell.oga")
    }

    @Test("A name that the theme lacks falls back to a shorter name")
    func shorter() {
        let themes = Themes(["apus/stereo/bell.oga"])
        #expect(SoundTheme.file(for: .bellTerminal, in: [themes.root]) == "\(themes.root)/apus/stereo/bell.oga")
    }

    @Test("The longer name wins when both are there")
    func longer() {
        let themes = Themes(["apus/stereo/bell.oga", "apus/stereo/bell-terminal.wav"])
        #expect(SoundTheme.file(for: .bellTerminal, in: [themes.root])
            == "\(themes.root)/apus/stereo/bell-terminal.wav")
    }

    @Test("The first directory wins, so a person's own file replaces the system's")
    func order() {
        let home = Themes(["apus/stereo/bell.wav"])
        let system = Themes(["apus/stereo/bell.oga"])
        #expect(SoundTheme.file(for: .bell, in: [home.root, system.root]) == "\(home.root)/apus/stereo/bell.wav")
    }

    @Test("A disabled file is silence, even with a sound behind it")
    func disabled() {
        let home = Themes(["apus/stereo/bell.disabled"])
        let system = Themes(["apus/stereo/bell.oga"])
        #expect(SoundTheme.file(for: .bell, in: [home.root, system.root]) == nil)
    }

    @Test("The freedesktop theme comes after the theme")
    func fallback() {
        let themes = Themes(["freedesktop/stereo/complete.oga", "apus/stereo/bell.oga"])
        #expect(SoundTheme.file(for: SystemSound(rawValue: "complete"), in: [themes.root])
            == "\(themes.root)/freedesktop/stereo/complete.oga")
    }

    @Test("An event with no file anywhere is silence")
    func silence() {
        let themes = Themes(["apus/stereo/bell.oga"])
        #expect(SoundTheme.file(for: SystemSound(rawValue: "window-new"), in: [themes.root]) == nil)
    }
}
