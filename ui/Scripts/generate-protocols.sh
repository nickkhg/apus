#!/bin/sh
# Generates the C code for Wayland protocol extensions with wayland-scanner.
# Runs in the build container (`make protocols`). The output is committed.
#
# Each protocol gets two C targets: <Name>Server (for the compositor) and
# <Name>Client (for apps). Both carry the interface definitions (the
# "private code"), because no program links both.
set -eu
cd "$(dirname "$0")/.."
PROTOCOLS=/usr/share/wayland-protocols

gen() { # module-base xml
    base=$1 xml=$2 name=$(basename "$xml" .xml)
    for side in Server Client; do
        dir=Sources/C${base}${side}
        lower=$(echo "$side" | tr 'A-Z' 'a-z')
        mkdir -p "$dir/include"
        wayland-scanner private-code "$xml" "$dir/$name-protocol.c"
        wayland-scanner "$lower-header" "$xml" "$dir/include/$name-$lower-protocol.h"
    done
}

gen XDGShell "$PROTOCOLS/stable/xdg-shell/xdg-shell.xml"
echo "generated from wayland-protocols $(pkg-config --modversion wayland-protocols)" \
    > Sources/GENERATED_PROTOCOLS
