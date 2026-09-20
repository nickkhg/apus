import Foundation
import Virtualization

/// A virtio-gpu device of our own, on VZCustomVirtioDevice.
///
/// Apple's Virtualization framework gives a Linux guest a 2D scanout only:
/// `VZVirtioGraphicsDeviceConfiguration` never offers the 3D feature bit, so
/// Mesa in the guest falls back to llvmpipe and the GPU renderer has no GPU
/// under it. macOS 26 added `VZCustomVirtioDevice`, which lets this program
/// be the device instead. A device of our own can offer the 3D feature bit.
///
/// This is the first stage: the device answers enough of the specification
/// for the guest's `virtio_gpu` driver to bind to it and read the size of the
/// screen. It draws nothing yet. The stage after it attaches a renderer on
/// the host (virglrenderer with Venus, on MoltenVK) and offers
/// VIRTIO_GPU_F_CONTEXT_INIT, which is what makes the guest's Mesa use it.
///
/// The framework calls every method here on the device's own serial queue,
/// so the state needs no lock of its own.
///
/// VZCustomVirtioDevice arrived in macOS 27, so everything here is behind
/// that version and the rest of the program runs without it.
@available(macOS 27, *)
final class VirtioGPUDevice: NSObject, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    private let width: UInt32
    private let height: UInt32
    private var device: VZCustomVirtioDevice?

    /// What the guest asked for, for the log. The first stage is about
    /// whether the guest binds at all, so it counts the commands.
    private var counts: [UInt32: Int] = [:]

    init(width: Int, height: Int) {
        self.width = UInt32(width)
        self.height = UInt32(height)
    }

    /// The configuration that makes the framework create the device.
    static func configuration(width: Int, height: Int)
        -> (VZCustomVirtioDeviceConfiguration, VirtioGPUDevice, Provider)
    {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = VirtioGPU.deviceID
        configuration.pciClassID = VirtioGPU.pciClass
        configuration.pciSubclassID = VirtioGPU.pciSubclass
        configuration.virtioQueueCount = VirtioGPU.queueCount
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: VirtioGPU.configuration(scanouts: 1, capsets: 0))

        let delegate = VirtioGPUDevice(width: width, height: height)
        let provider = Provider(delegate: delegate)
        // The provider holds its delegate weakly, so the caller keeps both.
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: DispatchQueue(label: "mydistro-vm.virtio-gpu"), delegate: provider)
        return (configuration, delegate, provider)
    }

    /// Holds the device that the framework makes, and hands it its delegate.
    @available(macOS 27, *)
    final class Provider: NSObject, VZCustomVirtioDeviceConfigurationDelegate, @unchecked Sendable {
        private let delegate: VirtioGPUDevice

        init(delegate: VirtioGPUDevice) { self.delegate = delegate }

        func customVirtioConfiguration(
            _ configuration: VZCustomVirtioDeviceConfiguration,
            didCreateDevice device: VZCustomVirtioDevice
        ) {
            device.delegate = delegate
            delegate.device = device
            log("virtio-gpu: the framework made the device")
        }
    }

    // MARK: - The device

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        let features = device.negotiatedFeatures.map { "\($0)" } ?? "none"
        log("VIRTIO-GPU-BOUND the guest driver accepted the device, features \(features)")
    }

    func customVirtioDevice(
        _ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue
    ) {
        while let element = queue.nextElement() {
            handle(element, on: queue)
        }
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        log("virtio-gpu: reset")
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        let seen = counts.keys.sorted()
            .map { "0x\(String($0, radix: 16))=\(counts[$0]!)" }
            .joined(separator: " ")
        log("virtio-gpu: stopping, commands seen: \(seen.isEmpty ? "none" : seen)")
    }

    // MARK: - Commands

    private func handle(_ element: VZVirtioQueueElement, on queue: VZVirtioQueue) {
        defer { element.returnToQueue() }

        guard element.readBuffersAvailableByteCount >= VirtioGPU.Header.size,
              let bytes = try? element.readBytes(withExactLength: VirtioGPU.Header.size),
              let header = VirtioGPU.Header(bytes)
        else {
            log("virtio-gpu: a command with no header")
            return
        }
        counts[header.type, default: 0] += 1

        guard let command = VirtioGPU.Command(rawValue: header.type) else {
            log("virtio-gpu: command 0x\(String(header.type, radix: 16)) is not one we know")
            write(header.answer(.errorUnspecified), to: element)
            return
        }

        switch command {
        case .getDisplayInfo:
            log("VIRTIO-GPU-DISPLAY-INFO the guest asked for the size of the screen")
            write(VirtioGPU.displayInfo(header: header, width: width, height: height), to: element)

        // The first stage answers the rest without doing the work, so that
        // the driver keeps going and we can see how far it gets.
        default:
            write(header.answer(.okNoData), to: element)
        }
    }

    private func write(_ data: Data, to element: VZVirtioQueueElement) {
        guard element.writeBuffersAvailableByteCount >= data.count else {
            log("virtio-gpu: no room for an answer of \(data.count) bytes")
            return
        }
        do { try element.write(data) } catch {
            log("virtio-gpu: cannot answer: \(error.localizedDescription)")
        }
    }
}

/// Adds a virtio-gpu device of our own to the configuration, when
/// VM_CUSTOM_GPU asks for it. Gives back what must stay alive: the
/// framework's provider holds its delegate weakly.
func makeCustomGPU(
    _ options: Options, _ configuration: VZVirtualMachineConfiguration
) -> [AnyObject] {
    guard options.customGPU else { return [] }
    guard #available(macOS 27, *) else {
        log("VM_CUSTOM_GPU needs macOS 27; the framework has no custom Virtio device before it")
        return []
    }
    let (deviceConfiguration, delegate, provider) = VirtioGPUDevice.configuration(
        width: options.screen.width, height: options.screen.height)
    configuration.customVirtioDevices = [deviceConfiguration]
    log("a virtio-gpu device of our own is on the machine (VM_CUSTOM_GPU=1)")
    return [delegate, provider]
}
