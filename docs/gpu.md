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
| Guest | The app, or the compositor | Makes Vulkan calls (GLES goes through Zink first) |
| Guest | Mesa `venus` | Turns the calls into a stream of commands |
| Guest | `virtio_gpu` | Sends the stream over the queues of the device |
| Mac | `VirtioGPUDevice` | Reads the queues and the shared memory |
| Mac | virglrenderer | Reads the stream and makes the same Vulkan calls |
| Mac | MoltenVK | Turns Vulkan into Metal |
| Mac | Metal | The GPU |

Virtio-gpu carries the two things a transport needs: a channel (the queues) and shared memory (`VZVirtioSharedMemoryRegionConfiguration`). `VZCustomVirtioDevice` gives both.

## What works

The guest binds to a device that this program makes:

```
VIRTIO-GPU-BOUND the guest driver accepted the device
VIRTIO-GPU-DISPLAY-INFO the guest asked for the size of the screen
virtio5 id=0x0010 driver=virtio_gpu
[drm] pci: virtio-gpu-pci detected at 0000:00:0c.0
[drm] Initialized virtio_gpu 0.1.0
```

`VM_CUSTOM_GPU=1` adds the device, beside the one the framework gives, so nothing that works today changes. The guest needed no change at all.

virglrenderer builds for the Mac, with Venus and without the OpenGL renderer. `build/make-virglrenderer.sh` does it, and it takes approximately one minute:

```sh
brew install meson ninja vulkan-headers vulkan-loader molten-vk
build/make-virglrenderer.sh
```

It gives `build/cache/virglrenderer/build/src/libvirglrenderer.dylib`, which holds `virgl_renderer_init`, the context calls and the Metal helpers of Venus. virglrenderer finds Vulkan at run time, so MoltenVK answers.

Two things in that build are not the defaults:

- The Venus protocol at the pinned version 1.1.3 has no Metal header. The build takes the `main` branch.
- The Metal part of Venus includes the protocol headers by the name that an install gives them (`venus-protocol/...`). As a subproject they keep their own name, so the script makes that name point to them.

## The work that remains

1. The 2D command set of the device: resources, backing pages, transfers to the host, scanout and flush. The device answers `GET_DISPLAY_INFO` and accepts the rest without doing the work.
2. `VIRTIO_GPU_F_CONTEXT_INIT` and a Venus capset, so that Mesa in the guest chooses the device.
3. virglrenderer behind the device: the blob resources, the shared memory regions and the fences that it needs.
4. The guest: the `vulkan-virtio` package for Venus, and Zink for the GLES that the compositor draws with.

## The other way

libkrun already does all of this, with the same virglrenderer, Venus and MoltenVK. It uses Hypervisor.framework, not Virtualization, so it gives up the Xcode build and debug of `mydistro-vm`. It is the shorter way to a guest with a GPU, and the longer way keeps one program in Swift.
