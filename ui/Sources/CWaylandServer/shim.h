#pragma once
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>

// In C, `struct wl_surface_interface` (the request handlers a compositor
// implements) and the variable `wl_surface_interface` (the protocol's
// description) share a name. Swift can't tell them apart, so the
// descriptions are also available through these functions.
static inline const struct wl_interface *wl_compositor_interface_ptr(void) { return &wl_compositor_interface; }
static inline const struct wl_interface *wl_surface_interface_ptr(void) { return &wl_surface_interface; }
static inline const struct wl_interface *wl_region_interface_ptr(void) { return &wl_region_interface; }
static inline const struct wl_interface *wl_callback_interface_ptr(void) { return &wl_callback_interface; }

// C code finds its object from a wl_listener with container_of(). Swift
// can't, so listeners are allocated inside this struct, next to a pointer
// back to the Swift object.
struct swift_wl_listener {
    struct wl_listener listener;
    void *context;
};

// ...and the handler structs get unambiguous names.
typedef struct wl_compositor_interface wl_compositor_requests;
typedef struct wl_surface_interface wl_surface_requests;
typedef struct wl_region_interface wl_region_requests;

// wl_resource_post_error() is variadic (printf-style), which Swift can't call.
static inline void wl_resource_post_error_message(struct wl_resource *resource,
                                                  uint32_t code, const char *message) {
    wl_resource_post_error(resource, code, "%s", message);
}
