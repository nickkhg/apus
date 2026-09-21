#pragma once
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

// A frame is read back into one of these instead of straight into memory,
// so that the read does not wait for the GPU. GL_NV_pixel_buffer_object
// gives GLES 2 the buffer, and GL_EXT_map_buffer_range reads it. Neither
// header names these, so they are here.
static const GLenum CGLES_PIXEL_PACK_BUFFER = 0x88EB;
static const GLenum CGLES_STREAM_READ = 0x88E1;
static const GLbitfield CGLES_MAP_READ_BIT = 0x0001;
