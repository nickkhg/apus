#!/bin/sh
# Builds virglrenderer for macOS, with Venus and without the OpenGL renderer.
#
# This is the renderer on the host side of the GPU. The guest's Mesa speaks
# Venus, which is Vulkan commands in a stream; virglrenderer reads that
# stream and makes the same calls to Vulkan on the Mac, where MoltenVK turns
# them into Metal. See docs/gpu.md.
#
# Everything lands in build/cache, which git ignores. Nothing is installed on
# the Mac outside Homebrew.
set -eu
cd "$(dirname "$0")/.."
cache="$PWD/build/cache"
source="$cache/virglrenderer"

# Homebrew gives the tools and the Vulkan headers. MoltenVK is the Vulkan
# that virglrenderer loads at run time. This installs what is missing,
# because `make vm` calls this script and a person who clones the repository
# should not have to find the list themselves.
missing=
for formula in meson ninja vulkan-headers vulkan-loader molten-vk; do
    brew list --formula "$formula" >/dev/null 2>&1 || missing="$missing $formula"
done
if [ -n "$missing" ]; then
    command -v brew >/dev/null 2>&1 || {
        echo "build/make-virglrenderer.sh: the renderer needs Homebrew for:$missing" >&2
        echo "Install Homebrew from https://brew.sh, or build without a GPU." >&2
        exit 1
    }
    echo "==> installing the build requirements of the renderer:$missing"
    # shellcheck disable=SC2086
    brew install $missing
fi

# The Venus protocol generator is Python with mako. It goes in a virtual
# environment, so nothing is added to the Python of the Mac.
if [ ! -x "$cache/venusbuild/bin/python" ]; then
    python3 -m venv "$cache/venusbuild"
    "$cache/venusbuild/bin/pip" install -q mako
fi
PATH="$cache/venusbuild/bin:$PATH"
export PATH

[ -d "$source" ] || git clone --depth 1 \
    https://gitlab.freedesktop.org/virgl/virglrenderer.git "$source"
cd "$source"

# The Metal part of Venus is new, and it includes the Venus protocol headers
# by the name they have once they are installed. As a subproject they stay
# where they are, so this gives them that name as well. The pinned v1.1.3 of
# the protocol has no Metal header at all, so the build takes the main branch.
sed -i '' -e 's|^directory = venus-protocol-1.1.3|directory = venus-protocol-main|' \
          -e 's|^revision = v1.1.3|revision = main|' subprojects/venus-protocol.wrap

PKG_CONFIG_PATH="$(brew --prefix vulkan-loader)/lib/pkgconfig:$(brew --prefix vulkan-headers)/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_PATH

# render-server-mode=thread keeps Venus in this process, as a thread. The
# other mode forks a virgl_render_server program and talks to it over a
# socket. A thread needs no second program, no path to find it by, and no
# signature of its own, and Virtualization.framework gives a program that
# forks a lot of trouble.
[ -d build ] || meson setup build \
    -Dvenus=true -Dvrend=false -Dplatforms= -Dtests=false \
    -Drender-server-mode=thread \
    --prefix "$source/install"

# The layout that the Metal helpers expect. meson makes the subproject on
# the first setup, so this comes after it.
[ -e subprojects/venus-protocol-main/venus-protocol ] || \
    ln -sfn include/vulkan subprojects/venus-protocol-main/venus-protocol

ninja -C build
echo "==> $source/build/src/libvirglrenderer.dylib"
