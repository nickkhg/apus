#pragma once
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

// Protocol descriptions are `extern const` variables, and wl_registry_bind()
// needs their address. Swift can only pass a copy, so these return the address.
static inline const struct wl_interface *wl_compositor_interface_ptr(void) { return &wl_compositor_interface; }
static inline const struct wl_interface *wl_shm_interface_ptr(void) { return &wl_shm_interface; }
static inline const struct wl_interface *wl_seat_interface_ptr(void) { return &wl_seat_interface; }
static inline const struct wl_interface *wl_output_interface_ptr(void) { return &wl_output_interface; }
