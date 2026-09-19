#!/usr/bin/env python3
"""Screenshot the VM through the QEMU monitor and check the probe's pattern.

    tests/screen.py MONITOR_SOCKET OUTPUT.ppm

mydistro-display-probe fills the screen with mydistro purple (0x965ADC) and
draws a white rectangle over the middle half. We check one pixel of each.
"""
import os
import socket
import sys
import time

PURPLE = (0x96, 0x5A, 0xDC)
WHITE = (0xFF, 0xFF, 0xFF)


def screendump(sock_path, out_path):
    if os.path.exists(out_path):
        os.remove(out_path)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall(f"screendump {os.path.abspath(out_path)}\n".encode())
        deadline = time.time() + 10
        while time.time() < deadline:
            if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
                time.sleep(0.5)  # let QEMU finish writing
                return
            time.sleep(0.2)
    sys.exit("screenshot: QEMU wrote no file")


def read_ppm(path):
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:  # magic, width, height, maxval
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b"P6":
        sys.exit(f"screenshot: not a binary PPM ({fields[0]!r})")
    width, height = int(fields[1]), int(fields[2])
    return width, height, data[pos + 1:]


def pixel(pixels, width, x, y):
    i = (y * width + x) * 3
    return tuple(pixels[i:i + 3])


def main():
    sock_path, out_path = sys.argv[1], sys.argv[2]
    screendump(sock_path, out_path)
    width, height, pixels = read_ppm(out_path)
    corner = pixel(pixels, width, width // 8, height // 8)
    centre = pixel(pixels, width, width // 2, height // 2)
    print(f"screenshot {width}x{height}: background {corner}, centre {centre}")
    if corner != PURPLE or centre != WHITE:
        sys.exit(f"screenshot: expected background {PURPLE} and centre {WHITE}")
    print("SCREEN-OK")


main()
