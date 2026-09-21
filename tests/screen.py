#!/usr/bin/env python3
"""Check the colours of pixels in a picture of the guest's screen.

    tests/screen.py PICTURE.ppm X,Y=RRGGBB ...

The guest writes the picture itself, with `apus-screen shot`, into the
`screens` share (out/vm/screens on the Mac). Those are the pixels that the
compositor gave to the display.

QEMU could make the picture from the host, over its monitor socket, and send
input over QMP. Apple's Virtualization framework can do neither, so both
happen in the guest now: see ui/Sources/ScreenTool and
ui/Sources/Compositor/Screenshot.swift.

X and Y are pixels, or fractions of the screen size when they contain a dot
(0.5,0.5 is the centre).

    X,Y=RRGGBB            this pixel has this colour
    X0,Y0-X1,Y1!RRGGBB    this area has at least one pixel of another colour
                          (for example text drawn over a background)

Exits non-zero if any check fails.
"""
import sys


def read_ppm(path):
    try:
        data = open(path, "rb").read()
    except OSError as error:
        sys.exit(f"screenshot: cannot read {path}: {error}")
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


def coordinate(text, size):
    return int(float(text) * size) if "." in text else int(text)


def parse(spec, width, height):
    position, colour = spec.split("=")
    x, y = position.split(",")
    value = int(colour, 16)
    return (coordinate(x, width), coordinate(y, height),
            ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF))


def parse_area(spec, width, height):
    area, colour = spec.split("!")
    start, end = area.split("-")
    x0, y0 = start.split(",")
    x1, y1 = end.split(",")
    value = int(colour, 16)
    return ((coordinate(x0, width), coordinate(y0, height),
             coordinate(x1, width), coordinate(y1, height)),
            ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF))


def differing(pixels, width, area, colour):
    """The number of pixels in the area that do not have this colour."""
    x0, y0, x1, y1 = area
    return sum(1 for y in range(y0, y1) for x in range(x0, x1)
               if pixel(pixels, width, x, y) != colour)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path, specs = sys.argv[1], sys.argv[2:]
    width, height, pixels = read_ppm(path)
    print(f"screenshot {width}x{height}")
    failed = False
    for spec in specs:
        if "!" in spec:
            area, colour = parse_area(spec, width, height)
            count = differing(pixels, width, area, colour)
            ok = count > 0
            failed |= not ok
            print(f"  {area} {'ok' if ok else 'WRONG'}: {count} pixels are not "
                  f"{'%02X%02X%02X' % colour}{'' if ok else ' (expected some)'}")
            continue
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
