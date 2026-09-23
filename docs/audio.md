# Audio

The guest plays sound through the speakers of the Mac. It can also hear the
microphone of the Mac, when a person asks for that.

```
   an app ──┐                                                   ┌── speakers
            ├─ PipeWire ─ ALSA ─ virtio_snd ─ virtio sound ─ apus-vm
   pw-play ─┘  (WirePlumber,                    device        └── microphone
               pipewire-pulse)                                    (VM_AUDIO=mic)
```

## Play a sound

```sh
pw-play /usr/share/sounds/apus/stereo/message-new-instant.oga
```

`pw-play` plays a file (WAV, FLAC, Ogg Vorbis, and the other types of
libsndfile) on the default sink and stops at its end. `--volume 0.5` plays it
at half volume. This is the command for a system sound: a program that wants
a sound starts `pw-play` with the path of the file.

Programs for the other two sound interfaces reach the same server:

| Interface | Example |
|---|---|
| PipeWire | `pw-play`, `pw-cat`, `wpctl` |
| PulseAudio | `paplay`, `pactl`, libcanberra, most browsers |
| ALSA | `aplay`, `speaker-test` (the `default` device goes to PipeWire) |

To test the whole path with the ears:

```sh
speaker-test -c 2 -t wav -l 1     # "front left", "front right"
```

### Where the system sounds go

The sounds of Apus are the `apus` sound theme, in `/usr/share/sounds/apus/`,
with one file for each name of the [freedesktop sound naming
specification](https://specifications.freedesktop.org/sound-naming-spec/latest/)
that has a sound. The toolkit finds the file and gives it to `pw-play`. See
[sounds.md](sounds.md).

The image does not have the freedesktop sound theme. The spec makes
`freedesktop` the last theme of every lookup, so with it an event that Apus
keeps silent on purpose would play a sound of that theme. The image has no
libcanberra: its player, `canberra-gtk-play`, needs GTK, and `pw-play` does
the same work.

## The host

`apus-vm` gives the guest a `VZVirtioSoundDeviceConfiguration`. The variable
`VM_AUDIO` selects its streams:

| `VM_AUDIO` | Streams |
|---|---|
| Not set, or `on` | One output: `VZHostAudioOutputStreamSink`, the default output of the Mac. |
| `mic` | That output, and one input: `VZHostAudioInputStreamSource`, the default input of the Mac. |
| `off` | No sound device. |

`make gui`, `make demo` and the tests use the default, so the guest has
speakers and no microphone.

The microphone is not the default, for these reasons:

- macOS asks the person before a program can hear the microphone. The
  question goes to the app that started `apus-vm`, for example Terminal or
  Xcode, and not to `apus-vm`, which is a program with no app bundle. A test
  that nobody watches would wait at that question.
- If the person says no, the guest probably records silence, and nothing
  says why. This is not tested.
- A guest that can hear the room at all times is not a good default.

`apus-vm` needs no new entitlement and no new signature for the microphone.
The `com.apple.security.device.audio-input` entitlement is for a program
with the hardened runtime, and `make vm` signs ad hoc, without it.

On 23 September the microphone worked with no question, because the app
that ran the test had the permission already. On a Mac where nobody has
answered the question yet, this is not tested.

The framework says nothing about what reaches the speakers. The Mac does:
while the guest plays, `pmset -g assertions` lists an assertion of
`coreaudiod` on `BuiltInSpeakerDevice` (or on the output that is in use),
"Created for PID" the `com.apple.Virtualization.VirtualMachine` process of
the machine. The framework runs each machine in a process of that name, and
not in `apus-vm`. The microphone gives an assertion on
`BuiltInMicrophoneDevice` in the same way.

## The guest

### The driver

The Arch Linux ARM kernel (`linux-aarch64`) has sound, but not the driver of
this device: `CONFIG_SND_VIRTIO` is not set. Without the driver the guest has
no sound card.

`packages/virtio-snd` builds that one driver. It takes the files of
`sound/virtio/` from the kernel release that `pkgver` names (from
git.kernel.org, with SHA-256 sums), and compiles them against
`linux-aarch64-headers` in the builder. The package puts `virtio_snd.ko` in
`/usr/lib/modules/<kernel>/extramodules/`, and the depmod hook of pacman adds
it to the list of modules. udev loads it when it finds the device, so
nothing else loads it.

The module fits one kernel only. Thus:

- A new `linux-aarch64` needs a new `make build`. When the headers in the
  builder are newer than `pkgver`, the build says so and goes on. Move
  `pkgver` to the new release, and put the new sums in the PKGBUILD.
- A machine that updates its kernel with pacman has no sound until it gets
  a new package.

A kernel with `CONFIG_SND_VIRTIO=m` removes the package. See
[next-steps.md](next-steps.md#the-system).

### The profiles of the card

The card has the speakers as PCM 0 and, with `VM_AUDIO=mic`, the microphone
as PCM 1. The default profiles of PipeWire look for a microphone on PCM 0
only. With them the card has a sink (`Stereo`) and no source.

`/usr/share/alsa-card-profile/mixer/profile-sets/apus-virtio.conf` names the
two PCMs, and a udev rule (`/usr/lib/udev/rules.d/90-apus-virtio-snd.rules`)
gives it to the card with `ACP_PROFILE_SET`. The sink is then `Speakers` and
the source is `Microphone`. A card with no microphone gets the speakers
only. A WirePlumber rule with `api.acp.profile-set` does not do this: the
property arrives on the device, but the card still reads `default.conf`.

WirePlumber gives a new sink a volume of 40%. `wpctl set-volume
@DEFAULT_AUDIO_SINK@ 100%` changes it.

### The sound server

PipeWire is the sound server, WirePlumber is its session manager, and
`pipewire-pulse` and `pipewire-alsa` take the programs of PulseAudio and of
ALSA to it. See [decisions.md](decisions.md).

The packages have units for the session of a person, under
`systemd --user`. Those units refuse root (`ConditionUser=!root`), and the
shell runs as root, as a service of the system, with no login session. See
[system.md](system.md). Thus Apus has three services of its own:

| Unit | Program |
|---|---|
| `apus-pipewire.service` | `pipewire` |
| `apus-wireplumber.service` | `wireplumber` |
| `apus-pipewire-pulse.service` | `pipewire-pulse` |

- `apus-shell.service` wants `apus-pipewire.service`, and that unit wants the
  other two. So the sound server starts with the shell.
- The sound server does not stop when the shell stops. The tests stop the
  shell, and a restart of the shell does not cut a sound.
- The shell fails without a screen, but systemd starts the units that it
  wants in any case. So a machine with no display also has sound.
- The live system does not start the shell, so it has no sound server.

The server is in `/run/pipewire`: `pipewire-0` for PipeWire and
`pulse/native` for PulseAudio. It is not in the runtime directory of the
shell (`/run/apus`), because systemd removes that directory when the shell
stops. Two variables name it:

| Variable | Value |
|---|---|
| `PIPEWIRE_RUNTIME_DIR` | `/run/pipewire` |
| `PULSE_SERVER` | `unix:/run/pipewire/pulse/native` |

`apus-shell.service` sets them, and every app that the shell starts gets
them. `/etc/environment` sets them for a login on the console and over SSH.
So all of these programs find one server.

The journal of the three services has warnings about the D-Bus session
bus, because a service of the system has none. They are expected. Without
that bus, WirePlumber does not reserve the card for itself
(`org.freedesktop.ReserveDevice1`) and has no MPRIS and no portal. Apus uses
none of them.

When Apus has user accounts, the shell will run in the session of a person,
and the units of the packages will do this work.

## The test

`tests/audio.exp` boots the installed disk with the sound device. It checks
these conditions:

- `aplay -l` lists `VirtIO SoundCard`.
- The default sink of PipeWire (`wpctl inspect @DEFAULT_AUDIO_SINK@`) is on
  that card, and it is `speakers` from the profiles of Apus.
- `pactl info` gets an answer from PipeWire.
- While `pw-play` plays a file, `/proc/asound/card0/pcm0p/sub0/status` says
  `RUNNING`.

The test plays at volume 0, so it makes no sound on the Mac. It cannot hear
the speakers, so the check with the ears is `speaker-test` in `make gui`.
