# The system: live image, installer, and boot

## The live image

`systemd-repart` writes `out/live.img` from the definitions in `image/repart.d/`. The image has a GPT partition table with two partitions:

| Partition | Type | Size | UUID | Content |
|---|---|---|---|---|
| 1 | EFI system partition (FAT32) | 512 MB | `6d79646f-...-000000000001` | systemd-boot, kernel, initramfs, device trees |
| 2 | Linux root (ARM-64), ext4 | Size of the contents | `6d79646f-...-000000000002` | The root file system |

The UUIDs do not change, so the boot entry and the installer can find the partitions. `6d79646f` is "mydo" in ASCII.

The boot entry is `image/esp/loader/entries/mydistro-live.conf`. Its kernel command line has these parameters:

| Parameter | Purpose |
|---|---|
| `root=PARTUUID=...0002` | The root partition. |
| `ro` | Mount the root partition read-only. |
| `systemd.volatile=overlay` | Put a RAM overlay on the root file system. All changes go into RAM. |
| `console=ttyAMA0` | Use the serial port as the console. |
| `mydistro.live` | Tells programs that this is the live system. |

The root partition does not change on the live system. Thus, the installer can copy it.

### The volatile overlay

The mkinitcpio `systemd` hook does not include `systemd-volatile-root.service`. The custom hook `rootfs/overlay/etc/initcpio/install/sd-volatile` adds the service and the `overlay` kernel module to the initramfs.

The hook only adds the service. It does not enable the service. `systemd-fstab-generator` starts the service only when the kernel command line has `systemd.volatile=`. If the service starts on every boot, it puts the root on a tmpfs and mounts only `/usr` from the disk. See [troubleshooting.md](troubleshooting.md).

### The initramfs

`rootfs/overlay/etc/mkinitcpio.conf.d/mydistro.conf` sets the hooks and the modules. The configuration has no `autodetect` hook. The build runs in a container, and the image must boot on other machines.

`rootfs/overlay/etc/mkinitcpio.d/linux-aarch64.preset` makes one initramfs. It makes no "fallback" initramfs.

## The installer

The installer is `rootfs/overlay/usr/bin/mydistro-install`.

```sh
mydistro-install            # asks for the disk
mydistro-install /dev/vdb   # asks for confirmation
mydistro-install -y /dev/vdb
```

It does these steps:

1. It makes sure that it runs on the live system as root.
2. It finds the live partitions by their fixed UUIDs, and the disk that has them.
3. It asks for the target disk, if you do not give one. It does not accept the live disk or a disk smaller than 4 GiB.
4. It mounts the live root partition read-only, and the live EFI system partition.
5. It runs `systemd-repart` with the definitions in `/usr/lib/mydistro/repart.d/`:
   - Partition 1: EFI system partition, FAT32, 512 MB, a copy of the live EFI system partition.
   - Partition 2: root, ext4, the remaining space, a copy of the files on the live root partition.
6. It writes `/etc/fstab` on the new root. The file mounts the EFI system partition at `/boot`.
7. It removes the live boot entry and writes `loader/entries/mydistro.conf` with the new root PARTUUID.
8. It writes the installation date to `/etc/mydistro-installed`.

If a command fails, the installer stops and shows the line and the command.

### Why the EFI system partition is at /boot

pacman installs the kernel to `/boot/Image`, and mkinitcpio writes `/boot/initramfs-linux.img`. On an installed system, `/boot` is the EFI system partition. Thus, kernel updates go where systemd-boot finds them.

## First boot

The image has `uninitialized` in `/etc/machine-id`. On first boot, systemd makes a new machine ID.

`mydistro-pacman-init.service` makes a pacman keyring for each system on first boot. The image has no keyring, so two systems do not share a local signing key.

The build masks `systemd-firstboot.service` and `systemd-homed-firstboot.service`. These services ask questions on the console on first boot. The build sets the locale, the time zone, and the host name, and root has no password. Thus, first boot does not stop.

The build runs `systemctl preset-all`. The image has its final set of enabled services, and first boot enables no new services.

## System configuration

| Setting | Value | Source |
|---|---|---|
| Host name | `mydistro` | `rootfs/overlay/etc/hostname` |
| Locale | `C.UTF-8` | `rootfs/overlay/etc/locale.conf` |
| Time zone | UTC | `build/build.sh` |
| Network | DHCP on wired interfaces (systemd-networkd, systemd-resolved) | `rootfs/overlay/etc/systemd/network/20-wired.network` |
| Root password | None | `build/build.sh` |

Root has no password. Change this before you use mydistro outside a VM.

## Host directory in the VM

`mnt-host.automount` mounts the `out/` directory of the Mac at `/mnt/host` (read-only, virtiofs). `mnt-screens.automount` mounts `out/vm/screens` at `/mnt/screens`, and the VM can write to it: the tests put pictures of the screen there. Both mounts work only in a VM on a Mac, because the units test `ConditionVirtualization=apple`. systemd mounts a directory when a program first uses it.
