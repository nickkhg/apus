#!/bin/bash
# Runs inside the build container. Makes a Swift SDK (an artifact bundle) from
# the builder image: the Linux headers and libraries, and the Swift runtime of
# the Linux toolchain. With it, the swift.org toolchain for macOS compiles the
# ui/ package for mydistro on the Mac, without the container.
#
# Output: build/cache/swift-sdk.tar, with mydistro-aarch64.artifactbundle/.
set -euo pipefail

SRC=$PWD
SWIFT=/opt/swift/usr/lib
STAGE=/work/sdk
BUNDLE=$STAGE/mydistro-aarch64.artifactbundle
SDK=$BUNDLE/mydistro-aarch64
SYSROOT=$SDK/sysroot

rm -rf "$STAGE"
mkdir -p "$SYSROOT/usr/lib" "$SYSROOT/usr/share"

# C headers, pkg-config files, and the libraries to link with (not firmware,
# kernel modules, or the files of programs).
cd /
tar -cf - usr/include usr/share/pkgconfig usr/lib/pkgconfig usr/lib/gcc usr/lib/glib-2.0 lib \
    $(find usr/lib -maxdepth 1 \( -name '*.so' -o -name '*.so.*' -o -name '*.a' -o -name '*.o' \)) |
    tar -C "$SYSROOT" -xf -

# The Swift runtime and modules for Linux, without the parts for other targets
# (embedded) and for the compiler itself (host, pm).
tar -C "$SWIFT" -cf - \
    --exclude=swift/embedded --exclude=swift/host --exclude=swift/pm \
    --exclude=swift/FrameworkABIBaseline --exclude=swift_static/embedded \
    swift swift_static clang |
    tar -C "$SYSROOT/usr/lib" -xf -

# macOS file systems ignore case. Keep one file of each group of names that
# differ only in case (these are netfilter headers that ui/ does not use).
(cd "$SYSROOT" && find . | sort | awk '{ key = tolower($0); if (key in seen) print; else seen[key] = 1 }') |
    while read -r path; do
        echo "sdk: removed $path (same name as another file on macOS)"
        rm -rf "${SYSROOT:?}/$path"
    done

cat > "$BUNDLE/info.json" <<'EOF'
{
  "schemaVersion": "1.0",
  "artifacts": {
    "mydistro-aarch64": {
      "type": "swiftSDK",
      "version": "1",
      "variants": [{ "path": "mydistro-aarch64" }]
    }
  }
}
EOF

# The include directories that pkg-config gives for the ui/ libraries. With
# them in the SDK, the headers are found also when pkg-config is not set up for
# the SDK (for example in an editor).
includes=$(pkg-config --cflags-only-I libdrm gbm egl glesv2 libinput libudev xkbcommon \
    libseat wayland-client freetype2 harfbuzz |
    tr ' ' '\n' | sed -n 's|^-I/|"sysroot/|p' | sed 's|$|"|' | paste -sd, -)

cat > "$SDK/swift-sdk.json" <<EOF
{
  "schemaVersion": "4.0",
  "targetTriples": {
    "aarch64-unknown-linux-gnu": {
      "sdkRootPath": "sysroot",
      "swiftResourcesPath": "sysroot/usr/lib/swift",
      "swiftStaticResourcesPath": "sysroot/usr/lib/swift_static",
      "includeSearchPaths": [$includes],
      "toolsetPaths": ["toolset.json"]
    }
  }
}
EOF

cat > "$SDK/toolset.json" <<'EOF'
{
  "schemaVersion": "1.0",
  "swiftCompiler": { "extraCLIOptions": ["-use-ld=lld"] }
}
EOF

mkdir -p "$SRC/build/cache"
tar -C "$STAGE" -cf "$SRC/build/cache/swift-sdk.tar" mydistro-aarch64.artifactbundle
du -sh "$BUNDLE"
