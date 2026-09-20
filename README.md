# mydistro

mydistro is a Linux distribution for aarch64, based on Arch Linux ARM. It uses systemd and pacman. A live image boots in a VM and installs the system to a disk. The user interface is a Wayland compositor in Swift 6.4, with a declarative toolkit of its own, a tiling shell, and a terminal.

## Requirements

- A Mac with Apple silicon.
- Apple `container` 1.0 or later. Start the service with `container system start`.
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
| `make live` | Boots the live image. Log in as `root` with no password, then run `mydistro-install`. |
| `make installed` | Boots the installed disk, with the serial console only. |
| `make gui` | Boots the installed disk in a window. |
| `make ui` | Compiles the Swift code on the Mac in a few seconds, for use in the VM at `/mnt/host/ui/`. |
| `make demo-dev` | The same as `make demo`, with the programs from `make ui`. |
| `make test-dev` | The compositor test, with the programs from `make ui`. |
| `make shell` | Opens a root shell in the builder container. |
| `make help` | Lists all commands. |

To stop a VM, push Ctrl-A in the terminal, then push X.

To use Xcode, open `mydistro.xcodeproj`. Cmd-B runs `make ui`, and Cmd-R starts the new build in a VM. See [User interface](docs/ui.md#xcode).

To install software on a running system, use pacman. For example: `pacman -S htop`.

## Documentation

| Document | Content |
|---|---|
| [Architecture](docs/architecture.md) | The layers, the repository layout, and the boot sequence |
| [Building](docs/building.md) | The builder image, the pinned inputs, the build steps, and reproducibility |
| [The system](docs/system.md) | The live image, the installer, first boot, and the system settings |
| [Packages](docs/packages.md) | The `[mydistro]` repository, the branding package, and how to add packages |
| [User interface](docs/ui.md) | The Swift toolchains, the Swift SDK, Xcode, the Swift package, and the development loop |
| [Compositor](docs/compositor.md) | The design of `mydistro-compositor` and of its Wayland server in Swift |
| [Toolkit](docs/toolkit.md) | The declarative UI layer: views, layout, and text |
| [Applications](docs/applications.md) | The app bundles in `/Applications`, Summon, and the terminal |
| [Layouts](docs/layouts.md) | How a layout and a window agree on a size, and the four layouts |
| [Writing an app](docs/apps.md) | The client library, the two user interfaces of an app, and the bundle |
| [Testing](docs/testing.md) | The VM, the tests, and the screenshot checks |
| [Decisions](docs/decisions.md) | The main decisions, with the reasons and the evidence |
| [Troubleshooting](docs/troubleshooting.md) | Problems that occurred, and their solutions |
| [Next steps](docs/next-steps.md) | Loose ends and the next work |

The documentation uses ASD-STE100 Simplified Technical English.
