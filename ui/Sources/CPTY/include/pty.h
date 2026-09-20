// The parts of a pseudo terminal that Swift cannot do itself: ioctl() is a
// variadic C function, and the functions that open a pseudo terminal are
// behind feature macros that the Swift Glibc module does not set.
#ifndef MYDISTRO_PTY_H
#define MYDISTRO_PTY_H

/// Opens a pseudo terminal and unlocks it. Gives the file descriptor of the
/// first end, and writes the name of the other end into `name`. Gives -1
/// with errno set if it fails.
int mydistro_pty_open(char *name, int length);

/// Tells the programs in the terminal how large it is, in characters and in
/// pixels. Gives 0, or -1 with errno set.
int mydistro_pty_set_size(int fd, int columns, int rows, int width, int height);

#endif
