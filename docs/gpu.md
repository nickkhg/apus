# A GPU for the guest

Apple's Virtualization framework gives a Linux guest no GPU. This document says what we do about it, and where the work is.

## The problem

`VZVirtioGraphicsDeviceConfiguration` is a 2D scanout. It never offers the 3D feature bit, so Mesa in the guest falls back to llvmpipe and draws with the CPU. The 3D graphics device of the framework, `VZMacGraphicsDeviceConfiguration`, accepts macOS guests only.

The compositor can draw with a GPU (see [ui.md](ui.md#the-two-renderers)), but in a VM it has none. These are the times of one frame, measured with `MYDISTRO_FRAME_LOG`:

| Renderer | Size | Average | Frames a second |
|---|---|---|---|
| `cpu` | 2560x1600 | 37.1 ms | 27 |
| `gpu` | 2560x1600 | 49.4 ms | 20 |

The GPU renderer is the slower one, because llvmpipe is under it.

## The design

macOS 27 added `VZCustomVirtioDevice`. A program can be a Virtio device itself: it chooses the device ID, the feature bits, the queues and the shared memory. So mydistro-vm is the GPU device, and it offers what the framework will not.

The parts, from the app in the guest to the Mac:

| Where | Part | What it does |
|---|---|---|
| Guest | The app | Makes Vulkan calls |
| Guest | Mesa `venus` | Turns the calls into a stream of commands |
| Guest | `virtio_gpu` | Sends the stream over the queues of the device |
| Mac | `VirtioGPUDevice` | Reads the queues and the shared memory |
| Mac | virglrenderer | Reads the stream and makes the same Vulkan calls |
| Mac | MoltenVK | Turns Vulkan into Metal |
| Mac | Metal | The GPU |

Virtio-gpu carries the two things a transport needs: a channel (the queues) and shared memory (`VZVirtioSharedMemoryRegionConfiguration`). `VZCustomVirtioDevice` gives both.

## What works

Vulkan in the guest runs on the GPU of the Mac. `VM_CUSTOM_GPU=1` adds the device, and `vulkaninfo` in the guest answers:

```
GPU0:
	apiVersion    = 1.4.343
	driverVersion = 26.2.3
	vendorID      = 0x106b
	deviceName    = Virtio-GPU Venus (Apple M2 Pro)
	driverID      = DRIVER_ID_MESA_VENUS
```

`0x106b` is Apple. Every call the guest makes goes through Venus to MoltenVK and then to Metal.

The program adds the device beside the one the framework gives, so nothing that works today changes. `make test` passes with the device off, which is the default.

## How to build it

virglrenderer builds for the Mac, with Venus and without the OpenGL renderer. `build/make-virglrenderer.sh` does it, and it takes approximately one minute:

```sh
brew install meson ninja vulkan-headers vulkan-loader molten-vk
build/make-virglrenderer.sh
```

It gives `build/cache/virglrenderer/build/src/libvirglrenderer.dylib`. The Makefile finds that file and builds `mydistro-vm` with the renderer in it. Without the file the program still builds, and the device carries no 3D.

Four things in that build are not the defaults:

- The Venus protocol at the pinned version 1.1.3 has no Metal header. The build takes the `main` branch.
- The Metal part of Venus includes the protocol headers by the name that an install gives them (`venus-protocol/...`). As a subproject they keep their own name, so the script makes that name point to them.
- `render-server-mode=thread` keeps Venus in the same process, as a thread. The other mode starts a second program and talks to it over a socket.
- The program carries the Homebrew directories of the Vulkan loader and MoltenVK as run paths. virglrenderer opens Vulkan by name at run time. For a name with no directory in it, dyld looks along the run paths of the program.

## The four faults that hid each other

Each one looked like the guest simply not wanting the device.

**The shared memory region had the wrong number.** `VIRTIO_GPU_SHM_ID_HOST_VISIBLE` is 1. Zero is `VIRTIO_GPU_SHM_ID_UNDEFINED`. The guest looks for the region by number. It passes over a region with another number without a word. So the guest reported `-host_visible` and said nothing more. The PCI capability was correct the whole time.

**The renderer answered every capset with zeros.** virglrenderer fills the Venus capset only when it has a render server. It starts one only for `VIRGL_RENDERER_RENDER_SERVER`. Without the flag the *size* of the capset still reads 160. That number is a `sizeof` and not an answer. So the device looked as if it had Venus. The guest read a wire format version of zero and stopped.

**The renderer could not find Vulkan.** See the run paths above.

**The answer to `RESOURCE_MAP_BLOB` had the wrong number.** `VIRTIO_GPU_RESP_OK_MAP_INFO` is `0x1106`. `VIRTIO_GPU_RESP_OK_RESOURCE_UUID` sits between it and the EDID answer.

One more thing is worth writing down. A Venus device must offer `VIRTIO_GPU_F_VIRGL` as well. The guest reports `VIRTGPU_PARAM_3D_FEATURES` only when it negotiated that bit, and it allows the 3D calls only then. Mesa asks for the parameter first. No virgl command ever arrives.

## The step between blobs

The guest puts each blob in the host-visible window straight after the one before it. So the step between blob sizes is also the step between the offsets it asks the device to map. Linux rounds a blob to its own page, which is 4096 bytes. macOS maps memory in whole pages of 16384 and refuses any other offset. The device placed the first blob and could not place the second.

Nothing on the host can mend this. A mapping can only start on a page boundary. Two blobs that share a page therefore cannot both go in. The guest is the only side that decides where a blob starts.

virtio-gpu has a feature for exactly this: `VIRTIO_GPU_F_BLOB_ALIGNMENT`. The device states the step in its configuration, and the guest then rounds every blob up to it. Linux carries its half as `VIRTGPU_PARAM_BLOB_ALIGNMENT`. Mesa never asks for the number. `packages/vulkan-virtio` adds the half that was missing, as a patch of about ten lines over Mesa 26.2.3. The build takes the Vulkan driver alone, so it needs neither LLVM nor Rust, and it finishes in approximately one minute.

## What the compositor cannot do yet

The compositor draws with GLES (see [ui.md](ui.md#the-two-renderers)). The usual way to put GLES on Vulkan is Zink, and Zink does not start here:

```
MESA: error: Zink requires the nullDescriptor feature of KHR/EXT robustness2.
```

MoltenVK sets that feature to false, and not by accident. `MVKDevice.mm` states it as a constant:

```objc
robustness2Features->nullDescriptor = false;
```

Metal has no null descriptor, and Zink puts `VK_NULL_HANDLE` in a descriptor for every slot a shader does not use. No setting and no newer MoltenVK changes this. `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1` does not change it either.

So the compositor keeps llvmpipe for now, and a guest program that speaks Vulkan gets the GPU. To give the compositor the GPU, one of these has to happen:

1. The compositor draws with Vulkan, beside the GLES renderer it has. This is the way that depends on nobody else. It is approximately the size of `GLRenderer.swift`, with the shaders built to SPIR-V.
2. Zink stops needing `nullDescriptor`, or MoltenVK starts answering it. Both are upstream work.

## The work that remains

1. The 2D command set of the device: resources, backing pages, transfers to the host, scanout and flush. The device answers `GET_DISPLAY_INFO` and accepts the rest without doing the work. Until someone writes it, the window shows the graphics device of the framework, and the device we make draws nothing.
2. Fences. The device answers at once, so a guest that waits for work to finish is told it already has.
3. A Vulkan renderer for the compositor, which is where the frame times above would change.

## The other way

libkrun already does all of this, with the same virglrenderer, Venus and MoltenVK. It uses Hypervisor.framework, not Virtualization, so it gives up the Xcode build and debug of `mydistro-vm`. It is the shorter way to a guest with a GPU, and the longer way keeps one program in Swift.
