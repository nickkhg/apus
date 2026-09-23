import Foundation
import Virtualization

/// The files that the virtual machine reads and writes. The tool runs from
/// the top of the repository, as the Makefile starts it there.
struct Layout {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    var out: URL { root.appending(path: "out") }
    var live: URL { out.appending(path: "live.img") }
    /// The copy of the live image that a boot actually uses.
    var liveBoot: URL { vm.appending(path: "live-boot.img") }
    var vm: URL { out.appending(path: "vm") }
    var target: URL { vm.appending(path: "target.img") }
    /// The screenshots that the guest writes (tests/screen.py reads them).
    var screens: URL { vm.appending(path: "screens") }
    /// The EFI variables. A fresh store each boot makes the firmware fall
    /// back to the removable media path (EFI/BOOT/BOOTAA64.EFI), exactly as
    /// a new machine would.
    var efiVariables: URL { vm.appending(path: "efi-variables") }
}

enum MachineError: Error, CustomStringConvertible {
    case noLiveImage(URL)
    case cannotCreate(URL)

    var description: String {
        switch self {
        case .noLiveImage(let url):
            "no \(url.path(percentEncoded: false)) - run 'make build' first"
        case .cannotCreate(let url):
            "cannot make \(url.path(percentEncoded: false))"
        }
    }
}

func makeConfiguration(_ options: Options, _ layout: Layout) throws -> VZVirtualMachineConfiguration {
    let files = FileManager.default
    try files.createDirectory(at: layout.vm, withIntermediateDirectories: true)
    try files.createDirectory(at: layout.screens, withIntermediateDirectories: true)

    let configuration = VZVirtualMachineConfiguration()
    configuration.cpuCount = 4
    configuration.memorySize = 2 << 30

    // EFI, as the images boot systemd-boot from the EFI system partition.
    let boot = VZEFIBootLoader()
    try? files.removeItem(at: layout.efiVariables)
    boot.variableStore = try VZEFIVariableStore(
        creatingVariableStoreAt: layout.efiVariables, options: [])
    configuration.bootLoader = boot
    configuration.platform = VZGenericPlatformConfiguration()

    configuration.storageDevices = try storage(options, layout)
    configuration.serialPorts = [console()]
    configuration.networkDevices = [network()]
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    // A socket of the machine, for the clipboard. The guest connects to it
    // and the two sides send each other text. See Clipboard.swift.
    configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    configuration.directorySharingDevices = try shares(layout)
    configuration.audioDevices = sound(options.audio)

    if options.display != .none {
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: options.screen.width, heightInPixels: options.screen.height)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    try configuration.validate()
    return configuration
}

/// The disks. In `live` mode the live image is the first disk and the target
/// is the second, as the installer writes to the second (/dev/vdb).
private func storage(
    _ options: Options, _ layout: Layout
) throws -> [VZStorageDeviceConfiguration] {
    var disks: [VZStorageDeviceConfiguration] = []
    if options.mode == .live {
        guard FileManager.default.fileExists(atPath: layout.live.path(percentEncoded: false)) else {
            throw MachineError.noLiveImage(layout.live)
        }
        try makeLiveCopy(from: layout.live, to: layout.liveBoot)
        disks.append(VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(
                url: layout.liveBoot, readOnly: false)))
    }
    try makeTargetDisk(layout.target, size: options.targetSize)
    disks.append(VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: layout.target, readOnly: false)))
    return disks
}

/// A copy of the live image for one boot, so that the boot never changes
/// out/live.img. QEMU did this with `snapshot=on`; Virtualization has no
/// such mode, so the tool makes the copy.
///
/// On APFS `clonefile` makes the copy at once, and the two files share their
/// blocks until one of them is written to. The copy therefore costs almost
/// no time and almost no disk. On other file systems the tool copies the
/// bytes.
///
/// The image must be writable: systemd-boot writes a random seed and updates
/// itself on the EFI system partition, and those services fail on a
/// read-only disk.
private func makeLiveCopy(from source: URL, to destination: URL) throws {
    let files = FileManager.default
    try? files.removeItem(at: destination)
    if clonefile(source.path(percentEncoded: false),
                 destination.path(percentEncoded: false), 0) == 0 {
        return
    }
    try files.copyItem(at: source, to: destination)
}

/// A raw disk image. Virtualization reads raw images only, so this replaces
/// the qcow2 file that `qemu-img create` made. The file is sparse: it uses
/// only the blocks that the guest writes.
private func makeTargetDisk(_ url: URL, size: UInt64) throws {
    let path = url.path(percentEncoded: false)
    guard !FileManager.default.fileExists(atPath: path) else { return }
    guard FileManager.default.createFile(atPath: path, contents: nil) else {
        throw MachineError.cannotCreate(url)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: size)
}

/// The serial console on stdin and stdout, which is how the expect tests
/// drive the guest.
private func console() -> VZSerialPortConfiguration {
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: Terminal.guestInput,
        fileHandleForWriting: GuestConsole.guestOutput)
    return port
}

/// Network address translation: the guest reaches the network through the
/// host, as QEMU's user-mode networking did.
private func network() -> VZNetworkDeviceConfiguration {
    let device = VZVirtioNetworkDeviceConfiguration()
    device.attachment = VZNATNetworkDeviceAttachment()
    return device
}

/// The sound card of the guest: a virtio sound device, with the speakers of
/// the Mac as its output. The guest needs the virtio_snd driver for it (see
/// packages/virtio-snd).
///
/// The microphone is there only when a person asks for it (VM_AUDIO=mic).
/// macOS asks the person before a program may hear the microphone, and the
/// question goes to the app that started the program, for example Terminal
/// or Xcode. A test with no person there would stop at that question, and
/// a guest that could always hear the room is not a default to give.
private func sound(_ audio: Options.Audio) -> [VZAudioDeviceConfiguration] {
    guard audio != .off else { return [] }
    let device = VZVirtioSoundDeviceConfiguration()
    let output = VZVirtioSoundDeviceOutputStreamConfiguration()
    output.sink = VZHostAudioOutputStreamSink()
    device.streams = [output]
    if audio == .mic {
        let input = VZVirtioSoundDeviceInputStreamConfiguration()
        input.source = VZHostAudioInputStreamSource()
        device.streams.append(input)
    }
    return [device]
}

/// The shared directories, over virtiofs.
///
/// `host` is out/ on the Mac, read-only, mounted at /mnt/host in the guest:
/// the `make ui` loop runs the programs from there. `screens` is writable,
/// and the guest puts screenshots in it for tests/screen.py.
private func shares(_ layout: Layout) throws -> [VZDirectorySharingDeviceConfiguration] {
    func share(tag: String, directory: URL, readOnly: Bool) throws
        -> VZVirtioFileSystemDeviceConfiguration
    {
        try VZVirtioFileSystemDeviceConfiguration.validateTag(tag)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: directory, readOnly: readOnly))
        return device
    }
    return [
        try share(tag: "host", directory: layout.out, readOnly: true),
        try share(tag: "screens", directory: layout.screens, readOnly: false),
    ]
}
