#pragma once
#include "xdg-shell-server-protocol.h"

// See CWaylandServer/shim.h: the descriptions share names with the handler
// structs, so Swift reaches them through these functions.
static inline const struct wl_interface *xdg_wm_base_interface_ptr(void) { return &xdg_wm_base_interface; }
static inline const struct wl_interface *xdg_surface_interface_ptr(void) { return &xdg_surface_interface; }
static inline const struct wl_interface *xdg_toplevel_interface_ptr(void) { return &xdg_toplevel_interface; }
static inline const struct wl_interface *xdg_positioner_interface_ptr(void) { return &xdg_positioner_interface; }

typedef struct xdg_wm_base_interface xdg_wm_base_requests;
typedef struct xdg_surface_interface xdg_surface_requests;
typedef struct xdg_toplevel_interface xdg_toplevel_requests;
typedef struct xdg_positioner_interface xdg_positioner_requests;
