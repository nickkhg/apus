# mydistro

mydistro is a Linux distribution for aarch64, based on Arch Linux ARM. It uses systemd and pacman. A live image boots in a VM and installs the system to a disk. The user interface is a Wayland compositor in Swift 6.4.

## Requirements

- A Mac with Apple silicon.
- Apple `container` 1.0 or later. Start the service with `container system start`.
- QEMU from Homebrew: `brew install qemu`.
- Approximately 20 GB of free disk space.

## Quick start

1. Build the live image. The first build downloads approximately 3 GB. Later builds take approximately 1 minute.

   ```sh
   make build
   ```

2. Run the tests. They install the system to a new VM disk, then test the display and the compositor.

   ```sh
   make test
   ```

3. Boot the installed system in a window, with the compositor and a test window.

   ```sh
   make demo
   ```

Other commands:

| Command | Result |
|---|---|
| `make live` | Boots the live image. Log in as `root` with no password, then run `mydistro-install`. |
| `make installed` | Boots the installed disk, with the serial console only. |
| `make gui` | Boots the installed disk in a window. |
| `make ui` | Compiles the Swift code in a few seconds, for use in the VM at `/mnt/host/ui/`. |
| `make shell` | Opens a root shell in the builder container. |
| `make help` | Lists all commands. |

To stop QEMU, push Ctrl-A in the terminal, then push X.

To install software on a running system, use pacman. For example: `pacman -S htop`.

## Documentation

| Document | Content |
|---|---|
| [Architecture](docs/architecture.md) | The layers, the repository layout, and the boot sequence |
| [Building](docs/building.md) | The builder image, the pinned inputs, the build steps, and reproducibility |
| [The system](docs/system.md) | The live image, the installer, first boot, and the system settings |
| [Packages](docs/packages.md) | The `[mydistro]` repository, the branding package, and how to add packages |
| [User interface](docs/ui.md) | The Swift toolchain, the Swift package, the C library modules, and the development loop |
| [Compositor](docs/compositor.md) | The design of `mydistro-compositor` and its Wayland support |
| [Testing](docs/testing.md) | The VM, the tests, and the screenshot checks |
| [Decisions](docs/decisions.md) | The main decisions, with the reasons and the evidence |
| [Troubleshooting](docs/troubleshooting.md) | Problems that occurred, and their solutions |
| [Next steps](docs/next-steps.md) | Loose ends and the next work |

The documentation uses ASD-STE100 Simplified Technical English.
