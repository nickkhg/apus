#!/usr/bin/env python3
"""Screenshot the VM through the QEMU monitor and check pixel colours.

    tests/screen.py MONITOR_SOCKET OUTPUT.ppm [OPTIONS] X,Y=RRGGBB ...

X and Y are pixels, or fractions of the screen size when they contain a
dot (0.5,0.5 is the centre).

    X,Y=RRGGBB            this pixel has this colour
    X0,Y0-X1,Y1!RRGGBB    this area has at least one pixel of another colour
                          (for example text drawn over a background)

--pointer X,Y moves the pointer of the VM to that pixel first, and waits for
the compositor to draw again. The VM needs an absolute pointer device
(virtio-tablet, which VM_GPU=headless and VM_GPU=window add).

--click presses the left button and releases it, at the place that --pointer
gave.

--type TEXT types the text on the keyboard of the VM. It knows the small
letters, the digits, a few punctuation marks, and "\n" for the Enter key.
The VM needs a keyboard (VM_GPU=headless and VM_GPU=window add one).

The options run in this order: --pointer, --click, --type.

Exits non-zero if any check fails.
"""
import json
import os
import socket
import sys
import time

def qmp(sock_path, command):
    """Runs one QMP command and gives the answer."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        stream = s.makefile("rw")
        stream.readline()                       # the greeting
        for message in ({"execute": "qmp_capabilities"}, command):
            stream.write(json.dumps(message) + "\n")
            stream.flush()
            answer = stream.readline()
        return answer


def move_pointer(sock_path, x, y, width, height):
    """Moves the pointer of the VM. The tablet is an absolute device, and
    QEMU wants its coordinates from 0 to 32767 over the whole screen.

    The QEMU monitor has `mouse_move`, but it sends relative motion, which an
    absolute device does not get. QMP sends absolute events."""
    qmp_path = os.path.join(os.path.dirname(sock_path), "qmp.sock")
    qmp(qmp_path, {"execute": "input-send-event", "arguments": {"events": [
        {"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / width)}},
        {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / height)}},
    ]}})
    time.sleep(1.0)  # the compositor draws the next frame


def click(sock_path):
    """Presses the left button and releases it."""
    qmp_path = os.path.join(os.path.dirname(sock_path), "qmp.sock")
    for down in (True, False):
        qmp(qmp_path, {"execute": "input-send-event", "arguments": {
            "events": [{"type": "btn", "data": {"down": down, "button": "left"}}]}})
        time.sleep(0.3)
    time.sleep(1.0)


# The key names of QEMU (qcode) for the characters that a test types.
KEYS = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal",
    ".": "dot", ",": "comma", "/": "slash", ";": "semicolon", "'": "apostrophe",
    "[": "bracket_left", "]": "bracket_right", "\\": "backslash", "`": "grave_accent",
}
SHIFTED = {
    ">": "dot", "<": "comma", "|": "backslash", "~": "grave_accent", "?": "slash",
    ":": "semicolon", '"': "apostrophe", "_": "minus", "+": "equal",
}


def key_name(character):
    """The QEMU key for a character, and whether Shift is down."""
    if character in KEYS:
        return KEYS[character], False
    if character in SHIFTED:
        return SHIFTED[character], True
    if character.isdigit() or ("a" <= character <= "z"):
        return character, False
    if "A" <= character <= "Z":
        return character.lower(), True
    sys.exit(f"screenshot: --type cannot type {character!r}")


def type_text(sock_path, text):
    """Types the text on the keyboard of the VM."""
    qmp_path = os.path.join(os.path.dirname(sock_path), "qmp.sock")
    for character in text:
        name, shifted = key_name(character)
        keys = ([{"type": "qcode", "data": "shift"}] if shifted else []) + \
              [{"type": "qcode", "data": name}]
        for down in (True, False):
            events = [{"type": "key", "data": {"down": down, "key": key}}
                      for key in (keys if down else list(reversed(keys)))]
            qmp(qmp_path, {"execute": "input-send-event", "arguments": {"events": events}})
            time.sleep(0.05)
    time.sleep(1.5)  # the program answers and the compositor draws


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
    sock_path, out_path, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
    pointer = None
    clicking = False
    text = None
    while specs and specs[0].startswith("--"):
        option = specs.pop(0)
        if option == "--pointer":
            pointer = specs.pop(0)
        elif option == "--click":
            clicking = True
        elif option == "--type":
            text = specs.pop(0).replace("\\n", "\n").replace("\\t", "\t")
        else:
            sys.exit(f"screenshot: {option} is not an option")
    screendump(sock_path, out_path)
    width, height, pixels = read_ppm(out_path)
    if pointer or clicking or text is not None:
        if pointer:
            x, y = pointer.split(",")
            move_pointer(sock_path, coordinate(x, width), coordinate(y, height), width, height)
            print(f"pointer at {pointer}")
        if clicking:
            click(sock_path)
            print("clicked")
        if text is not None:
            type_text(sock_path, text)
            print(f"typed {text!r}")
        screendump(sock_path, out_path)
        width, height, pixels = read_ppm(out_path)
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
