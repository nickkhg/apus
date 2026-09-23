# Testing and the VM

## The VM

`apus-vm` starts the VM. It is a Swift program in `vm/`, and it uses Apple's Virtualization framework. The settings are:

- aarch64, 4 CPUs, 2 GB of memory.
- The EFI firmware of the framework. The firmware variables are new for each boot, so the firmware starts `EFI/BOOT/BOOTAA64.EFI` like a new machine.
- Network: network address translation. The VM gets an address with DHCP.
- Two shared directories, over virtiofs. `out/` of the Mac is at `/mnt/host`, read-only. `out/vm/screens` is at `/mnt/screens`, and the VM can write to it.
- A virtio sound device, with the speakers of the Mac as its output. `VM_AUDIO=mic` adds the microphone, and `VM_AUDIO=off` removes the device. See [audio.md](audio.md).

`make vm` builds the program and signs it. The signature carries the entitlement `com.apple.security.virtualization`. Without that entitlement, the framework refuses to make a VM. A local (ad hoc) signature is sufficient.

| Command | Disks |
|---|---|
| `apus-vm live` | A copy of `out/live.img`, and the target disk `out/vm/target.img` |
| `apus-vm installed` | Only the target disk |

A boot in `live` mode first copies `out/live.img` to `out/vm/live-boot.img`, and the VM uses the copy. The live image therefore never changes. On APFS the copy is a clone: it is immediate, and it uses almost no disk. The copy must be writable, because systemd-boot writes a random seed to the EFI system partition.

The variable `VM_GPU` selects the display:

| `VM_GPU` | Display |
|---|---|
| Not set | No display device. Serial console only. |
| `window` | A virtio graphics device in a macOS window, with a USB keyboard and a pointer. A resize of the window resizes the screen of the guest, and the compositor lays out again. |
| `headless` | A virtio graphics device with no window. The guest writes the pictures of the screen. See [Screenshots](#screenshots). |

The serial console is always in the terminal. To stop the VM, push Ctrl-A in the terminal, then push X.

`VM_SCREEN` sets the size of the screen, for example `VM_SCREEN=1920x1200`. The default is 1280x800, which is the size that the pixel tests read.

A window follows its own size when a person changes it, and it counts pixels, not points. A Mac with small pixels therefore gives the guest two times the pixels in each direction, which is four times the work for each frame. `VM_RESIZE=off` keeps the size that `VM_SCREEN` gave.

`APUS_FRAME_LOG` times the frames. `APUS_FRAME_LOG=20` writes one line for each 20 frames: the cost of a frame, the longest gap between two frames, the rate, the size of the screen, and the part of the screen that the frames drew. These are the costs of the shell with nothing open, drawn whole, in a VM, where Mesa renders with the CPU:

| Renderer | Size | Average | Longest |
|---|---|---|---|
| `cpu` | 1280x800 | 14.2 ms | 17.0 ms |
| `cpu` | 2560x1600 | 37.1 ms | 46.9 ms |
| `gpu` | 2560x1600 | 49.4 ms | 186.5 ms |

The average and the longest are the cost of the drawing alone. The rate in the line is a different measurement: it counts the frames against the clock, so the waiting for a page flip, for input, and for an app is in it. A frame that costs 6 ms does not make 163 frames a second if the compositor then waits 20 ms for the next thing to do. `worst gap`, beside the rate, is the longest the screen went without a new frame, and a stutter is in that number and not in the average.

The GPU renderer is the slower one in a VM, because the VM has no GPU. Mesa renders with the CPU (llvmpipe). The GPU path then adds work of its own: a texture for each window, and a new framebuffer for each frame. On hardware with a GPU the numbers are not these. A frame drawn whole costs the size of the screen, so the size is what counts most then.

The compositor draws only the part of the screen that changed (see [compositor.md](compositor.md#damage)), and `APUS_DAMAGE=full` draws every frame whole. These are the two, in a VM at 1280x800, with the terminal open: 60 keys typed into it, then 60 lines of output, then Summon opened and closed. Each number is the average of the lines of `APUS_FRAME_LOG=20` for that part (23 September):

| Renderer | What changes | Whole | Only the damage | Drew |
|---|---|---|---|---|
| `cpu` | a key in the terminal | 2.5 ms | 0.5 ms | 1 % |
| `cpu` | a line of output | 2.5 ms | 0.5 ms | 1 % |
| `cpu` | Summon | 2.2 to 4.8 ms | 1.0 to 2.0 ms | 8 % |
| `gpu` (GBM, llvmpipe, GPU mode) | a key in the terminal | 10.1 ms | 1.9 ms | 1 % |
| `gpu` (GBM, llvmpipe, GPU mode) | a line of output | 10.7 ms | 1.9 ms | 1 % |
| `gpu` (GBM, llvmpipe, GPU mode) | Summon, over its blur | 10.2 ms | 3.7 to 10.0 ms | 8 % |

The rate stays near 19 frames a second in every row, because the apps and the input set it, not the drawing. What the damage gives back is time for everything else, and room for a larger screen.

If `out/vm/target.img` does not exist, the program makes an 8 GB disk. To start with an empty disk, remove the file. To change the size, set `TARGET_SIZE`, for example `TARGET_SIZE=16G`. The disk is a raw file, because the framework reads raw disk images only. The file is sparse: it uses only the blocks that the guest writes.

## Make targets

| Command | Result |
|---|---|
| `make live` | Boots the live image and the target disk. |
| `make installed` | Boots only the target disk. |
| `make gui` | Boots the target disk in a window. The shell starts with the machine. |
| `make demo` | Boots the target disk in a window and starts the compositor with a test window. It installs the disk first, when there is none. |
| `make test` | Runs the three tests. |
| `make test-ui` | Runs the unit tests of the toolkit and the shell on the Mac. No VM and no container. |
| `make test-ui-linux` | Runs the same tests on Apus, in the builder container. |
| `make test-dev` | Runs `make ui`, then the compositor test with the programs from `out/ui/` (through `/mnt/host/ui`). Needs the disk from `make test`. |
| `make demo-dev` | The same as `make demo`, with the programs from `out/ui/`. |

## Unit tests

`make test-ui` runs the unit tests of `ui/Toolkit/` on the Mac, because that package also builds for macOS. A run takes a few seconds. They test the layout of the toolkit, the text, and the shell panel. A test makes a display list from a view and looks at the items in it, so it needs no screen.

`make test-ui-linux` runs the same tests on Apus, in the builder container. Run it before a commit. See [toolkit.md](toolkit.md#tests).

## The tests

The tests are `expect` scripts. They use the serial console of the VM. `tests/lib.exp` has the shared procedures `login` and `fail`. Each test stops at the first error and prints `TEST FAILED: <reason>`.

An installed system starts the shell when it finishes booting, so it owns the screen. `login` therefore stops `apus-shell.service`, and the test drives the screen itself. A test that sets `expectShell` to 1 before it logs in also holds that the shell was running. `tests/install.exp` does that on the first boot of the system that it installed. That is the one place that says the machine starts into its user interface.

| Test | What it does |
|---|---|
| `tests/install.exp` | Removes the target disk. Boots the live image and runs `apus-install -y /dev/vdb`. Boots the installed disk and checks it (see below). |
| `tests/display.exp` | Boots the installed disk with `VM_GPU=headless`. Checks `/mnt/host`. Runs `apus-ui-check` and `apus-display-probe`. Checks a screenshot. |
| `tests/compositor.exp` | Boots the installed disk with `VM_GPU=headless`. Starts `apus-compositor`. Opens the apps with Summon, types in the terminal, and checks screenshots. Stops the compositor with SIGTERM. |
| `tests/audio.exp` | Boots the installed disk with the sound device. Checks the ALSA card, the PipeWire sink and the PulseAudio server, and that the card runs while `pw-play` plays. See [audio.md](audio.md#the-test). |

`tests/display.exp` and `tests/compositor.exp` use the disk that `tests/install.exp` made. Run the tests in this sequence. `make test` does this.

The installed system passes when all these conditions are true:

- `/etc/apus-installed` exists.
- `/etc/os-release` has `ID=apus`, and pacman lists `apus-release`.
- `/boot` is a mount point and has `/boot/Image`.
- The kernel command line does not have `apus.live`.
- The root file system is writable.
- pacman can read its database (`pacman -Q linux-aarch64`).

The test also prints the output of `systemctl is-system-running` and `systemctl --failed`. The expected result is `running` with no failed units.

### Output markers

The tests look for markers in the output. A marker that the test sends in a command must not match before the command runs. Thus, the tests use shell arithmetic, for example `echo INSTALLED-$((1+1))` gives `INSTALLED-2`. The command text does not contain `INSTALLED-2`.

The programs print these markers:

| Marker | Program |
|---|---|
| `Installation complete` | `apus-install` |
| `UI-CHECK-OK` | `apus-ui-check` |
| `PROBE-READY`, `PROBE-DONE` | `apus-display-probe` |
| `COMPOSITOR-READY`, `COMPOSITOR-EXIT` | `apus-compositor` |
| `WINDOW-MAPPED` | `apus-compositor`, when a window opens |
| `WINDOW-CLOSE-SENT` | `apus-compositor`, when a command of Summon asks a window to close |
| `WINDOW-CONFIGURED`, `WINDOW-KEPT` | `apus-compositor`, when a layout gives a window a new size or keeps the one it had |
| `WINDOW-STATE` | `apus-compositor`, when a window keeps its size and gets new states (`activated`, `resizing`) |
| `FOCUS` | `apus-compositor`, when another window gets the keys |
| `WINDOW-RAISED` | `apus-compositor`, when a click brings a tile into the large cell |
| `WINDOW-MOVE-START`, `WINDOW-MOVED`, `WINDOW-MOVE-DROPPED` | `apus-compositor`, when an app starts a move, and when the window takes another cell or keeps its own |
| `WINDOW-RESIZE-START`, `WINDOW-RESIZED` | `apus-compositor`, when an app starts a resize, and the size at the release |
| `WINDOW-MOVE-REFUSED`, `WINDOW-RESIZE-REFUSED` | `apus-compositor`, when the layout has no use for the request |
| `WINDOW-MOVE-IGNORED`, `WINDOW-RESIZE-IGNORED` | `apus-compositor`, when the request names no press that is still held |
| `WINDOW-IN-RAIL` | `apus-compositor`, when a layout places no window and it waits in the rail |
| `LAYOUT` | `apus-compositor`, when a person picks another layout |
| `APP-STARTED`, `APP-RAISED` | `apus-compositor`, when Summon starts an app or brings its window forward |
| `APP-DID-NOT-START` | `apus-compositor`, when an app opens no window in ten seconds |
| `CLIENT-DRAWN` | `apus-hello-client` |
| `CLIENT-POINTER-ENTER`, `CLIENT-POINTER`, `CLIENT-POINTER-LEAVE`, `CLIENT-BUTTON` | `apus-hello-client`, when the compositor gives it the pointer |
| `CLIENT-MOVE`, `CLIENT-RESIZE` | `apus-hello-client`, when a press on its bar or its border asks for a move or a resize |
| `CLIENT-CONFIGURE` | `apus-hello-client`, with the size and the states of each configure |
| `TERMINAL-READY` | `apus-terminal`, with the size of the grid |

### Screenshots

Apple's Virtualization framework cannot make a picture of the screen of a guest, and it cannot send input to a guest. QEMU could do both, with `screendump` on its monitor socket and `input-send-event` on QMP. The guest therefore does this work itself, with `apus-screen`:

| Command | Result |
|---|---|
| `apus-screen shot PATH` | Asks the compositor for the pixels that it put on the screen, and writes them to `PATH` as a PPM. |
| `apus-screen input [OPTIONS]` | Moves the pointer, clicks, and types. |
| `apus-screen size` | Prints the size of the screen. |

| Option of `input` | Result |
|---|---|
| `--pointer X,Y` | Puts the pointer on that pixel. |
| `--click` | Presses the left button and releases it, where the pointer is. |
| `--press`, `--release` | Presses the left button and holds it, or releases it. A `--pointer` between the two is a drag. |
| `--type TEXT` | Types the text. It knows the small letters, the capitals, the digits, some punctuation, and `\n` for the Enter key. |

The tool runs the options in the order of the command line. A test can therefore say `--key super --type terminal --key enter`, which opens Summon, narrows the list, and then chooses. `--key` presses a key that writes no character. The names are `escape`, `backspace`, `tab`, `enter`, `up`, `down`, `left`, `right`, `super` and `space`.

`apus-screen input` makes a pointer and a keyboard with uinput. The pointer reports where it is, from 0 to 32767 on each axis, which is what QEMU's virtio-tablet also did. The events therefore go through evdev, libinput and xkbcommon, in the same way as the events of a real mouse and a real keyboard. The compositor needs no test code for input.

The compositor writes the pictures. It listens on the socket that `APUS_SCREENSHOT_SOCKET` names, and it writes the buffer that it gave to the display. The pixels in a picture are therefore the pixels on the screen, and not a second drawing of them. Without that variable, the compositor has no such socket.

`tests/display.exp` runs no compositor, so `apus-display-probe --write PATH` writes its own picture.

The tests put the pictures in `/mnt/screens`, which is `out/vm/screens` on the Mac. `tests/screen.py` reads them there and checks pixel colours:

```sh
tests/screen.py PICTURE.ppm X,Y=RRGGBB ...
```

There are two kinds of check:

| Check | Result |
|---|---|
| `X,Y=RRGGBB` | This pixel has this colour. |
| `X0,Y0-X1,Y1!RRGGBB` | This area has at least one pixel of another colour. |

The second kind tests drawing that is correct but not exact, for example text. The test knows where the glyphs are. It does not know which pixels they cover.

X and Y are pixels. If a value contains a dot, it is a fraction of the screen size (`0.5,0.5` is the centre).

The compositor test checks these places on the 1280×800 screen. The rail is 56 points wide, 8 from every edge, so it covers x 8 to 64. The canvas is beside it, at 72, 8.

| Place | Expected | What it is |
|---|---|---|
| (128, 80) | `07080A` | The desktop background |
| (36, 400) | `12161A` | The background of the rail |
| (22, 44) | `1D2A12` | The Summon button at the top of the rail |
| (640, 120) | `12161A` | The surface of Summon, when it is open |
| (150, 400) | `020203` | The desktop under the layer that dims it |
| (640, 400) | `000000` | The outline of the pointer |
| (641, 402) | `FFFFFF` | The inside of the pointer |
| (600, 730) | `3070F0` | The first icon in its full colour, with the pointer on it |
| (640, 400) | `14111E` | The window of the terminal, over the whole app area |
| (0, 28) to (500, 52) | Not `14111E` | The prompt of the shell, in the first line of the terminal |
| (667, 771) | `FFFFFF` | The dot under the icon of the app that is open |
| (0, 28) to (700, 120) | Not `14111E` | What the test typed, and what the shell answered |
| (640, 400) | `3070F0` | The window of the second app, over the first one |
| (4, 32) | `FFFFFF` | The border of that window, at the top left of the app area |
| (900, 9) | `A9E34B` | The accent line over the terminal, side by side, after a click on it |
| (800, 400) | `3070F0` | The window of hello, after its right edge moved 200 to the right |
| (300, 400), (1100, 400) | `14111E`, `3070F0` | The terminal and hello, after hello moved to the other half |
| (640, 400) | `14111E` | The terminal again, after a click on the Close button |
| (640, 400) | `2B2340` | The desktop, after the terminal closes too |
| (667, 771) | `171320` | The background of the dock, where the dot was |

The test also reads `/tmp/typed` on the serial console. The shell in the terminal writes that file. The file is the proof: the keys went from uinput, through libinput, the compositor and the app, to the shell.

## After a change

Run `make build` and `make test` after each change. For Swift changes, you can use `make ui` and `make test-dev` first. See [ui.md](ui.md).

`make test` tests the programs in the image, which the Linux toolchain compiled. `make test-dev` tests the programs that the macOS toolchain compiled.
