#!/usr/bin/env python3
"""Teaches Mesa's Venus driver the step between blobs that the device asks for.

The guest puts each blob in the host-visible window straight after the one
before it, so the step between blob sizes is also the step between the
offsets it asks the device to map. macOS maps memory in whole pages of
16384 bytes and refuses any other offset.

virtio-gpu has a feature for this: VIRTIO_GPU_F_BLOB_ALIGNMENT. The device
says the step in its configuration, and the guest's kernel then refuses any
blob whose size is not a whole number of steps. The kernel half is there
(VIRTGPU_PARAM_BLOB_ALIGNMENT); Mesa never asks for the number, so it keeps
counting in 4096 and every blob after the first lands at an offset the Mac
cannot map. This adds the half that is missing.

See docs/gpu.md.
"""
import sys

path = sys.argv[1]
source = open(path).read()


def replace(old, new):
    global source
    if old not in source:
        sys.exit(f"blob-alignment.py: this part of {path} has changed:\n{old}")
    source = source.replace(old, new, 1)


# Mesa carries its own copy of the kernel header, and that copy is older
# than the parameter. The number is 9, from include/uapi/drm/virtgpu_drm.h.
replace(
    '#include "vn_renderer_internal.h"',
    '''#include "vn_renderer_internal.h"

#ifndef VIRTGPU_PARAM_BLOB_ALIGNMENT
#define VIRTGPU_PARAM_BLOB_ALIGNMENT 9
#endif''',
)

# The step, kept next to the other numbers the device reports.
replace(
    """   uint32_t shmem_blob_mem;
   uint32_t bo_blob_mem;
""",
    """   uint32_t shmem_blob_mem;
   uint32_t bo_blob_mem;

   /* The step between blobs, from VIRTGPU_PARAM_BLOB_ALIGNMENT. A device
    * that does not report one takes any size, so the step is one byte.
    */
   uint64_t blob_align;
""",
)

# Ask for the step where the other parameters are read.
replace(
    """   /* Cross-device feature is optional.""",
    """   val = virtgpu_ioctl_getparam(gpu, VIRTGPU_PARAM_BLOB_ALIGNMENT);
   gpu->blob_align = val ? val : 1;

   /* Cross-device feature is optional.""",
)

# Round every blob up to a whole number of steps. Two kinds of blob go to
# the device: the shared memory the rings live in, and device memory.
replace(
    """   struct virtgpu *gpu = (struct virtgpu *)renderer;

   struct vn_renderer_shmem *cached_shmem =
      vn_renderer_shmem_cache_get(&gpu->shmem_cache, size);""",
    """   struct virtgpu *gpu = (struct virtgpu *)renderer;

   size = (size + gpu->blob_align - 1) & ~(gpu->blob_align - 1);

   struct vn_renderer_shmem *cached_shmem =
      vn_renderer_shmem_cache_get(&gpu->shmem_cache, size);""",
)

replace(
    """   struct virtgpu *gpu = (struct virtgpu *)renderer;
   const uint32_t blob_flags =
      virtgpu_bo_blob_flags(gpu, flags, external_handles);""",
    """   struct virtgpu *gpu = (struct virtgpu *)renderer;
   const uint32_t blob_flags =
      virtgpu_bo_blob_flags(gpu, flags, external_handles);

   size = (size + gpu->blob_align - 1) & ~(gpu->blob_align - 1);""",
)

open(path, "w").write(source)
print(f"blob-alignment.py: patched {path}")
