#pragma once
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

// drm_fourcc.h builds formats with a function-like macro, which Swift can't
// import. Re-export the ones we use as constants.
static const uint32_t CDRM_FORMAT_XRGB8888 = DRM_FORMAT_XRGB8888;
static const uint32_t CDRM_FORMAT_ARGB8888 = DRM_FORMAT_ARGB8888;

// The size of the cursor that the display wants, for drmGetCap.
static const uint64_t CDRM_CAP_CURSOR_WIDTH = DRM_CAP_CURSOR_WIDTH;
static const uint64_t CDRM_CAP_CURSOR_HEIGHT = DRM_CAP_CURSOR_HEIGHT;
