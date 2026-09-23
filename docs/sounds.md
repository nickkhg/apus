# Sounds

Apus has 14 system sounds. They are a freedesktop sound theme in `/usr/share/sounds/apus`, and the `apus-sounds` package installs them.

No sound is a recording. `packages/apus-sounds/generate.swift` makes each one from numbers. Thus:

- The licence is clear. The sounds are code of this repository, under the Apache License 2.0 (see [licensing.md](licensing.md)). No sample library has a say.
- Each build makes the same files, byte for byte.
- To change a sound, change a line of Swift.

## The principles

1. **A sound is never the only signal.** Each event that has a sound also shows text or a colour. A person who turns the sound off loses a cue and nothing more. This is the rule of the notices, where a colour never carries the meaning alone ([toolkit.md](toolkit.md#notices)).
2. **Few sounds.** A sound is for an event that a person did not cause and wants to know about, such as a message or a low battery. It is also for an action that has no picture, such as a volume key or a screenshot. An action that a person does and sees, such as a window that opens, has no sound.
3. **One key.** The tuning is equal temperament with A4 at 440 Hz. Every note comes from the D major pentatonic scale: D, E, F#, A, B. Two sounds that play together therefore agree.
4. **One voice.** Every note is the same struck tone: two-operator FM with the modulator at the pitch of the carrier, and a quiet partial at 2.76 times the pitch (the first overtone of a bar). The FM index falls faster than the level, so the note gets darker as it dies. A "tick" is the same tone, short. Only the screenshot adds a second voice: noise through a band-pass filter.
5. **Short.** 11 of the 14 sounds are 325 ms or shorter, and 9 are shorter than 300 ms. Each length includes 5 ms of silence at the start. The three long ones are the login (1 s), the logout (0.6 s) and the low battery (0.47 s). The login plays once in a session. The low battery must not go unheard.
6. **The direction has a meaning.** A sound goes up when something arrives or starts: a message, a device, the charger, the login. It goes down when something goes, fails or runs low: a device that goes, the charger that goes, the logout, a failure, the battery. It stays on one note when it only asks for attention: a warning.
7. **It matches the design.** The shell is dark and quiet, with one accent colour, and it moves in 120 ms to 260 ms (`Animation.quick`, `.surface`, `.window` and `.arrive` in `Theme.swift`). The sounds are soft, and a sound ends in about the time that its move takes. The card of a notice arrives with `.arrive` (260 ms), and a message is 285 ms. The notes of the login are 70 ms apart, which is a step of the motion and not a tune.
8. **One loudness.** Each sound has a level against one reference, and the generator sets its gain to that level. No sound clips.

## The loudness

The reference is **-20 LUFS**. The measure is the loudness of ITU-R BS.1770 (the K filter), at its largest value in a window of 400 ms (the "momentary" loudness). The integrated loudness of the standard needs several blocks of 400 ms, and most of these sounds are shorter than one block. The momentary loudness of a short sound takes the energy of the whole sound. The ear also adds up the energy of a short sound over about 200 ms, so the measure is a fair model of what a person hears.

A sound at level 0 is at -20 LUFS, and a sound at level -6 is at -26 LUFS. -20 LUFS is below speech and music (a stream is often near -14 to -16 LUFS), so a sound does not jump out over what a person listens to.

The peak ceiling is -3 dBFS before the encoder and -1 dBFS after it. The encoder can make a peak a little higher than the one that it gets. The highest peak is -5.7 dBFS after the encoder. ffmpeg's `ebur128` filter measures a true peak (with oversampling) of -5.1 dBTP or lower before the encoder.

## The events

The level is in LU against -20 LUFS. The length includes the 5 ms of silence at the start.

| Event ID | When it plays | Length | Level | What it is | Why |
|---|---|---|---|---|---|
| `desktop-login` | The session starts: the first frame of the shell | 1005 ms | -2 | D5, F#5, A5, D6 up, 70 ms apart, over a soft D4 | It plays once. It says "ready", so it can take a moment. It is 2 LU down, because a person hears it on a quiet machine. |
| `desktop-logout` | Power off, restart, or the shell stops | 605 ms | -3 | A5, F#5, D5 down, over D4 | The login, down and shorter. A person who asked to stop is waiting. |
| `message-new-instant` | An app posts a notice to a person | 285 ms | 0 | A5, then D6: up a fifth | The reference sound. A message asks for a look. |
| `dialog-information` | A notice of the system of kind `information` | 225 ms | -3 | One F#5 | It asks for nothing, so it is one note and softer than a message. |
| `dialog-warning` | A notice of kind `warning` | 305 ms | 0 | E5 twice | Not up and not down: something is not right, and the system carries on. |
| `dialog-error` | A notice of kind `failure` | 325 ms | 0 | D5, then A4: down a fourth, darker | A failure must be clear, not a fright. It is lower, not louder. |
| `bell` | The terminal bell (the terminal asks for `bell-terminal`, and the lookup falls back to `bell`) | 155 ms | -6 | One short B5 | A program can ring it many times in a second. It must be soft. |
| `audio-volume-change` | Each step of a volume key, at the new volume | 75 ms | -6 | A tick on D6 | A key that repeats plays it about ten times in a second. It plays at the new volume, so the person hears the volume that they chose. |
| `screen-capture` | A screenshot that a person asked for | 205 ms | -4 | Two ticks (F#6, A6) with a breath of noise | A shutter that opens and closes. The screenshot has no other signal at the moment it happens. |
| `device-added` | A device arrives after the session started | 205 ms | -4 | Ticks F#5, B5: up | It confirms what the person did with a hand. |
| `device-removed` | That device goes | 205 ms | -4 | Ticks B5, F#5: down | The mirror of `device-added`. |
| `power-plug` | The charger connects | 265 ms | -4 | D5 slides up to A5 | A level that fills. |
| `power-unplug` | The charger disconnects | 265 ms | -4 | A5 slides down to D5 | The mirror of `power-plug`. |
| `battery-low` | The charge goes below the low level while it discharges, once | 465 ms | -1 | B5 to E5 (down a fourth), twice | The only sound that repeats itself. A person must not miss it, and it comes once. |

### The events with no sound

The theme has no file for these, and it inherits no other theme. The spec makes `freedesktop` the last theme of every lookup, and the image does not have that theme. So a request for one of them plays nothing.

| Event | Why there is no sound |
|---|---|
| `window-new`, `window-close`, and the other `window-*` events | The person opened the window and sees it. The canvas moves already (`Animation.window`), and a sound would say the same thing a second time. There is no sound that is off by default: a sound that nobody hears is not worth a file. |
| `button-pressed`, `button-toggle-on`, `item-selected`, `menu-*` | A control answers the pointer with a picture in 120 ms (`.quick`). A click sound on each control is noise. |
| Summon that opens or closes | The same reason. The spec has no name for it. |
| `dialog-question` | Settings asks for a second click to power off. The text of the button asks, and the person is looking at it. |
| `complete`, `message-new-email`, `phone-*`, `camera-shutter`, `trash-empty` | Apus has no app for these. |
| `desktop-screen-lock`, `suspend-*`, `system-bootup`, `system-shutdown` | Apus has no lock and no suspend. The login marks the start, and the logout marks the end. |
| `network-connectivity-*` | The network of a VM is always there. A sound for it tells nobody anything. |
| `battery-caution`, `battery-full` | One warning for the battery is enough. A full battery needs nothing from the person. |
| `audio-channel-*`, `audio-test-signal` | Settings has no sound pane yet. |

## The files

```
/usr/share/sounds/apus/
├── index.theme              Name=Apus, Directories=stereo, no Inherits
└── stereo/
    ├── audio-volume-change.oga
    ├── battery-low.oga
    ├── bell.oga
    └── ...                  one Ogg Vorbis file for each event, 48 kHz, mono
/etc/xdg/gtk-3.0/settings.ini   gtk-sound-theme-name=apus
```

The directory is `stereo` because the spec calls the default output profile `stereo`. The files are mono. libsndfile and PipeWire play a mono file on both channels. The 14 files are 116 KB together.

`settings.ini` makes `apus` the theme of a GTK 3 app that plays event sounds through libcanberra. The image has no such app now. The toolkit of Apus does not read the file: it uses the theme `apus`.

## Make the sounds again

On the Mac:

```sh
make sounds                      # out/sounds/*.wav, then the check
afplay out/sounds/message-new-instant.wav
```

The build of the image does the same in the builder container. The `PKGBUILD` of `packages/apus-sounds`:

1. compiles `generate.swift` and `check.swift` with `swiftc`,
2. writes the WAV files and `levels.tsv` (the target loudness and the length of each sound),
3. encodes each WAV file with `oggenc --quality 6` and a fixed serial number (oggenc takes a random one otherwise, and the files would differ from build to build),
4. in `check()`, checks the WAV files, decodes the `.oga` files with `oggdec`, and checks them again with the looser limits for a lossy file.

`build/build.sh` installs `vorbis-tools` for step 3. The image does not need it.

To change a sound, change its line in the `sounds` list of `generate.swift`, run `make sounds`, and listen. Then increase `pkgrel` in the `PKGBUILD`. A note has these values:

| Value | Meaning |
|---|---|
| `pitch`, `to`, `glide` | The note, and a second note that it slides to over `glide` seconds |
| `at` | When it starts, in seconds from the start of the sound |
| `attack` | The rise, in seconds. It is never zero: a note that starts at full level is a click. |
| `decay` | The time constant of the fall, in seconds |
| `bright` | The FM index at the strike. 0 is a sine. |
| `glass` | The level of the partial at 2.76 times the pitch |
| `gain` | The level of the note against the other notes of the sound |

A sound has an `id`, a `level` in LU, a `length`, and a `fade` at its end. The generator stops with a message if a new sound would go above the ceiling. Then lower its level.

The two programs share no code, so a mistake in one is not the same mistake in the other.

## The check

A build cannot listen, so `check.swift` measures. For each file:

| Check | WAV | After Vorbis |
|---|---|---|
| Sample rate and channels | 48 kHz, mono | 48 kHz, mono |
| Length | Exactly the length in `levels.tsv` | The same |
| Sample peak | -3 dBFS or lower | -1 dBFS or lower |
| Loudness | Within 0.1 LU of the target | Within 1 LU |
| DC offset | -80 dBFS or lower | The same |
| First and last sample | 1 LSB or less (a step at an edge is a click) | -60 dBFS (33 LSB) or less |
| The first 2 ms | 40 dB under the peak: the sound rises, it does not step | The same |
| The last 5 ms | 40 dB under the peak: the fade happened | The same |
| The onset | Within 8 ms: a sound that is late does not belong to its cause | The same |

The numbers of the files that the build makes (`check` prints these tables):

| Sound | Length | Peak | RMS | Loudness | DC | Last 5 ms | Peak after Vorbis | Loudness after Vorbis | First, last after Vorbis |
|---|---|---|---|---|---|---|---|---|---|
| `audio-volume-change` | 75 ms | -5.9 dBFS | -18.6 dBFS | -26.0 LUFS | -155 dBFS | -61.9 dB | -5.7 dBFS | -26.0 LUFS | 0, 1 LSB |
| `battery-low` | 465 ms | -10.4 dBFS | -21.3 dBFS | -21.0 LUFS | -154 dBFS | -64.7 dB | -10.3 dBFS | -20.9 LUFS | 0, 0 LSB |
| `bell` | 155 ms | -8.9 dBFS | -21.6 dBFS | -26.0 LUFS | -144 dBFS | -65.7 dB | -8.6 dBFS | -26.0 LUFS | 0, 0 LSB |
| `desktop-login` | 1005 ms | -11.1 dBFS | -24.7 dBFS | -22.0 LUFS | -150 dBFS | silent | -11.1 dBFS | -21.9 LUFS | 0, 0 LSB |
| `desktop-logout` | 605 ms | -12.8 dBFS | -24.0 dBFS | -23.0 LUFS | -157 dBFS | silent | -12.7 dBFS | -22.9 LUFS | 0, 0 LSB |
| `device-added` | 205 ms | -9.0 dBFS | -20.9 dBFS | -24.0 LUFS | -144 dBFS | -66.4 dB | -9.0 dBFS | -24.0 LUFS | 0, 0 LSB |
| `device-removed` | 205 ms | -9.1 dBFS | -20.8 dBFS | -24.0 LUFS | -150 dBFS | -65.7 dB | -9.2 dBFS | -24.0 LUFS | 0, 1 LSB |
| `dialog-error` | 325 ms | -8.1 dBFS | -18.2 dBFS | -20.0 LUFS | -151 dBFS | -62.7 dB | -8.0 dBFS | -19.9 LUFS | 0, 0 LSB |
| `dialog-information` | 225 ms | -8.1 dBFS | -19.8 dBFS | -23.0 LUFS | -145 dBFS | -69.0 dB | -8.1 dBFS | -22.9 LUFS | 0, 0 LSB |
| `dialog-warning` | 305 ms | -7.0 dBFS | -18.2 dBFS | -20.0 LUFS | -153 dBFS | -64.3 dB | -7.1 dBFS | -19.9 LUFS | 0, 0 LSB |
| `message-new-instant` | 285 ms | -7.0 dBFS | -18.7 dBFS | -20.0 LUFS | 0 | -60.7 dB | -7.1 dBFS | -20.0 LUFS | 0, 3 LSB |
| `power-plug` | 265 ms | -9.9 dBFS | -21.5 dBFS | -24.0 LUFS | -137 dBFS | -69.8 dB | -9.9 dBFS | -24.0 LUFS | 0, 0 LSB |
| `power-unplug` | 265 ms | -10.0 dBFS | -21.6 dBFS | -24.0 LUFS | -145 dBFS | -70.1 dB | -9.7 dBFS | -24.0 LUFS | 0, 0 LSB |
| `screen-capture` | 205 ms | -6.1 dBFS | -22.6 dBFS | -24.0 LUFS | -147 dBFS | -78.9 dB | -6.0 dBFS | -24.1 LUFS | 0, 1 LSB |

The RMS is the RMS of the part that sounds: from the onset to the last sample within 40 dB of the peak. "Silent" means that the last 5 ms are all zero. The first and last sample of every WAV file are 0. After Vorbis the DC offset of every file is -94 dBFS or lower.

Other checks, done once by hand:

- The loudness of `check` agrees with ffmpeg's `ebur128` filter (a separate implementation of BS.1770) to 0.1 LU for all 14 sounds.
- Two builds in the builder container gave the same `.oga` files, byte for byte. The WAV files from the Mac and from the builder are the same, byte for byte.
- A spectrogram of the sounds (ffmpeg `showspectrumpic`) shows what the parameters say: a fundamental, a few harmonics that die before it, and the glass partial that dies first. Above 6 kHz a note is 60 dB or more under its peak. The noise of the screenshot goes higher, and it is 30 dB or more under the peak there.
- libsndfile (which `pw-play` uses) reads the `.oga` files as 48 kHz mono with the right number of frames.

5 ms of silence starts each sound. Vorbis spreads an attack a few milliseconds back in time (pre-echo). Without the silence, that spread started at the first sample, and the first sample of a decoded file was up to 106 LSB (-50 dBFS). With it, the first sample is 0.

What the check cannot tell: how the sounds sound. Nobody listened to them before this commit. Listen with `make sounds`, on speakers and on headphones, before you trust the levels between the sounds.

## Play a sound

From Swift, with the toolkit:

```swift
import Toolkit

playSound(.messageNewInstant)
playSound(.bellTerminal)          // the theme answers with bell.oga
playSound(SystemSound(rawValue: "window-new"))   // no file: nothing plays
```

`playSound` returns at once. It does these steps:

1. It finds the file as the spec says: `$XDG_DATA_HOME/sounds` (or `~/.local/share/sounds`), then the `sounds` directory in each directory of `$XDG_DATA_DIRS`; the theme `apus`, then `freedesktop`; the full name, then the name without its last part (`bell-terminal`, then `bell`); `.oga`, `.ogg`, `.wav`. A file `<name>.disabled` stops the lookup with silence. So a person can replace a sound, or turn one off, in the home directory.
2. It starts `pw-play --media-role=Notification <file>`, with the standard input and output on `/dev/null` and the signals at their defaults (the compositor blocks some, and they do not belong to the player).
3. It does not wait. The next call collects the players that ended. A program that ignores SIGCHLD, as the compositor does, has none to collect.

The toolkit links no audio library, so it builds on the Mac and in the builder with none. A machine with no `pw-play` plays nothing, and nothing fails. `ui/Toolkit/Tests/ToolkitTests/SoundTests.swift` tests the lookup on the Mac and on Linux.

From a shell:

```sh
pw-play --media-role=Notification /usr/share/sounds/apus/stereo/bell.oga
canberra-gtk-play -i bell         # needs libcanberra and GTK 3, which the image does not have
```

`pw-play` is in the `pipewire-audio` package. `canberra-gtk-play` reads the theme from GTK, and `settings.ini` gives it `apus`. A program that uses libcanberra without GTK must set the property `canberra.xdg-theme.name` to `apus`.

The role `Notification` lets WirePlumber give event sounds a volume of their own, and lower music under them, when a policy for that exists.

### Rules for a caller

- Play a sound for an event, not for a state. The battery is low once, when it crosses the level, not on each reading.
- Do not play two sounds for one event. A notice of kind `failure` plays `dialog-error` only, not `message-new-instant` as well.
- Limit a sound that a program can repeat. The terminal bell: at most one in 100 ms.
- Play `audio-volume-change` after the volume changed, so that it plays at the new volume.
- Do not play a sound for what a test does. `apus-screen shot` is a test tool, and a test makes no sound.

## What is still to do

These items are also in [next-steps.md](next-steps.md).

1. **The audio stack in the image.** PipeWire, WirePlumber and `pipewire-audio` (for `pw-play`), and virtio-sound to the Mac. This is separate work. Until it is in the image, `playSound` plays nothing.
2. **The compositor.** Play `desktop-login` at the first frame of the session. Play a sound for a notice: `message-new-instant` for a notice of an app, and `dialog-information`, `dialog-warning` or `dialog-error` for a notice of the system, by `Notice.Kind`.
3. **The terminal.** It drops BEL now (`ui/Toolkit/Sources/Terminal/Screen.swift`). The screen can count the bells, and the app can play `bellTerminal` at most once in 100 ms.
4. **The volume keys.** The compositor reads `XF86AudioRaiseVolume`, `XF86AudioLowerVolume` and `XF86AudioMute`, changes the volume with `wpctl`, and then plays `audio-volume-change`. This needs the audio stack.
5. **A screenshot key.** Apus has none. When it has one, the key plays `screen-capture`. `apus-screen shot` does not.
6. **Devices.** A udev monitor in the compositor for devices that a person plugs in: `device-added` and `device-removed`. Not for the devices that are there at boot.
7. **Power.** The Power app (separate work) reads `/sys/class/power_supply`. It plays `power-plug` and `power-unplug` when `online` changes, and `battery-low` once when the charge crosses the low level while it discharges.
8. **The logout.** Settings powers off with `systemctl poweroff`, and systemd stops the player with the shell. The compositor must play `desktop-logout` and wait for its length (0.6 s) before it asks systemd to stop.
9. **A switch in Settings.** Sounds on or off, and a volume for event sounds. The lookup honours a `.disabled` file already, so a switch for one sound can write one in `~/.local/share/sounds/apus/stereo`. A switch for all sounds needs a value that `playSound` reads.
10. **The cost of a sound.** Each sound starts a process, which takes a few milliseconds. That is enough for events. A player in the process (a PipeWire stream) would start faster, but then the toolkit links libpipewire.
