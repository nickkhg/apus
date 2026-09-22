#pragma once
// Linux kernel interfaces that the Swift Glibc module does not include.
// Headers only: no C code and no library.
#include <sys/epoll.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
// AF_VSOCK, the socket family that reaches the machine running the VM. The
// compositor carries the clipboard over it (Compositor/HostClipboard.swift).
//
// <linux/vm_sockets.h> is a kernel header, and it cannot be included beside
// <sys/socket.h> of the C library without the two disagreeing about the
// socket types. The few things that are needed are therefore written out
// here. They are a kernel interface, so they do not change.
#define APUS_AF_VSOCK 40
#define APUS_VMADDR_CID_HOST 2

/// `struct sockaddr_vm` of <linux/vm_sockets.h>. It is the size of a
/// `struct sockaddr`, and the padding at the end is what makes it so.
struct apus_sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_flags;
    unsigned char svm_zero[3];
};

static const int apus_af_vsock = APUS_AF_VSOCK;
static const unsigned int apus_vsock_host_cid = APUS_VMADDR_CID_HOST;
