#include "include/uinput_shim.h"

#include <fcntl.h>
#include <linux/uinput.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

const uint16_t apus_ev_key = EV_KEY;
const uint16_t apus_ev_abs = EV_ABS;
const uint16_t apus_ev_syn = EV_SYN;
const uint16_t apus_syn_report = SYN_REPORT;
const uint16_t apus_abs_x = ABS_X;
const uint16_t apus_abs_y = ABS_Y;
const uint16_t apus_btn_left = BTN_LEFT;
// The same range as QEMU used for its tablet, so a test that worked in QEMU
// puts the pointer in the same place.
const int32_t apus_abs_maximum = 32767;

int apus_uinput_open(void) {
    return open("/dev/uinput", O_WRONLY | O_NONBLOCK);
}

static int finish(int fd, const char *name) {
    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x6D64;   // "md"
    setup.id.product = 0x0001;
    strncpy(setup.name, name, UINPUT_MAX_NAME_SIZE - 1);
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) return -1;
    return ioctl(fd, UI_DEV_CREATE);
}

int apus_uinput_make_pointer(int fd) {
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE) < 0) return -1;
    if (ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0) return -1;

    struct uinput_abs_setup axis;
    memset(&axis, 0, sizeof(axis));
    axis.absinfo.minimum = 0;
    axis.absinfo.maximum = apus_abs_maximum;
    axis.code = ABS_X;
    if (ioctl(fd, UI_ABS_SETUP, &axis) < 0) return -1;
    axis.code = ABS_Y;
    if (ioctl(fd, UI_ABS_SETUP, &axis) < 0) return -1;

    return finish(fd, "Apus test pointer");
}

int apus_uinput_make_keyboard(int fd) {
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) return -1;
    // Every key from Escape to the end of the main block: enough for the
    // letters, the digits, the punctuation, Enter and the modifiers.
    for (int key = KEY_ESC; key <= KEY_COMPOSE; key++) {
        if (ioctl(fd, UI_SET_KEYBIT, key) < 0) return -1;
    }
    return finish(fd, "Apus test keyboard");
}

int apus_uinput_send(int fd, uint16_t type, uint16_t code, int32_t value) {
    struct input_event event;
    memset(&event, 0, sizeof(event));
    event.type = type;
    event.code = code;
    event.value = value;
    if (write(fd, &event, sizeof(event)) != (ssize_t)sizeof(event)) return -1;
    return 0;
}

int apus_uinput_remove(int fd) {
    return ioctl(fd, UI_DEV_DESTROY);
}
