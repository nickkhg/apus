#pragma once
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

// drm_fourcc.h builds formats with a function-like macro, which Swift can't
// import. Re-export the ones we use as constants.
static const uint32_t CDRM_FORMAT_XRGB8888 = DRM_FORMAT_XRGB8888;
static const uint32_t CDRM_FORMAT_ARGB8888 = DRM_FORMAT_ARGB8888;

// Whether a virtio-gpu card carries 3D, which is how the guest tells the
// display of the framework from the device that carries the GPU of the Mac.
// The numbers are the ones in <drm/virtgpu_drm.h>, which the SDK does not
// carry, and the structure has the layout that the kernel reads.
struct CDRMVirtgpuGetparam {
    uint64_t param;
    uint64_t value;
};
static const unsigned long CDRM_IOCTL_VIRTGPU_GETPARAM =
    DRM_IOWR(DRM_COMMAND_BASE + 0x03, struct CDRMVirtgpuGetparam);
static const uint64_t CDRM_VIRTGPU_PARAM_3D_FEATURES = 1;

// The size of the cursor that the display wants, for drmGetCap.
static const uint64_t CDRM_CAP_CURSOR_WIDTH = DRM_CAP_CURSOR_WIDTH;
static const uint64_t CDRM_CAP_CURSOR_HEIGHT = DRM_CAP_CURSOR_HEIGHT;
