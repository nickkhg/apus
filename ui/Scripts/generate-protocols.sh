#!/bin/sh
# Generates the C client code for Wayland protocol extensions with
# wayland-scanner, for the test client. Runs in the build container
# (`make protocols`). The output is committed.
#
# The compositor does not use this code: its protocol code is Swift, from
# Tools/WaylandScanner (see the Makefile).
set -eu
cd "$(dirname "$0")/.."
PROTOCOLS=/usr/share/wayland-protocols

gen() { # module-base xml
    base=$1 xml=$2 name=$(basename "$xml" .xml)
    dir=Sources/C${base}Client
    mkdir -p "$dir/include"
    wayland-scanner private-code "$xml" "$dir/$name-protocol.c"
    wayland-scanner client-header "$xml" "$dir/include/$name-client-protocol.h"
}

gen XDGShell "$PROTOCOLS/stable/xdg-shell/xdg-shell.xml"

# The XML files for the Swift generator (Tools/WaylandScanner), which runs on
# the Mac.
cp /usr/share/wayland/wayland.xml "$PROTOCOLS/stable/xdg-shell/xdg-shell.xml" Protocols/

echo "generated from wayland $(pkg-config --modversion wayland-client)" \
    "and wayland-protocols $(pkg-config --modversion wayland-protocols)" > Sources/GENERATED_PROTOCOLS
