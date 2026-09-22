# Apus - host-side entry point. The build runs inside an Apple `container`;
# testing runs in a virtual machine on the Mac, through Apple's
# Virtualization framework (vm/, the apus-vm program).

IMAGE     := apus-builder
VOL_WORK  := apus-work
VOL_PKG   := apus-pkgcache
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
# builder. Together they compile ui/ for Apus on the Mac.
SWIFT_MAC_PKG    := build/cache/swift-$(SWIFT_VERSION)-RELEASE-osx.pkg
SWIFT_MAC_URL    := https://download.swift.org/swift-$(SWIFT_VERSION)-release/xcode/swift-$(SWIFT_VERSION)-RELEASE/$(notdir $(SWIFT_MAC_PKG))
SWIFT_MAC_SHA256 := 8fd03185b98fe27f54a54631c2449decf75d5b466ce8e34abbd414141063c6aa
SWIFT_MAC        := build/cache/swift-$(SWIFT_VERSION)-macos
# The key for a shell on the guest. It is made once and never committed.
SSH_KEY          := build/cache/apus
SWIFT_SDKS       := build/cache/swift-sdks
SWIFT_SDK        := apus-aarch64
SDK_STAMP        := $(SWIFT_SDKS)/$(SWIFT_SDK).artifactbundle/info.json
# APUS_CROSS tells ui/Toolkit/Package.swift not to run pkg-config: the
# Swift SDK has the include directories, and pkg-config would answer with the
# macOS libraries of Homebrew.
# The compositor draws every pixel of every frame, and a debug build of it
# is several times slower than the one the image carries, which makepkg
# builds with -c release. `make demo-dev` would then look slow for a reason
# that has nothing to do with the machine. UI_CONFIG=debug asks for the
# other one.
UI_CONFIG        ?= release
# The libraries are dynamic (see ui/Package.swift), so a program finds them
# beside itself first ($ORIGIN, for the /mnt/host/ui loop) and in /usr/lib
# after that. The Swift runtime is in the image, at /usr/lib/swift/linux, so
# the programs no longer carry a copy each.
SWIFT_BUILD       = APUS_CROSS=1 $(SWIFT_MAC)/usr/bin/swift build --package-path ui \
	--swift-sdks-path $(SWIFT_SDKS) --swift-sdk $(SWIFT_SDK) \
	-Xlinker -rpath -Xlinker '$$ORIGIN' \
	-Xlinker -rpath -Xlinker /usr/lib/swift/linux \
	-c $(UI_CONFIG)

# apus-vm boots the images. It builds with the Swift toolchain of Xcode,
# because Virtualization and AppKit are frameworks of the platform. The
# program needs the com.apple.security.virtualization entitlement, and a
# local (ad hoc) signature carries it.
# The renderer of the host side of the GPU. `make vm` builds it, so a guest
# has a GPU without a separate step. A Mac with no Homebrew cannot build it.
# The build then says so and goes on, and the guest gets a 2D device only.
VIRGL_DIR  := build/cache/virglrenderer
VIRGL_LIB  := $(VIRGL_DIR)/build/src/libvirglrenderer.dylib
# The renderer loads Vulkan by name at run time: libvulkan.dylib first, then
# libMoltenVK.dylib. Neither is on the standard path, and dyld looks for a
# name with no directory in it along the run paths of the program, so the
# program carries the two Homebrew directories.
VULKAN_DIR := $(shell brew --prefix vulkan-loader 2>/dev/null)/lib
MOLTEN_DIR := $(shell brew --prefix molten-vk 2>/dev/null)/lib
# $(wildcard) reads the directory once for a whole run of make, so it would
# answer "no renderer" even after the rule below made one. The shell asks
# again each time the flags are used.
VIRGL_FLAGS = $(if $(shell test -f $(VIRGL_LIB) && echo yes),\
	-Xswiftc -DVIRGL \
	-Xcc -I$(CURDIR)/$(VIRGL_DIR)/src \
	-Xcc -I$(CURDIR)/$(VIRGL_DIR)/build/src \
	-Xlinker -L$(CURDIR)/$(VIRGL_DIR)/build/src \
	-Xlinker -rpath -Xlinker $(CURDIR)/$(VIRGL_DIR)/build/src \
	-Xlinker -rpath -Xlinker $(VULKAN_DIR) \
	-Xlinker -rpath -Xlinker $(MOLTEN_DIR),)

# The live image that `make build` writes, and the disk that the installer
# writes into. A machine boots one of the two.
LIVE_IMG   := out/live.img
TARGET_IMG := out/vm/target.img

VM_BUILD = xcrun swift build --package-path vm -c release $(VIRGL_FLAGS)
VM       = $(shell xcrun swift build --package-path vm -c release --show-bin-path)/apus-vm
# The expect scripts in tests/ and vm/ start the machine through this.
export APUS_VM := $(VM)

# Xcode and other GUI apps start make with a minimal PATH.
export PATH := /usr/local/bin:/opt/homebrew/bin:$(PATH)

# Xcode turns Metal API Validation on for what it runs, with this variable,
# and a child of make keeps it. Validation then stops apus-vm in MoltenVK:
# "bytesPerRow(6619) must be a multiple of MTLPixelFormatBGRA8Unorm pixel
# bytes(4)". MoltenVK computes that number for an image that Zink binds, and
# the number is not a whole count of pixels. The frames are right, and
# validation makes a fault of another project fatal here.
#
# So a build from Xcode ran no machine at all, and the same build in a
# terminal worked. This takes the variable away from the machine.
# MTL_DEBUG_LAYER=1 turns validation on again, for a person who wants it.
unexport METAL_DEVICE_WRAPPER_TYPE

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

.PHONY: help preflight virgl install-disk builder volumes build sdk ui ui-container protocols shell vm live installed gui demo demo-dev test test-venus test-dev test-ui test-ui-linux ssh bench clean distclean

help:
	@echo "make build      build out/live.img"
	@echo "make vm         build apus-vm, the virtual machine on the Mac"
	@echo "make live       boot live image + blank disk (Ctrl-A X quits)"
	@echo "make installed  boot the disk the installer wrote"
	@echo "make gui        boot the installed disk in a window (display + input)"
	@echo "make demo       same, and start the compositor (open an app from the dock)"
	@echo "make demo-dev   same, with the programs from 'make ui' (out/ui)"
	@echo "make ui         quick Swift build of ui/ on the Mac into out/ui (shared at /mnt/host/ui in the VM)"
	@echo "make ui-container  the same build in the build container"
	@echo "make sdk        the macOS Swift toolchain and the Apus Swift SDK (make ui does this)"
	@echo "make test       install, display, compositor and GPU tests"
	@echo "make ssh        a shell on the running guest over SSH"
	@echo "make test-ui    unit tests of the toolkit and the shell, on the Mac (seconds)"
	@echo "make test-venus  the guest finds the GPU of the Mac (needs the renderer)"
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

builder: preflight $(BUILDER_STAMP)

# Apple's `container` runs the build in a Linux VM of its own, and its
# background service must be running first. The first start of that service
# asks a question that only a person can answer, so this says what to run
# and stops. A build from Xcode fails with a message about a connection
# without it.
preflight:
	@container system status 2>/dev/null | grep -q running || { \
	    echo "The Apple container service is not running."; \
	    echo ""; \
	    echo "    container system start"; \
	    echo ""; \
	    echo "Run that in a terminal, then build again. If the command is"; \
	    echo "not there, install Apple container 1.0 or later. See README.md."; \
	    exit 1; }

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

volumes: preflight
	@container volume inspect $(VOL_WORK) >/dev/null 2>&1 || container volume create -s 32G $(VOL_WORK)
	@container volume inspect $(VOL_PKG)  >/dev/null 2>&1 || container volume create -s 16G $(VOL_PKG)

build: builder volumes
	$(RUN) $(IMAGE) build/build.sh

# Fast Swift loop: no image rebuild. The Swift runtime is linked in.
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
# A shell on the guest that is running now. The guest takes its address from
# the DHCP server of the framework, which writes the lease under the name
# apus; the newest lease is the machine that is up.
ssh: $(SSH_KEY)
	@ip=$$(awk -F= '/name=apus/ { found = 1 } found && /ip_address/ { print $$2; found = 0 }' \
		/var/db/dhcpd_leases | tail -1); \
	test -n "$$ip" || { echo "no guest: is the VM running?" >&2; exit 1; }; \
	echo "==> $$ip"; \
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR root@$$ip $(SSH_ARGS)

test-ui: $(SWIFT_MAC)/usr/bin/swift
	$(SWIFT_MAC)/usr/bin/swift test --package-path ui/Toolkit

# How long one frame of the shell takes, on the Mac.
bench: $(SWIFT_MAC)/usr/bin/swift
	$(SWIFT_MAC)/usr/bin/swift run -c release --package-path ui/Toolkit toolkit-bench

# The same tests on Apus itself (aarch64 Linux), in the builder container.
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
#
# The renderer comes first. A Mac that cannot build it says why and gets a
# program with no 3D in it, rather than no program.
$(VIRGL_LIB):
	@build/make-virglrenderer.sh || { \
	    echo ""; \
	    echo "==> No GPU: the build of virglrenderer failed (see above)."; \
	    echo "==> apus-vm still works, and the guest gets a 2D device only."; \
	    echo "==> See docs/gpu.md."; \
	    echo ""; }

virgl: $(VIRGL_LIB)

vm: $(VIRGL_LIB) out/ssh/authorized_keys
	$(VM_BUILD)
	codesign --force --sign - --entitlements vm/apus-vm.entitlements $(VM)

# The key that reaches the guest over SSH. The VM shares out/ read-only at
# /mnt/host, and apus-ssh-key.service takes the key from there, so the key
# is never in the image and never in the repository. `ssh -i build/cache/apus
# root@<guest>` is then a shell on the machine; the guest's address is in
# /var/db/dhcpd_leases under the name apus. See docs/building.md.
out/ssh/authorized_keys: | $(SSH_KEY)
	mkdir -p $(dir $@)
	cp $(SSH_KEY).pub $@

$(SSH_KEY):
	mkdir -p $(dir $@)
	ssh-keygen -t ed25519 -N "" -C apus -f $@ -q

# The live image, for a target that names it. `make build` writes it.
$(LIVE_IMG):
	$(MAKE) build

# The installed disk. `tests/install.exp` boots the live image, runs the
# installer, and leaves the disk that the installer wrote.
#
# A clone has no such disk. Every target below boots one, and a machine with
# nothing to boot starts, shows the firmware, and stops. The test then says
# "VM exited before login", which names what happened and not why. This
# installs the disk one time instead.
#
# `vm` comes after the bar, as an order-only prerequisite: the program must
# be there first, but a new build of the program does not ask for a new
# install. Without the bar each build of the program would install again,
# because `vm` is a name and not a file.
$(TARGET_IMG): $(LIVE_IMG) | vm
	tests/install.exp

install-disk: $(TARGET_IMG)

live: $(LIVE_IMG) vm
	$(VM) live

installed: $(TARGET_IMG) vm
	$(VM) installed

gui: $(TARGET_IMG) vm
	VM_GPU=window VM_CUSTOM_GPU=1 $(VM) installed

# The installed system in a window, with the compositor and a test window
# running. The compositor draws with the GPU of the Mac when the renderer is
# built (build/make-virglrenderer.sh) and falls back to the CPU when it is
# not. See docs/gpu.md.
demo: $(TARGET_IMG) vm
	vm/demo.exp

# The same, but the VM runs the programs from `make ui` through /mnt/host.
# It builds them first, so that the VM never runs a program of an older build.
demo-dev: ui $(TARGET_IMG) vm
	APUS_UI_DIR=/mnt/host/ui vm/demo.exp

test: vm
	tests/install.exp
	tests/display.exp
	tests/compositor.exp
	tests/gpu.exp

# The guest finds the GPU of the Mac. This one needs the renderer, which
# build/make-virglrenderer.sh builds, so `make test` leaves it out. Needs the
# installed disk from `make test`. See docs/gpu.md.
test-venus: $(TARGET_IMG) vm
	tests/venus.exp

# The compositor test with the programs from `make ui`. Needs the installed
# disk from `make test`.
test-dev: ui $(TARGET_IMG) vm
	APUS_UI_DIR=/mnt/host/ui tests/compositor.exp

clean:
	-container volume rm $(VOL_WORK)
	rm -rf out

distclean: clean
	-container volume rm $(VOL_PKG)
	-container image rm $(IMAGE)
	rm -rf build/cache
