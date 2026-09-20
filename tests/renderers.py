#!/usr/bin/env python3
"""Compare a picture from the CPU renderer with one from the GPU renderer.

    tests/renderers.py CPU.ppm GPU.ppm [--tolerance N] [--allow N]

The two renderers draw the same display list, so the two pictures must be
the same picture. They are not the same pixel for pixel: the CPU divides by
256 (a shift) where the GPU divides by 255, so a colour channel can differ
by a small amount.

This check therefore holds the shape of the agreement, not exact colours:

    --tolerance N   a channel may differ by this much (default 4)
    --allow N       this many pixels may differ by more (default 2000)

The allowance is for the clock. The two pictures come from two runs of the
compositor in one boot, a few seconds apart, so a digit can change. A digit
is a few hundred pixels. A renderer that is really wrong is far larger: the
blend bug of 20 September moved 8312 pixels of the dock alone.

This test does not read the shell, so a change to the shell does not need a
change here.

Exits non-zero if the two renderers disagree.
"""
import sys


def read_ppm(path):
    try:
        data = open(path, "rb").read()
    except OSError as error:
        sys.exit(f"renderers: cannot read {path}: {error}")
    fields, pos = [], 0
    while len(fields) < 4:
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
        sys.exit(f"renderers: {path} is not a binary PPM ({fields[0]!r})")
    return int(fields[1]), int(fields[2]), data[pos + 1:]


def main():
    arguments = sys.argv[1:]
    tolerance, allow = 4, 2000
    paths = []
    while arguments:
        item = arguments.pop(0)
        if item == "--tolerance":
            tolerance = int(arguments.pop(0))
        elif item == "--allow":
            allow = int(arguments.pop(0))
        elif item.startswith("--"):
            sys.exit(f"renderers: {item} is not an option")
        else:
            paths.append(item)
    if len(paths) != 2:
        sys.exit(__doc__)

    width, height, cpu = read_ppm(paths[0])
    gpuWidth, gpuHeight, gpu = read_ppm(paths[1])
    if (width, height) != (gpuWidth, gpuHeight):
        sys.exit(f"renderers: {width}x{height} and {gpuWidth}x{gpuHeight} are different sizes")

    beyond, worst, where = 0, 0, None
    for index in range(0, len(cpu), 3):
        difference = max(abs(cpu[index + channel] - gpu[index + channel]) for channel in range(3))
        if difference > worst:
            pixel = index // 3
            worst, where = difference, (pixel % width, pixel // width)
        if difference > tolerance:
            beyond += 1

    print(f"renderers {width}x{height}: {beyond} pixels differ by more than {tolerance} "
          f"(at most {allow} may), largest difference {worst} at {where}")
    if beyond > allow:
        sys.exit("renderers: the two renderers do not agree")
    print("RENDERERS-AGREE")


main()
