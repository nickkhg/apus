#pragma once
#include "xdg-shell-client-protocol.h"

// See CWaylandClient/shim.h.
static inline const struct wl_interface *xdg_wm_base_interface_ptr(void) { return &xdg_wm_base_interface; }
