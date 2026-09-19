# Testing and the VM

## The VM

`vm/run.sh` starts QEMU with these settings:

- Machine `virt`, aarch64, 4 CPUs, 2 GB of memory, HVF acceleration.
- UEFI firmware from Homebrew QEMU (`edk2-aarch64-code.fd`). The firmware variables are new for each boot, so the firmware starts `EFI/BOOT/BOOTAA64.EFI` like a new machine.
- Network: QEMU user networking. The VM gets an address with DHCP.
- QEMU shares `out/` of the Mac with the VM at `/mnt/host` (read-only).

| Command | Disks |
|---|---|
| `vm/run.sh live` | `out/live.img` (read-only snapshot) and the target disk `out/vm/target.qcow2` |
| `vm/run.sh installed` | Only the target disk |

The variable `VM_GPU` selects the display:

| `VM_GPU` | Display |
|---|---|
| Not set | No display device. Serial console only. |
| `window` | virtio-gpu in a macOS window, with a keyboard and a tablet (mouse) |
| `headless` | virtio-gpu with no window. The QEMU monitor is on `out/vm/monitor.sock`. |

The serial console is always in the terminal. To stop QEMU, push Ctrl-A in the terminal, then push X. In a window, QEMU holds the mouse. Push Control+Option+G to release it.

If `out/vm/target.qcow2` does not exist, `vm/run.sh` makes an 8 GB disk. To start with an empty disk, remove the file. To change the size, set `TARGET_SIZE`, for example `TARGET_SIZE=16G`.

## Make targets

| Command | Result |
|---|---|
| `make live` | Boots the live image and the target disk. |
| `make installed` | Boots only the target disk. |
| `make gui` | Boots the target disk in a window. |
| `make demo` | Boots the target disk in a window and starts the compositor with a test window. |
| `make test` | Runs the three tests. |

## The tests

The tests are `expect` scripts. They use the serial console of the VM. `tests/lib.exp` has the shared procedures `login` and `fail`. Each test stops at the first error and prints `TEST FAILED: <reason>`.

| Test | What it does |
|---|---|
| `tests/install.exp` | Removes the target disk. Boots the live image and runs `mydistro-install -y /dev/vdb`. Boots the installed disk and checks it (see below). |
| `tests/display.exp` | Boots the installed disk with `VM_GPU=headless`. Checks `/mnt/host`. Runs `mydistro-ui-check` and `mydistro-display-probe`. Checks a screenshot. |
| `tests/compositor.exp` | Boots the installed disk with `VM_GPU=headless`. Starts `mydistro-compositor` and `mydistro-hello-client`. Checks a screenshot. Stops the compositor with SIGTERM. |

`tests/display.exp` and `tests/compositor.exp` use the disk that `tests/install.exp` made. Run the tests in this sequence. `make test` does this.

The installed system passes when all these conditions are true:

- `/etc/mydistro-installed` exists.
- `/etc/os-release` has `ID=mydistro`, and pacman lists `mydistro-release`.
- `/boot` is a mount point and has `/boot/Image`.
- The kernel command line does not have `mydistro.live`.
- The root file system is writable.
- pacman can read its database (`pacman -Q linux-aarch64`).

The test also prints the output of `systemctl is-system-running` and `systemctl --failed`. The expected result is `running` with no failed units.

### Output markers

The tests look for markers in the output. A marker that the test sends in a command must not match before the command runs. Thus, the tests use shell arithmetic, for example `echo INSTALLED-$((1+1))` gives `INSTALLED-2`. The command text does not contain `INSTALLED-2`.

The programs print these markers:

| Marker | Program |
|---|---|
| `Installation complete` | `mydistro-install` |
| `UI-CHECK-OK` | `mydistro-ui-check` |
| `PROBE-READY`, `PROBE-DONE` | `mydistro-display-probe` |
| `COMPOSITOR-READY`, `COMPOSITOR-EXIT` | `mydistro-compositor` |
| `WINDOW-MAPPED` | `mydistro-compositor`, when a window opens |
| `CLIENT-DRAWN` | `mydistro-hello-client` |

### Screenshots

`tests/screen.py` gets a screenshot through the QEMU monitor (`screendump`) and checks pixel colours:

```sh
tests/screen.py out/vm/monitor.sock out/vm/screen.ppm X,Y=RRGGBB...
```

X and Y are pixels. If a value contains a dot, it is a fraction of the screen size (`0.5,0.5` is the centre). The screenshot is in `out/vm/screen.ppm`.

The compositor test checks these pixels on the 1280×800 screen:

| Pixel | Colour | What it is |
|---|---|---|
| (128, 80) | `2B2340` | The background |
| (576, 360) | `3070F0` | The inside of the window |
| (444, 254) | `FFFFFF` | The border of the window |
| (640, 400) | `000000` | The outline of the pointer |
| (641, 402) | `FFFFFF` | The inside of the pointer |

## After a change

Run `make build` and `make test` after each change. For Swift changes, you can use `make ui` first. See [ui.md](ui.md).
