#!/usr/bin/env python3
"""Screenshot the VM through the QEMU monitor and check pixel colours.

    tests/screen.py MONITOR_SOCKET OUTPUT.ppm X,Y=RRGGBB...

X and Y are pixels, or fractions of the screen size when they contain a
dot (0.5,0.5 is the centre). Exits non-zero if any pixel differs.
"""
import os
import socket
import sys
import time

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


def parse(spec, width, height):
    position, colour = spec.split("=")
    x, y = position.split(",")
    x = int(float(x) * width) if "." in x else int(x)
    y = int(float(y) * height) if "." in y else int(y)
    value = int(colour, 16)
    return x, y, ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


def main():
    sock_path, out_path, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
    screendump(sock_path, out_path)
    width, height, pixels = read_ppm(out_path)
    print(f"screenshot {width}x{height}")
    failed = False
    for spec in specs:
        x, y, expected = parse(spec, width, height)
        actual = pixel(pixels, width, x, y)
        ok = actual == expected
        failed |= not ok
        print(f"  ({x},{y}) {'ok' if ok else 'WRONG'}: {'%02X%02X%02X' % actual}"
              f"{'' if ok else ' (expected %02X%02X%02X)' % expected}")
    if failed:
        sys.exit("screenshot: pixels differ")
    print("SCREEN-OK")


main()
