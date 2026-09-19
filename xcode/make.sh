#!/bin/bash
# Runs a make target for an Xcode target. Xcode calls this with the make
# target and its action: "build" (or empty) runs the target, "clean" does
# nothing, because a clean of the container build cache is slow to recover.
#
# The Swift build prints colour codes. Xcode finds "file:line:column: error:"
# only in plain text, so this script removes them.
set -o pipefail
target=$1
action=${2:-build}
if [ "$action" = clean ]; then
    echo "Nothing to clean from Xcode. Use 'make clean' in a terminal."
    exit 0
fi
cd "$(dirname "$0")/.." || exit 1
/usr/bin/make "$target" 2>&1 | sed -l -e $'s/\x1b\\[[0-9;]*m//g'
