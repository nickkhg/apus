# A GPU for the guest

Apple's Virtualization framework gives a Linux guest no GPU. This document says what we do about it, and where the work is.

## The problem

`VZVirtioGraphicsDeviceConfiguration` is a 2D scanout. It never offers the 3D feature bit, so Mesa in the guest falls back to llvmpipe and draws with the CPU. The 3D graphics device of the framework, `VZMacGraphicsDeviceConfiguration`, accepts macOS guests only.

The compositor can draw with a GPU (see [ui.md](ui.md#the-two-renderers)), but in a VM it has none. These are the times of one frame, measured with `APUS_FRAME_LOG`:

| Renderer | Size | Average | Frames a second |
|---|---|---|---|
| `cpu` | 2560x1600 | 37.1 ms | 27 |
| `gpu` | 2560x1600 | 49.4 ms | 20 |

The GPU renderer is the slower one, because llvmpipe is under it.

## The design

macOS 27 added `VZCustomVirtioDevice`. A program can be a Virtio device itself: it chooses the device ID, the feature bits, the queues and the shared memory. So apus-vm is the GPU device, and it offers what the framework will not.

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

`make test-venus` checks this. It also starts the compositor on that GPU and compares the picture with the one the CPU draws. It needs the renderer, which the next section builds, so `make test` leaves it out.

The device also draws. It carries the 2D commands, so the compositor runs on it alone:

```sh
APUS_DRM_DEVICE=/dev/dri/card1 apus-compositor
```

`VM_SNAPSHOT` names a PNG file, and every flush replaces it. Virtualization has no screenshot of its own, which is why the tests read the screen inside the guest. With a device of our own the host holds the pixels, so it can write them, with no help from the guest.

The program adds the device beside the one the framework gives, so nothing that works today changes. `make test` passes with the device off, which is the default.

## How to build it

`make vm` builds the renderer, so a person who clones the repository gets a GPU without a separate step. It takes approximately one minute the first time.

virglrenderer builds for the Mac, with Venus and without the OpenGL renderer. `build/make-virglrenderer.sh` does it. The script installs the Homebrew formulae that the build needs (`meson`, `ninja`, `vulkan-headers`, `vulkan-loader` and `molten-vk`), and `make virgl` runs the script by itself.

The script gives `build/cache/virglrenderer/build/src/libvirglrenderer.dylib`. The Makefile finds that file and builds `apus-vm` with the renderer in it.

A Mac with no Homebrew cannot build the renderer. The build then says so and goes on, and the program carries no 3D. `vm/Sources/apus-vm/VirglRendererMissing.swift` is what the device calls in such a build. It answers each call with "no renderer", so the guest gets a 2D device.

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

## How the compositor reaches the GPU

The compositor draws with GLES, and Zink is Mesa's OpenGL on Vulkan. Two things stood in the way, and a third was in this program.

**Zink asks for a feature that MoltenVK does not have.**

```
MESA: error: Zink requires the nullDescriptor feature of KHR/EXT robustness2.
```

`MVKDevice.mm` states it as a constant, because Metal has no null descriptor:

```objc
robustness2Features->nullDescriptor = false;
```

The feature says what a shader reads from a descriptor that has nothing bound. A shader that binds everything it reads never asks the question. The compositor's four shaders bind everything they read. So `packages/apus-zink` builds Zink without the check, and `tests/venus.exp` compares what it draws with what the CPU draws, pixel by pixel. The driver goes in a directory of its own, and `apus-gpu` puts a program on it. A driver with a check removed is not for everything on the system.

**GBM needs a dma-buf, and this Vulkan has none.** A compositor normally hands each frame to the screen through GBM. A GBM buffer is a dma-buf with a DRM format modifier. Venus offers those only when the renderer on the host can export one, and Metal has nothing to export. The device in the guest reports none of `VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier`, `VK_EXT_queue_family_foreign` or `VK_KHR_external_memory_fd`.

So the GPU draws into memory instead. EGL takes a device with no window, GLES draws into a texture, and the compositor reads that frame back into the buffer the screen shows. That costs one copy of the screen for each frame and needs nothing that is missing. `OffscreenRasterizer` holds it, and the GLES renderer above it is the same `GLRenderer` that GPUScreen uses. `APUS_RENDERER=gpu` tries GBM first, falls back to this, and then to the CPU.

**EGL took the wrong device.** A machine with our device has two, and only one of them carries Venus. The surfaceless platform takes the first it finds. Zink then looks for a Vulkan device with the same DRM number, finds none, and EGL ends with no driver at all. The device platform names the device instead, so the compositor asks EGL for its devices and takes the first that draws with a GPU. `APUS_RENDER_NODE` names one and stops the search.

With those, `make demo` draws the shell with the GPU of the Mac:

```
GPU-RENDERER zink Vulkan 1.4(Virtio-GPU Venus (Apple M2 Pro) (MOLTENVK))
```

## Fences

A command with `VIRTIO_GPU_FLAG_FENCE` asks the device to answer only once the renderer finishes the work behind it. An answer at once tells the guest that the GPU finished when it did not. A frame read back then is half drawn, and it was: the picture stopped at a line across the middle of the screen.

The device now holds the answer until virglrenderer says it finished the work. Two things about that on a Mac:

- The renderer would ring an eventfd, and macOS has none: virglrenderer builds with `HAVE_EVENTFD_H` undefined, so `create_eventfd` answers -1 and no fence is ever reported. So `VIRGL_RENDERER_THREAD_SYNC` and `VIRGL_RENDERER_ASYNC_FENCE_CB` are not set, and the device reads the numbers out of shared memory itself, once a millisecond, and only while an answer waits.
- It reads them for the contexts it knows. `virgl_renderer_poll` walks every context the renderer holds, and it walks into ones that are gone.

One fault in this program is worth writing down. virglrenderer keeps the pointer to its callbacks. A structure on the stack of the function that starts it therefore looks right until the first fence. Then the renderer calls whatever the stack holds by then, and the program stops with its program counter in the stack.

## The work that remains

1. The read back of each frame is a copy of the screen. A frame that the GPU drew into memory the guest can see, and that the device then scans out, would cost nothing. That needs the device to carry `SET_SCANOUT_BLOB`, and the compositor to draw into a blob.
2. The 2D command set carries a picture, and no more. The device takes a resource of any size and shows it, and it reads every transfer as a whole rectangle. Cursors go through the second queue, and the device does not answer them.
3. The GPU is not yet faster than the CPU for what the shell draws. With an empty desktop at 2560x1600, and the shell drawing its shadows and gradients, one frame takes:

| Renderer | Average | Longest | Frames a second |
|---|---|---|---|
| `cpu` | 14.9 ms | 19.1 ms | 67 |
| `gpu` (Venus, Metal) | 16.5 ms | 23.0 ms | 61 |

   The GPU draws the frame and the compositor then reads it back. That read copies the whole screen, whatever the frame holds. An empty desktop is little work to draw, so the copy is most of the time. Item 1 takes the copy away.

## The other way

libkrun already does all of this, with the same virglrenderer, Venus and MoltenVK. It uses Hypervisor.framework, not Virtualization, so it gives up the Xcode build and debug of `apus-vm`. It is the shorter way to a guest with a GPU, and the longer way keeps one program in Swift.
