import Foundation

/// The wire format of virtio-gpu, from the Virtio specification, version 1.3,
/// section 5.7. Every field is little-endian, which is what aarch64 uses, so
/// the structures go to and from memory as they are.
enum VirtioGPU {
    /// The Virtio device ID of a GPU.
    static let deviceID: UInt16 = 16
    /// PCI class 3 is a display controller, subclass 0x80 is "other". This
    /// is what QEMU gives its virtio-gpu, and the guest's driver binds on
    /// the Virtio device ID rather than on these.
    static let pciClass: UInt8 = 0x03
    static let pciSubclass: UInt8 = 0x80

    /// The feature bits of virtio-gpu, from the specification.
    enum Feature: UInt32 {
        /// The device can draw 3D, with the virgl protocol.
        case virgl = 0
        case edid = 1
        case resourceUUID = 2
        /// Resources that are memory, and can be mapped.
        case resourceBlob = 3
        /// A context says which capset it is for when it is made. Venus
        /// needs this one.
        case contextInit = 4
    }

    /// The queues: commands, then the cursor.
    static let controlQueue: UInt16 = 0
    static let cursorQueue: UInt16 = 1
    static let queueCount: UInt16 = 2

    /// The specification allows this many scanouts.
    static let maximumScanouts = 16

    enum Command: UInt32 {
        case getDisplayInfo = 0x0100
        case resourceCreate2D = 0x0101
        case resourceUnref = 0x0102
        case setScanout = 0x0103
        case resourceFlush = 0x0104
        case transferToHost2D = 0x0105
        case resourceAttachBacking = 0x0106
        case resourceDetachBacking = 0x0107
        case getCapsetInfo = 0x0108
        case getCapset = 0x0109
        case getEDID = 0x010A
        case resourceAssignUUID = 0x010B
        /// A resource that is memory. Venus uses these for everything.
        case resourceCreateBlob = 0x010C
        case setScanoutBlob = 0x010D

        // The 3D commands. A context is where the work happens: the guest
        // makes one for a capset, and then submits streams of commands to it.
        case contextCreate = 0x0200
        case contextDestroy = 0x0201
        case contextAttachResource = 0x0202
        case contextDetachResource = 0x0203
        case resourceCreate3D = 0x0204
        case transferToHost3D = 0x0205
        case transferFromHost3D = 0x0206
        case submit3D = 0x0207
        case resourceMapBlob = 0x0208
        case resourceUnmapBlob = 0x0209

        case updateCursor = 0x0300
        case moveCursor = 0x0301
    }

    /// The shared memory region that holds memory the guest can see
    /// directly. The specification calls it VIRTIO_GPU_SHM_ID_HOST_VISIBLE.
    /// Mesa's Venus requires it: without the region the guest's driver
    /// reports no VIRTGPU_PARAM_HOST_VISIBLE, and Venus takes no device.
    ///
    /// The number is 1. Zero is VIRTIO_GPU_SHM_ID_UNDEFINED. The guest's
    /// driver asks for the region by this number, and it passes over a
    /// region with another number without a word, so a wrong number here
    /// looks exactly like a device with no region at all.
    static let hostVisibleRegion: UInt8 = 1

    /// The flag in a command header that asks for a fence: the guest waits
    /// for the answer until the work is done.
    static let flagFence: UInt32 = 1

    enum Response: UInt32 {
        case okNoData = 0x1100
        case okDisplayInfo = 0x1101
        case okCapsetInfo = 0x1102
        case okCapset = 0x1103
        case okEDID = 0x1104
        case okResourceUUID = 0x1105
        /// The answer to RESOURCE_MAP_BLOB: how the guest may cache the
        /// memory it has just been given.
        case okMapInfo = 0x1106
        case errorUnspecified = 0x1200
        case errorInvalidResourceID = 0x1202
    }

    /// `struct virtio_gpu_ctrl_hdr`, 24 bytes. Every command starts with it,
    /// and every answer starts with it.
    struct Header {
        static let size = 24
        var type: UInt32
        var flags: UInt32
        var fenceID: UInt64
        var contextID: UInt32
        var ringIndex: UInt8

        /// Reads a header from the front of a command.
        init?(_ data: Data) {
            guard data.count >= Header.size else { return nil }
            type = data.value(at: 0)
            flags = data.value(at: 4)
            fenceID = data.value(at: 8)
            contextID = data.value(at: 16)
            ringIndex = data[data.startIndex + 20]
        }

        init(type: UInt32, flags: UInt32 = 0, fenceID: UInt64 = 0) {
            self.type = type
            self.flags = flags
            self.fenceID = fenceID
            contextID = 0
            ringIndex = 0
        }

        /// The header of an answer. A command with VIRTIO_GPU_FLAG_FENCE set
        /// wants its fence back in the answer.
        func answer(_ response: Response) -> Data {
            var data = Data()
            data.append(response.rawValue)
            data.append(UInt32(flags & 1))      // VIRTIO_GPU_FLAG_FENCE
            data.append(fenceID)
            data.append(contextID)
            data.append(ringIndex)
            data.append(contentsOf: [0, 0, 0])  // padding
            return data
        }
    }

    /// `struct virtio_gpu_resource_map_blob`: the guest asks for a blob to
    /// appear in the host-visible region, at this offset from its start.
    struct MapBlob {
        let resource: UInt32
        let offset: UInt64

        init?(_ data: Data) {
            guard data.count >= 16 else { return nil }
            resource = data.value(at: 0)
            // 4 bytes of padding follow the resource.
            offset = data.value(at: 8)
        }
    }

    /// `struct virtio_gpu_resp_map_info`: the answer to a map, with the way
    /// the guest may cache the memory.
    static func mapInfo(header: Header, info: UInt32) -> Data {
        var data = header.answer(.okMapInfo)
        data.append(info)
        data.append(UInt32(0))   // padding
        return data
    }

    /// `struct virtio_gpu_config`, the device-specific configuration.
    static func configuration(scanouts: UInt32, capsets: UInt32) -> Data {
        var data = Data()
        data.append(UInt32(0))   // events_read
        data.append(UInt32(0))   // events_clear
        data.append(scanouts)    // num_scanouts
        data.append(capsets)     // num_capsets
        return data
    }

    /// `struct virtio_gpu_resp_capset_info`: which capset an index holds,
    /// and how big it is.
    static func capsetInfo(header: Header, id: UInt32, version: UInt32, size: UInt32) -> Data {
        var data = header.answer(.okCapsetInfo)
        data.append(id)
        data.append(version)
        data.append(size)
        data.append(UInt32(0))   // padding
        return data
    }

    /// `struct virtio_gpu_resp_display_info`: one rectangle for each scanout,
    /// and whether it is on.
    static func displayInfo(header: Header, width: UInt32, height: UInt32) -> Data {
        var data = header.answer(.okDisplayInfo)
        for scanout in 0..<maximumScanouts {
            let used = scanout == 0
            data.append(UInt32(0))                  // x
            data.append(UInt32(0))                  // y
            data.append(used ? width : 0)
            data.append(used ? height : 0)
            data.append(UInt32(used ? 1 : 0))       // enabled
            data.append(UInt32(0))                  // flags
        }
        return data
    }
}

extension Data {
    /// Adds a value in little-endian order.
    mutating func append(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    /// Reads a little-endian value at a byte offset from the start.
    func value(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeBytes { bytes in
            for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (index * 8) }
        }
        return value
    }

    func value(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeBytes { bytes in
            for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (index * 8) }
        }
        return value
    }
}

extension VirtioGPU {
    /// `struct virtio_gpu_ctx_create`, after the header: the length of the
    /// name, then which capset the context is for, then the name.
    struct ContextCreate {
        let capset: UInt32
        let name: String

        init?(_ body: Data) {
            guard body.count >= 8 else { return nil }
            let nameLength = Int(body.value(at: 0) as UInt32)
            capset = body.value(at: 4)
            let start = body.startIndex + 8
            let end = min(start + nameLength, body.endIndex)
            name = start < end
                ? String(decoding: body[start..<end], as: UTF8.self) : ""
        }
    }

    /// `struct virtio_gpu_resource_create_blob`, after the header.
    struct CreateBlob {
        let resource: UInt32
        let memory: UInt32
        let flags: UInt32
        let blobID: UInt64
        let size: UInt64

        init?(_ body: Data) {
            guard body.count >= 32 else { return nil }
            resource = body.value(at: 0)
            memory = body.value(at: 4)
            flags = body.value(at: 8)
            // 4 bytes of padding sit between the flags and the id.
            blobID = body.value(at: 16)
            size = body.value(at: 24)
        }
    }
}
