# Out-of-tree Makefile for the patched amd-xgbe driver.
# Built via DKMS for the running/target kernel.

obj-m := amd-xgbe.o

amd-xgbe-objs := xgbe-main.o xgbe-drv.o xgbe-dev.o \
                 xgbe-desc.o xgbe-ethtool.o xgbe-mdio.o \
                 xgbe-hwtstamp.o xgbe-ptp.o \
                 xgbe-i2c.o xgbe-phy-v1.o xgbe-phy-v2.o \
                 xgbe-platform.o

amd-xgbe-$(CONFIG_PCI)          += xgbe-pci.o
amd-xgbe-$(CONFIG_AMD_XGBE_DCB) += xgbe-dcb.o
amd-xgbe-$(CONFIG_DEBUG_FS)     += xgbe-debugfs.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean
