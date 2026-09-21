// Small wrappers over /dev/uinput.
//
// Swift cannot call ioctl, because it takes a variable number of arguments.
// These functions make the two input devices that the tests need, and send
// events through them.
#ifndef APUS_UINPUT_SHIM_H
#define APUS_UINPUT_SHIM_H

#include <stdint.h>

// Opens /dev/uinput. Returns the file descriptor, or -1.
int apus_uinput_open(void);

// A pointer that reports where it is, not how far it moved: absolute X and Y
// from 0 to 32767, and the three mouse buttons. This is what QEMU's
// virtio-tablet looked like, so libinput reads it in the same way (a pointer
// with absolute motion) and the compositor needs no change.
int apus_uinput_make_pointer(int fd);

// A keyboard with the keys that the tests type.
int apus_uinput_make_keyboard(int fd);

// Sends one event. `type` and `code` are the EV_* and KEY_*/ABS_* numbers of
// the kernel.
int apus_uinput_send(int fd, uint16_t type, uint16_t code, int32_t value);

// Removes the device.
int apus_uinput_remove(int fd);

// The numbers that the Swift side needs, without importing linux/input.h.
extern const uint16_t apus_ev_key;
extern const uint16_t apus_ev_abs;
extern const uint16_t apus_ev_syn;
extern const uint16_t apus_syn_report;
extern const uint16_t apus_abs_x;
extern const uint16_t apus_abs_y;
extern const uint16_t apus_btn_left;
extern const int32_t apus_abs_maximum;

#endif
