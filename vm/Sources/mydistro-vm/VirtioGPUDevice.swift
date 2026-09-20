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
/// How wide the window of host-visible memory is. It is address space, not
/// memory: the guest maps parts of it as it needs them.
private let hostVisibleSize: UInt64 = 8 << 30

@available(macOS 27, *)
final class VirtioGPUDevice: NSObject, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    private let width: UInt32
    private let height: UInt32
    /// The bytes of the Venus capset, when the renderer has one. The guest
    /// reads it with GET_CAPSET and gives it to Mesa.
    private let venusCapset: Data
    private var device: VZCustomVirtioDevice?
    /// The window the guest can see directly. Blobs go in it, and the guest
    /// then reads and writes them without the device in the way.
    private var hostVisible: VZVirtioSharedMemoryRegion?

    /// What the guest asked for, for the log. The first stage is about
    /// whether the guest binds at all, so it counts the commands.
    private var counts: [UInt32: Int] = [:]
    private var submissions = 0
    private var blobs = 0
    private var maps = 0

    init(width: Int, height: Int, venusCapset: Data) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.venusCapset = venusCapset
    }

    /// The configuration that makes the framework create the device.
    static func configuration(width: Int, height: Int, venusCapset: Data)
        -> (VZCustomVirtioDeviceConfiguration, VirtioGPUDevice, Provider)
    {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = VirtioGPU.deviceID
        configuration.pciClassID = VirtioGPU.pciClass
        configuration.pciSubclassID = VirtioGPU.pciSubclass
        configuration.virtioQueueCount = VirtioGPU.queueCount

        // One capset, the Venus one, when the renderer gave us its bytes.
        let capsets: UInt32 = venusCapset.isEmpty ? 0 : 1
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: VirtioGPU.configuration(scanouts: 1, capsets: capsets))

        // CONTEXT_INIT lets the guest say which capset a context is for.
        // Mesa's Venus driver looks for it, and takes the device only when
        // the device offers it. It is optional: a guest that does not want
        // 3D still binds.
        if capsets > 0 {
            // VIRGL is here for the kernel, not for us. The guest's driver
            // only reports VIRTGPU_PARAM_3D_FEATURES, and only allows the
            // 3D ioctls at all, when it negotiated VIRTIO_GPU_F_VIRGL. Mesa's
            // Venus asks for that parameter before anything else and stops
            // without it. So a Venus device offers VIRGL as well, even
            // though no virgl command ever arrives.
            configuration.optionalFeatures.subset0 |=
                (1 << VirtioGPU.Feature.virgl.rawValue)
                | (1 << VirtioGPU.Feature.contextInit.rawValue)
                | (1 << VirtioGPU.Feature.resourceBlob.rawValue)
                | (1 << VirtioGPU.Feature.blobAlignment.rawValue)
        }

        // The window of memory that the guest can see directly. Venus needs
        // it, and the guest's driver only reports VIRTGPU_PARAM_HOST_VISIBLE
        // when the device has the region. The guest maps parts of it; the
        // size is the largest it can address, not memory we hold.
        let allowedRegions = VZCustomVirtioDeviceConfiguration
            .maximumAllowedSharedMemoryRegionCount
        if capsets > 0, allowedRegions > 0 {
            configuration.sharedMemoryRegions = [
                VZVirtioSharedMemoryRegionConfiguration(
                    regionID: VirtioGPU.hostVisibleRegion, size: hostVisibleSize)
            ]
        }
        log("virtio-gpu: the framework allows \(allowedRegions) shared memory regions; "
            + "the device has \(configuration.sharedMemoryRegions.count)")

        let delegate = VirtioGPUDevice(width: width, height: height, venusCapset: venusCapset)
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
            delegate.hostVisible = device.sharedMemoryRegions.first {
                $0.regionID == VirtioGPU.hostVisibleRegion
            }
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
        // A map goes to the framework and answers when the framework is
        // done, so that command keeps the element and gives it back itself.
        var answersLater = false
        defer { if !answersLater { element.returnToQueue() } }

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

        case .getCapsetInfo:
            // The command holds the index of the capset that the guest asks
            // about. We have one, and it is Venus.
            log("VIRTIO-GPU-CAPSET-INFO the guest asked which capsets there are")
            write(VirtioGPU.capsetInfo(header: header, id: 4, version: 0,
                                       size: UInt32(venusCapset.count)), to: element)

        case .getCapset:
            log("VIRTIO-GPU-CAPSET the guest read the Venus capset, \(venusCapset.count) bytes")
            var answer = header.answer(.okCapset)
            answer.append(venusCapset)
            write(answer, to: element)

        // The 3D commands go to the renderer.
        case .contextCreate:
            handleContextCreate(header, element)

        case .contextDestroy:
            renderer { VirglRenderer.destroyContext(id: header.contextID) }
            write(header.answer(.okNoData), to: element)

        case .contextAttachResource, .contextDetachResource:
            // The body is one resource id.
            let resource: UInt32 = (try? element.readBytes(withExactLength: 8))?.value(at: 0) ?? 0
            renderer {
                if command == .contextAttachResource {
                    VirglRenderer.attach(resource: resource, toContext: header.contextID)
                } else {
                    VirglRenderer.detach(resource: resource, fromContext: header.contextID)
                }
            }
            write(header.answer(.okNoData), to: element)

        case .submit3D:
            handleSubmit(header, element)

        case .resourceCreateBlob:
            handleCreateBlob(header, element)

        case .resourceMapBlob:
            answersLater = handleMapBlob(header, element)

        case .resourceUnmapBlob:
            let resource: UInt32 = (try? element.readBytes(withExactLength: 8))?.value(at: 0) ?? 0
            handleUnmapBlob(resource, header, element)

        case .resourceUnref:
            let resource: UInt32 = (try? element.readBytes(withExactLength: 8))?.value(at: 0) ?? 0
            renderer { VirglRenderer.unref(resource: resource) }
            write(header.answer(.okNoData), to: element)

        // The 2D commands are still answered without the work. A guest that
        // draws through Venus does not use them.
        default:
            write(header.answer(.okNoData), to: element)
        }
    }

    /// Runs a piece of work on the renderer, when there is one.
    private func renderer(_ body: () -> Void) {
        #if VIRGL
        body()
        #endif
    }

    private func handleContextCreate(_ header: VirtioGPU.Header, _ element: VZVirtioQueueElement) {
        // 8 bytes of fields, then up to 64 bytes of name.
        let bodyLength = min(element.readBuffersAvailableByteCount, 72)
        guard bodyLength >= 8, let body = try? element.readBytes(withExactLength: bodyLength),
              let create = VirtioGPU.ContextCreate(body) else {
            write(header.answer(.errorUnspecified), to: element)
            return
        }
        var result: Int32 = 0
        renderer {
            result = VirglRenderer.createContext(id: header.contextID,
                                                 capset: create.capset, name: create.name)
        }
        log("VIRTIO-GPU-CONTEXT the guest made context \(header.contextID) "
            + "for capset \(create.capset) (\(create.name)), result \(result)")
        write(header.answer(result == 0 ? .okNoData : .errorUnspecified), to: element)
    }

    private func handleSubmit(_ header: VirtioGPU.Header, _ element: VZVirtioQueueElement) {
        // `struct virtio_gpu_cmd_submit`: the size of the stream, then
        // padding, then the stream itself.
        guard let fields = try? element.readBytes(withExactLength: 8) else {
            write(header.answer(.errorUnspecified), to: element)
            return
        }
        let size = Int(fields.value(at: 0) as UInt32)
        guard size > 0, size <= element.readBuffersAvailableByteCount,
              var stream = (try? element.readBytes(withExactLength: size)).map({ [UInt8]($0) })
        else {
            write(header.answer(.errorUnspecified), to: element)
            return
        }

        var result: Int32 = 0
        renderer {
            result = VirglRenderer.submit(&stream, context: header.contextID)
            // A guest that asked for a fence waits for the work, so let the
            // renderer finish what it can before the answer goes back.
            if header.flags & VirtioGPU.flagFence != 0 { VirglRenderer.poll() }
        }
        submissions += 1
        if submissions <= 3 || submissions % 500 == 0 {
            log("VIRTIO-GPU-SUBMIT stream \(submissions) of \(size) bytes to context "
                + "\(header.contextID), result \(result)")
        }
        write(header.answer(result == 0 ? .okNoData : .errorUnspecified), to: element)
    }

    private func handleCreateBlob(_ header: VirtioGPU.Header, _ element: VZVirtioQueueElement) {
        guard let body = try? element.readBytes(withExactLength: 32),
              let blob = VirtioGPU.CreateBlob(body) else {
            write(header.answer(.errorUnspecified), to: element)
            return
        }
        var result: Int32 = 0
        renderer {
            result = VirglRenderer.createBlob(
                resource: blob.resource, context: header.contextID, memory: blob.memory,
                flags: blob.flags, blobID: blob.blobID, size: blob.size)
        }
        blobs += 1
        if blobs <= 3 {
            log("VIRTIO-GPU-BLOB resource \(blob.resource), \(blob.size) bytes, "
                + "memory \(blob.memory), result \(result)")
        }
        write(header.answer(result == 0 ? .okNoData : .errorUnspecified), to: element)
    }

    /// Puts a blob in the window the guest can see, at the offset the guest
    /// asks for. Gives back true when it keeps the element to answer later.
    ///
    /// The framework maps the memory on its own time and calls back on this
    /// queue, so the answer goes out from the callback and the element goes
    /// back to the queue there.
    private func handleMapBlob(
        _ header: VirtioGPU.Header, _ element: VZVirtioQueueElement
    ) -> Bool {
        guard let body = try? element.readBytes(withExactLength: 16),
              let map = VirtioGPU.MapBlob(body), let hostVisible else {
            write(header.answer(.errorUnspecified), to: element)
            return false
        }

        var found: (address: UnsafeMutableRawPointer, size: UInt64)?
        var info: UInt32 = 0
        renderer {
            found = VirglRenderer.map(resource: map.resource)
            info = VirglRenderer.mapInfo(resource: map.resource)
        }
        guard let found else {
            log("virtio-gpu: resource \(map.resource) has no memory to map")
            write(header.answer(.errorUnspecified), to: element)
            return false
        }

        // The framework wants the offset and the size in whole host pages.
        // A blob is not always that large, and the page the memory ends in
        // is mapped to its end anyway, so the size rounds up.
        let page = UInt64(getpagesize())
        let size = (found.size + page - 1) / page * page
        maps += 1
        if maps <= 3 {
            log("VIRTIO-GPU-MAP resource \(map.resource) at offset \(map.offset), "
                + "\(found.size) bytes as \(size), cache \(info)")
        }

        hostVisible.mapMemory(found.address, atOffset: map.offset, size: size) { error in
            if let error {
                log("virtio-gpu: the map of resource \(map.resource) failed: "
                    + error.localizedDescription)
                self.write(header.answer(.errorUnspecified), to: element)
            } else {
                self.write(VirtioGPU.mapInfo(header: header, info: info), to: element)
            }
            element.returnToQueue()
        }
        return true
    }

    /// Takes a blob out of the window again. The guest asks for this before
    /// it lets the resource go.
    private func handleUnmapBlob(
        _ resource: UInt32, _ header: VirtioGPU.Header, _ element: VZVirtioQueueElement
    ) {
        renderer { VirglRenderer.unmap(resource: resource) }
        write(header.answer(.okNoData), to: element)
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

    // The renderer of this side. Without it the device carries no 3D, and
    // the guest sees a plain 2D device.
    var venusCapset = Data()
    #if VIRGL
    do {
        try VirglRenderer.start()
        // Venus answers with a version of 0 always; the size is the sign.
        let venus = VirglRenderer.capset(.venus)
        if venus.size > 0 {
            venusCapset = VirglRenderer.capsetData(.venus, version: venus.version,
                                                   size: venus.size)
            let head = venusCapset.withUnsafeBytes { raw in
                stride(from: 0, to: min(32, raw.count), by: 4).map { offset in
                    String(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                }.joined(separator: " ")
            }
            log("VIRGL-VENUS the renderer offers Venus, \(venusCapset.count) bytes of capset")
            log("VIRGL-VENUS-CAPSET first words: \(head)")
        } else {
            log("VIRGL-NO-VENUS the renderer answered with no Venus capset")
        }
    } catch {
        log("virglrenderer: \(error)")
    }
    #else
    log("built with no renderer; run build/make-virglrenderer.sh for a guest with a GPU")
    #endif
    let (deviceConfiguration, delegate, provider) = VirtioGPUDevice.configuration(
        width: options.screen.width, height: options.screen.height, venusCapset: venusCapset)
    configuration.customVirtioDevices = [deviceConfiguration]
    log("a virtio-gpu device of our own is on the machine (VM_CUSTOM_GPU=1)")
    return [delegate, provider]
}
