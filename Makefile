# mydistro - host-side entry point. The build runs inside an Apple `container`;
# testing runs in a virtual machine on the Mac, through Apple's
# Virtualization framework (vm/, the mydistro-vm program).

IMAGE     := mydistro-builder
VOL_WORK  := mydistro-work
VOL_PKG   := mydistro-pkgcache
# The time zone of the image. The compositor shows this time in the panel.
# Change it here, or with `timedatectl set-timezone` on a running system.
TIMEZONE  ?= Europe/London
CPUS      ?= 8
MEM       ?= 8g

# Base of the builder image. "latest" moves upstream: when the hash stops
# matching, check the new tarball and update the pin deliberately.
ALARM_URL     := http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
ALARM_SHA256  := 42a4eeaa038994ffd31fa173256ef2f0ef511358eeb41b9ea1f8626391b9b319
ALARM_TARBALL := build/cache/ArchLinuxARM-aarch64-latest.tar.gz
SWIFT_VERSION := 6.4.0
SWIFT_TARBALL := build/cache/swift-$(SWIFT_VERSION)-RELEASE-fedora41-aarch64.tar.gz
SWIFT_URL     := https://download.swift.org/swift-$(SWIFT_VERSION)-release/fedora41-aarch64/swift-$(SWIFT_VERSION)-RELEASE/$(notdir $(SWIFT_TARBALL))
SWIFT_SHA256  := ca1088186e3a3b278854b4f5b3d6975e5846d06748b1109ab259a959a5431f86
BUILDER_STAMP := build/cache/builder.stamp

# The swift.org toolchain for macOS (the same compiler version as the Linux
# toolchain in the builder), and the Swift SDK that `make sdk` makes from the
# builder. Together they compile ui/ for mydistro on the Mac.
SWIFT_MAC_PKG    := build/cache/swift-$(SWIFT_VERSION)-RELEASE-osx.pkg
SWIFT_MAC_URL    := https://download.swift.org/swift-$(SWIFT_VERSION)-release/xcode/swift-$(SWIFT_VERSION)-RELEASE/$(notdir $(SWIFT_MAC_PKG))
SWIFT_MAC_SHA256 := 8fd03185b98fe27f54a54631c2449decf75d5b466ce8e34abbd414141063c6aa
SWIFT_MAC        := build/cache/swift-$(SWIFT_VERSION)-macos
SWIFT_SDKS       := build/cache/swift-sdks
SWIFT_SDK        := mydistro-aarch64
SDK_STAMP        := $(SWIFT_SDKS)/$(SWIFT_SDK).artifactbundle/info.json
# MYDISTRO_CROSS tells ui/Toolkit/Package.swift not to run pkg-config: the
# Swift SDK has the include directories, and pkg-config would answer with the
# macOS libraries of Homebrew.
SWIFT_BUILD       = MYDISTRO_CROSS=1 $(SWIFT_MAC)/usr/bin/swift build --package-path ui \
	--swift-sdks-path $(SWIFT_SDKS) --swift-sdk $(SWIFT_SDK) --static-swift-stdlib

# mydistro-vm boots the images. It builds with the Swift toolchain of Xcode,
# because Virtualization and AppKit are frameworks of the platform. The
# program needs the com.apple.security.virtualization entitlement, and a
# local (ad hoc) signature carries it.
# The renderer of the host side of the GPU, when build/make-virglrenderer.sh
# has built it. Without it the program builds and runs as before, and the
# GPU device of our own is not in it.
VIRGL_DIR  := build/cache/virglrenderer
VIRGL_LIB  := $(VIRGL_DIR)/build/src/libvirglrenderer.dylib
VIRGL_FLAGS = $(if $(wildcard $(VIRGL_LIB)),\
	-Xswiftc -DVIRGL \
	-Xcc -I$(CURDIR)/$(VIRGL_DIR)/src \
	-Xcc -I$(CURDIR)/$(VIRGL_DIR)/build/src \
	-Xlinker -L$(CURDIR)/$(VIRGL_DIR)/build/src \
	-Xlinker -rpath -Xlinker $(CURDIR)/$(VIRGL_DIR)/build/src,)

VM_BUILD = xcrun swift build --package-path vm -c release $(VIRGL_FLAGS)
VM       = $(shell xcrun swift build --package-path vm -c release --show-bin-path)/mydistro-vm
# The expect scripts in tests/ and vm/ start the machine through this.
export MYDISTRO_VM := $(VM)

# Xcode and other GUI apps start make with a minimal PATH.
export PATH := /usr/local/bin:/opt/homebrew/bin:$(PATH)

# Work files live in container volumes (ext4): macOS file systems are
# case-insensitive and don't keep Linux ownership. The package cache volume
# means packages are downloaded once. The repository has the same path in the
# container as on the Mac, so compiler messages point to files that Xcode and
# other editors can open.
RUN = container run --rm --cap-add ALL -c $(CPUS) -m $(MEM) \
	-e TIMEZONE=$(TIMEZONE) \
	-v $(CURDIR):$(CURDIR) \
	-v $(VOL_WORK):/work \
	-v $(VOL_PKG):/var/cache/pacman/pkg \
	-w $(CURDIR)

.PHONY: help builder volumes build sdk ui ui-container protocols shell vm live installed gui demo demo-dev test test-dev test-ui test-ui-linux bench clean distclean

help:
	@echo "make build      build out/live.img"
	@echo "make vm         build mydistro-vm, the virtual machine on the Mac"
	@echo "make live       boot live image + blank disk (Ctrl-A X quits)"
	@echo "make installed  boot the disk the installer wrote"
	@echo "make gui        boot the installed disk in a window (display + input)"
	@echo "make demo       same, and start the compositor (open an app from the dock)"
	@echo "make demo-dev   same, with the programs from 'make ui' (out/ui)"
	@echo "make ui         quick Swift build of ui/ on the Mac into out/ui (shared at /mnt/host/ui in the VM)"
	@echo "make ui-container  the same build in the build container"
	@echo "make sdk        the macOS Swift toolchain and the mydistro Swift SDK (make ui does this)"
	@echo "make test       install, display, compositor and GPU tests"
	@echo "make test-ui    unit tests of the toolkit and the shell, on the Mac (seconds)"
	@echo "make test-ui-linux  the same tests in the builder container"
	@echo "make bench      how long one frame of the shell takes"
	@echo "make test-dev   the compositor test, with the programs from 'make ui'"
	@echo "make shell      root shell in the build container"
	@echo "make clean      remove build output (keeps package cache)"
	@echo "make distclean  also remove package cache, builder image, base tarball"

$(ALARM_TARBALL):
	mkdir -p $(dir $@)
	curl -fL --no-progress-meter -o $@.part $(ALARM_URL)
	echo "$(ALARM_SHA256)  $@.part" | shasum -a 256 -c -
	mv $@.part $@

$(SWIFT_TARBALL):
	mkdir -p $(dir $@)
	curl -fL --no-progress-meter -o $@.part $(SWIFT_URL)
	echo "$(SWIFT_SHA256)  $@.part" | shasum -a 256 -c -
	mv $@.part $@

$(BUILDER_STAMP): build/Containerfile $(ALARM_TARBALL) $(SWIFT_TARBALL)
	container build -t $(IMAGE) -f build/Containerfile build
	touch $@

builder: $(BUILDER_STAMP)

$(SWIFT_MAC_PKG):
	mkdir -p $(dir $@)
	curl -fL --no-progress-meter -o $@.part $(SWIFT_MAC_URL)
	echo "$(SWIFT_MAC_SHA256)  $@.part" | shasum -a 256 -c -
	pkgutil --check-signature $@.part
	mv $@.part $@

# The toolchain stays in build/cache. It is not installed on the Mac.
$(SWIFT_MAC)/usr/bin/swift: $(SWIFT_MAC_PKG)
	rm -rf $(SWIFT_MAC) $(SWIFT_MAC).part
	pkgutil --expand-full $< $(SWIFT_MAC).part
	mv $(SWIFT_MAC).part/*/Payload $(SWIFT_MAC)
	rm -rf $(SWIFT_MAC).part
	touch $@

$(SDK_STAMP): $(BUILDER_STAMP) build/make-sdk.sh
	$(RUN) $(IMAGE) build/make-sdk.sh
	rm -rf $(SWIFT_SDKS)
	mkdir -p $(SWIFT_SDKS)
	tar -C $(SWIFT_SDKS) -xf build/cache/swift-sdk.tar
	rm build/cache/swift-sdk.tar
	touch $@

sdk: $(SWIFT_MAC)/usr/bin/swift volumes $(SDK_STAMP)

volumes:
	@container volume inspect $(VOL_WORK) >/dev/null 2>&1 || container volume create -s 32G $(VOL_WORK)
	@container volume inspect $(VOL_PKG)  >/dev/null 2>&1 || container volume create -s 16G $(VOL_PKG)

build: builder volumes
	$(RUN) $(IMAGE) build/build.sh

# Fast Swift loop: no image rebuild. Debug build, Swift runtime linked in.
ui: sdk
	$(SWIFT_BUILD)
	mkdir -p out/ui
	find "$$($(SWIFT_BUILD) --show-bin-path)" -maxdepth 1 -type f -perm -u+x -exec cp {} out/ui/ \;
	ls out/ui

ui-container: builder volumes
	$(RUN) $(IMAGE) sh -c 'swift build --package-path ui --scratch-path /work/swiftpm/dev \
		--static-swift-stdlib && mkdir -p out/ui && \
		find "$$(swift build --package-path ui --scratch-path /work/swiftpm/dev --show-bin-path)" \
			-maxdepth 1 -type f -perm -u+x -exec cp {} out/ui/ \; && ls out/ui'

# Unit tests of the toolkit and the shell: layout, text and the panel. They
# need no screen, no VM and no container, because the toolkit package also
# builds for macOS. A run takes a few seconds.
test-ui: $(SWIFT_MAC)/usr/bin/swift
	$(SWIFT_MAC)/usr/bin/swift test --package-path ui/Toolkit

# How long one frame of the shell takes, on the Mac.
bench: $(SWIFT_MAC)/usr/bin/swift
	$(SWIFT_MAC)/usr/bin/swift run -c release --package-path ui/Toolkit toolkit-bench

# The same tests on mydistro itself (aarch64 Linux), in the builder container.
test-ui-linux: builder volumes
	$(RUN) $(IMAGE) swift test --package-path ui/Toolkit --scratch-path /work/swiftpm/test

# Regenerate the Wayland protocol code in ui/ (commit the result): the XML
# files and the C client code from the builder, then the Swift server code.
WAYLAND_SCANNER = $(SWIFT_MAC)/usr/bin/swift run --package-path ui/Tools/WaylandScanner -c release \
	wayland-swift-scanner

protocols: builder $(SWIFT_MAC)/usr/bin/swift
	$(RUN) $(IMAGE) ui/Scripts/generate-protocols.sh
	$(WAYLAND_SCANNER) ui/Protocols/wayland.xml ui/Sources/Wayland/Protocols/Wayland.swift
	$(WAYLAND_SCANNER) ui/Protocols/xdg-shell.xml ui/Sources/Wayland/Protocols/XDGShell.swift

shell: builder volumes
	$(RUN) -it $(IMAGE) bash

# The virtual machine. Signing is part of the build: without the
# entitlement, Virtualization refuses to make a machine.
vm:
	$(VM_BUILD)
	codesign --force --sign - --entitlements vm/mydistro-vm.entitlements $(VM)

live: vm
	$(VM) live

installed: vm
	$(VM) installed

gui: vm
	VM_GPU=window $(VM) installed

# The installed system in a window, with the compositor and a test window running.
demo: vm
	vm/demo.exp

# The same, but the VM runs the programs from `make ui` through /mnt/host.
# It builds them first, so that the VM never runs a program of an older build.
demo-dev: ui vm
	MYDISTRO_UI_DIR=/mnt/host/ui vm/demo.exp

test: vm
	tests/install.exp
	tests/display.exp
	tests/compositor.exp
	tests/gpu.exp

# The compositor test with the programs from `make ui`. Needs the installed
# disk from `make test`.
test-dev: ui vm
	MYDISTRO_UI_DIR=/mnt/host/ui tests/compositor.exp

clean:
	-container volume rm $(VOL_WORK)
	rm -rf out

distclean: clean
	-container volume rm $(VOL_PKG)
	-container image rm $(IMAGE)
	rm -rf build/cache
