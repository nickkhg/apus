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
BUILDER_STAMP := build/cache/builder.stamp

# Work files live in container volumes (ext4): macOS file systems are
# case-insensitive and don't keep Linux ownership. The package cache volume
# means packages are downloaded once.
RUN = container run --rm --cap-add ALL -c $(CPUS) -m $(MEM) \
	-v $(CURDIR):/src \
	-v $(VOL_WORK):/work \
	-v $(VOL_PKG):/var/cache/pacman/pkg \
	-w /src

.PHONY: help builder volumes build shell live installed test clean distclean

help:
	@echo "make build      build out/live.img"
	@echo "make live       boot live image + blank disk in QEMU (Ctrl-A X quits)"
	@echo "make installed  boot the disk the installer wrote"
	@echo "make test       automated install + reboot test"
	@echo "make shell      root shell in the build container"
	@echo "make clean      remove build output (keeps package cache)"
	@echo "make distclean  also remove package cache, builder image, base tarball"

$(ALARM_TARBALL):
	mkdir -p $(dir $@)
	curl -fL --no-progress-meter -o $@.part $(ALARM_URL)
	echo "$(ALARM_SHA256)  $@.part" | shasum -a 256 -c -
	mv $@.part $@

$(BUILDER_STAMP): build/Containerfile $(ALARM_TARBALL)
	container build -t $(IMAGE) -f build/Containerfile build
	touch $@

builder: $(BUILDER_STAMP)

volumes:
	@container volume inspect $(VOL_WORK) >/dev/null 2>&1 || container volume create -s 32G $(VOL_WORK)
	@container volume inspect $(VOL_PKG)  >/dev/null 2>&1 || container volume create -s 16G $(VOL_PKG)

build: builder volumes
	$(RUN) $(IMAGE) build/build.sh

shell: builder volumes
	$(RUN) -it $(IMAGE) bash

live:
	vm/run.sh live

installed:
	vm/run.sh installed

test:
	tests/install.exp

clean:
	-container volume rm $(VOL_WORK)
	rm -rf out

distclean: clean
	-container volume rm $(VOL_PKG)
	-container image rm $(IMAGE)
	rm -rf build/cache
