# Apus

*Apus* is the genus of the common swift, from the Greek *ápous*, "footless". The name comes from an old belief that the bird had no feet, because nobody ever saw one on the ground: a swift eats, sleeps and mates on the wing, and comes down only to nest. This system is written in Swift from the compositor up, so it borrows the bird rather than the word.

Apus is a Linux distribution for aarch64, based on Arch Linux ARM. It uses systemd and pacman. A live image boots in a VM and installs the system to a disk. The user interface is a Wayland compositor in Swift 6.4, with a declarative toolkit of its own, a tiling shell, and a terminal.

## Requirements

- A Mac with Apple silicon.
- Apple `container` 1.0 or later. Start the service with `container system start`. The build stops and says this if the service is not running.
- Homebrew, for the GPU renderer of the host side. `make vm` installs what that renderer needs and then builds it. A Mac with no Homebrew builds a virtual machine that gives the guest a 2D screen only.
- Approximately 28 GB of free disk space. The Swift toolchain for macOS and the Swift SDK use approximately 7.5 GB of this.
- Optional: Xcode, to edit and build from Xcode.

## Quick start

1. Build the live image. The first build downloads approximately 3 GB. Later builds take approximately 1 minute.

   ```sh
   make build
   ```

2. Run the tests. They install the system to a new VM disk, then test the display and the compositor.

   ```sh
   make test
   ```

3. Boot the installed system in a window, with the compositor. Press Super to open Summon, then type a name and press Enter to start an app.

   ```sh
   make demo
   ```

Other commands:

| Command | Result |
|---|---|
| `make live` | Boots the live image. Log in as `root` with no password, then run `apus-install`. |
| `make installed` | Boots the installed disk, with the serial console only. |
| `make gui` | Boots the installed disk in a window. |
| `make ui` | Compiles the Swift code on the Mac in a few seconds, for use in the VM at `/mnt/host/ui/`. |
| `make demo-dev` | The same as `make demo`, with the programs from `make ui`. |
| `make test-dev` | The compositor test, with the programs from `make ui`. |
| `make shell` | Opens a root shell in the builder container. |
| `make help` | Lists all commands. |

To stop a VM, push Ctrl-A in the terminal, then push X.

To use Xcode, open `apus.xcodeproj`. Cmd-B runs `make ui`, and Cmd-R starts the new build in a VM. See [User interface](docs/ui.md#xcode).

To install software on a running system, use pacman. For example: `pacman -S htop`.

## Documentation

| Document | Content |
|---|---|
| [Architecture](docs/architecture.md) | The layers, the repository layout, and the boot sequence |
| [Building](docs/building.md) | The builder image, the pinned inputs, the build steps, and reproducibility |
| [The system](docs/system.md) | The live image, the installer, first boot, and the system settings |
| [Packages](docs/packages.md) | The `[apus]` repository, the branding package, and how to add packages |
| [User interface](docs/ui.md) | The Swift toolchains, the Swift SDK, Xcode, the Swift package, and the development loop |
| [Compositor](docs/compositor.md) | The design of `apus-compositor` and of its Wayland server in Swift |
| [Toolkit](docs/toolkit.md) | The declarative UI layer: views, layout, and text |
| [Applications](docs/applications.md) | The app bundles in `/Applications`, Summon, and the terminal |
| [Settings](docs/settings.md) | The Settings app: what each pane reads and writes, and the keys |
| [Layouts](docs/layouts.md) | How a layout and a window agree on a size, and the four layouts |
| [Sounds](docs/sounds.md) | The system sounds: the events, how they are made, the check, and how to play one |
| [Writing an app](docs/apps.md) | The client library, the two user interfaces of an app, and the bundle |
| [Testing](docs/testing.md) | The VM, the tests, and the screenshot checks |
| [Decisions](docs/decisions.md) | The main decisions, with the reasons and the evidence |
| [Troubleshooting](docs/troubleshooting.md) | Problems that occurred, and their solutions |
| [Next steps](docs/next-steps.md) | Loose ends and the next work |
| [Licensing](docs/licensing.md) | The license of this code, the code from other projects, and what a published image asks of you |

The documentation uses ASD-STE100 Simplified Technical English.

## License

Apus is under the Apache License 2.0. [LICENSE](LICENSE) holds the full text.

The disk image holds packages from other projects, and each one keeps its own license. See [licensing.md](docs/licensing.md) before you publish an image.
