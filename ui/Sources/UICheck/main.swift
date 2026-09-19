// mydistro-ui-check
//
// Calls into every C library the UI builds on, so that a successful run
// proves: the Swift modules compile, the program links, and the libraries
// (and data such as keymaps) are present on this system. Needs no display.

import CDRM
import CEGL
import CFreeType
import CGBM
import CGLES
import CHarfBuzz
import CInput
import CSeat
import CUdev
import CWaylandClient
import CWaylandServer
import CXKBCommon
import Glibc

var failures = 0

/// For libraries that need a device or display to do anything: taking the
/// function's address makes the linker resolve it, which is the check.
func linked<Function>(_ function: Function) -> String? {
    withExtendedLifetime(function) { "linked" }
}

@MainActor
func check(_ name: String, _ body: () -> String?) {
    if let detail = body() {
        print("ok    \(name): \(detail)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

check("libdrm") {
    // No device needed: ask whether the kernel's DRM is available at all.
    drmAvailable() == 1 ? "kernel DRM available" : "linked (no DRM in this kernel/container)"
}

check("gbm") { linked(gbm_create_device) }

check("egl") {
    // Client extensions are queryable without a display (EGL 1.5).
    guard let extensions = eglQueryString(nil, EGL_EXTENSIONS) else { return nil }
    let list = String(cString: extensions)
    return list.contains("EGL_MESA_platform_gbm") ? "Mesa, GBM platform available" : "linked"
}

check("glesv2") { linked(glGetString) }

check("libudev") {
    guard let udev = udev_new() else { return nil }
    udev_unref(udev)
    return "context created"
}

check("libinput") {
    guard let udev = udev_new() else { return nil }
    defer { udev_unref(udev) }
    // libinput opens devices through these callbacks (a compositor would ask
    // libseat instead). Swift closures without captures work as C callbacks.
    var interface = libinput_interface(
        open_restricted: { path, flags, _ in
            let fd = open(path!, flags)
            return fd < 0 ? -errno : fd
        },
        close_restricted: { fd, _ in close(fd) }
    )
    guard let context = libinput_udev_create_context(&interface, nil, udev) else { return nil }
    libinput_unref(context)
    return "context created"
}

check("xkbcommon") {
    guard let context = xkb_context_new(XKB_CONTEXT_NO_FLAGS) else { return nil }
    defer { xkb_context_unref(context) }
    // Compiling the default keymap needs the xkeyboard-config data files.
    var names = xkb_rule_names()
    guard let keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS) else {
        return nil
    }
    defer { xkb_keymap_unref(keymap) }
    return "default keymap compiled (\(xkb_keymap_num_layouts(keymap)) layout)"
}

check("libseat") { linked(libseat_open_seat) }

check("wayland-server") {
    guard let display = wl_display_create() else { return nil }
    wl_display_destroy(display)
    return "display created"
}

check("wayland-client") { linked(wl_display_connect) }

check("freetype") {
    var library: FT_Library?
    guard FT_Init_FreeType(&library) == 0, let library else { return nil }
    defer { FT_Done_FreeType(library) }
    var major: FT_Int = 0, minor: FT_Int = 0, patch: FT_Int = 0
    FT_Library_Version(library, &major, &minor, &patch)
    return "FreeType \(major).\(minor).\(patch)"
}

check("harfbuzz") {
    "HarfBuzz \(String(cString: hb_version_string()))"
}

if failures == 0 {
    print("UI-CHECK-OK")
} else {
    print("UI-CHECK-FAILED (\(failures))")
    exit(1)
}
