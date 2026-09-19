# mydistro - host-side entry point. The build runs inside an Apple `container`;
# testing runs in QEMU on the host.

IMAGE     := mydistro-builder
VOL_WORK  := mydistro-work
VOL_PKG   := mydistro-pkgcache
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

# Work files live in container volumes (ext4): macOS file systems are
# case-insensitive and don't keep Linux ownership. The package cache volume
# means packages are downloaded once.
RUN = container run --rm --cap-add ALL -c $(CPUS) -m $(MEM) \
	-v $(CURDIR):/src \
	-v $(VOL_WORK):/work \
	-v $(VOL_PKG):/var/cache/pacman/pkg \
	-w /src

.PHONY: help builder volumes build ui protocols shell live installed gui demo test clean distclean

help:
	@echo "make build      build out/live.img"
	@echo "make live       boot live image + blank disk in QEMU (Ctrl-A X quits)"
	@echo "make installed  boot the disk the installer wrote"
	@echo "make gui        boot the installed disk in a window (display + input)"
	@echo "make demo       same, and start the compositor with a test window"
	@echo "make ui         quick Swift build of ui/ into out/ui (shared at /mnt/host/ui in the VM)"
	@echo "make test       install, display and compositor tests"
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

volumes:
	@container volume inspect $(VOL_WORK) >/dev/null 2>&1 || container volume create -s 32G $(VOL_WORK)
	@container volume inspect $(VOL_PKG)  >/dev/null 2>&1 || container volume create -s 16G $(VOL_PKG)

build: builder volumes
	$(RUN) $(IMAGE) build/build.sh

# Fast Swift loop: no image rebuild. Debug build, Swift runtime linked in.
ui: builder volumes
	$(RUN) $(IMAGE) sh -c 'swift build --package-path ui --scratch-path /work/swiftpm/dev \
		--static-swift-stdlib && mkdir -p out/ui && \
		find "$$(swift build --package-path ui --scratch-path /work/swiftpm/dev --show-bin-path)" \
			-maxdepth 1 -type f -perm -u+x -exec cp {} out/ui/ \; && ls out/ui'

# Regenerate Wayland protocol C code in ui/ (commit the result).
protocols: builder
	$(RUN) $(IMAGE) ui/Scripts/generate-protocols.sh

shell: builder volumes
	$(RUN) -it $(IMAGE) bash

live:
	vm/run.sh live

installed:
	vm/run.sh installed

gui:
	VM_GPU=window vm/run.sh installed

# The installed system in a window, with the compositor and a test window running.
demo:
	vm/demo.exp

test:
	tests/install.exp
	tests/display.exp
	tests/compositor.exp

clean:
	-container volume rm $(VOL_WORK)
	rm -rf out

distclean: clean
	-container volume rm $(VOL_PKG)
	-container image rm $(IMAGE)
	rm -rf build/cache
