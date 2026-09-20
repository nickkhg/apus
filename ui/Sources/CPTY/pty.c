#define _GNU_SOURCE

#include "pty.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>

int mydistro_pty_open(char *name, int length) {
    int fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (fd < 0) {
        return -1;
    }
    if (grantpt(fd) != 0 || unlockpt(fd) != 0 || ptsname_r(fd, name, (size_t)length) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int mydistro_pty_set_size(int fd, int columns, int rows, int width, int height) {
    struct winsize size;
    size.ws_col = (unsigned short)columns;
    size.ws_row = (unsigned short)rows;
    size.ws_xpixel = (unsigned short)width;
    size.ws_ypixel = (unsigned short)height;
    return ioctl(fd, TIOCSWINSZ, &size);
}
