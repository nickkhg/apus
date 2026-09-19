# mydistro - host-side entry point. The build runs inside an Apple `container`;
# testing runs in QEMU on the host.

IMAGE    := mydistro-builder
VOL_OUT  := mydistro-output
VOL_DL   := mydistro-dl
CPUS     ?= 8
MEM      ?= 8g
VERSION  := $(shell git describe --always --dirty 2>/dev/null || echo dev)

# Build output lives in container volumes (ext4, case-sensitive). macOS
# filesystems are case-insensitive and break the kernel build.
RUN = container run --rm -c $(CPUS) -m $(MEM) \
	-v $(CURDIR):/src \
	-v $(VOL_OUT):/work/output \
	-v $(VOL_DL):/work/dl \
	-e MYDISTRO_VERSION=$(VERSION) \
	-w /src $(IMAGE)

.PHONY: help builder volumes build menuconfig linux-menuconfig savedefconfig \
        shell live installed test clean distclean

help:
	@echo "make build             build out/live.img (first run: ~15-30 min)"
	@echo "make live              boot live image + blank disk in QEMU (Ctrl-A X quits)"
	@echo "make installed         boot the disk the installer wrote"
	@echo "make test              automated install + reboot test"
	@echo "make menuconfig        edit Buildroot config, then 'make savedefconfig'"
	@echo "make linux-menuconfig  edit kernel config"
	@echo "make shell             shell in the build container"
	@echo "make br-<target>       any Buildroot target, e.g. br-util-linux-reconfigure"
	@echo "make clean             wipe build output (keeps downloads)"
	@echo "make distclean         also remove downloads and builder image"

builder:
	container build -t $(IMAGE) -f build/Containerfile build

volumes:
	@container volume inspect $(VOL_OUT) >/dev/null 2>&1 || container volume create -s 64G $(VOL_OUT)
	@container volume inspect $(VOL_DL)  >/dev/null 2>&1 || container volume create -s 16G $(VOL_DL)

build: builder volumes
	$(RUN) build/br.sh build

# Pass-through to Buildroot: `make br-busybox-rebuild`, `make br-linux-reconfigure`, ...
br-%: builder volumes
	$(RUN) build/br.sh $*

menuconfig linux-menuconfig savedefconfig: builder volumes
	container run --rm -it -v $(CURDIR):/src -v $(VOL_OUT):/work/output \
		-v $(VOL_DL):/work/dl -w /src $(IMAGE) build/br.sh $@

shell: builder volumes
	container run --rm -it -c $(CPUS) -m $(MEM) -v $(CURDIR):/src \
		-v $(VOL_OUT):/work/output -v $(VOL_DL):/work/dl -w /src $(IMAGE) bash

live:
	vm/run.sh live

installed:
	vm/run.sh installed

test:
	tests/install.exp

clean:
	-container volume rm $(VOL_OUT)
	rm -rf out

distclean: clean
	-container volume rm $(VOL_DL)
	-container image rm $(IMAGE)
