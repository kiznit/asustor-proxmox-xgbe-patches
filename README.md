# AMD XGBE 10GbE Patches for ASUSTOR NAS + Proxmox

Patches to fix 10GbE networking on ASUSTOR LockerStor Gen3 NAS devices (AS6806T, AS6810T) running Proxmox VE.

## Problem

ASUSTOR Gen3 NAS devices use AMD Rembrandt (Yellow Carp) SoCs with integrated AMD XGBE 10GbE MAC connected to an **Aquantia AQR113C** external 10GBase-T PHY via CL45 MDIO. Under ASUSTOR's ADM operating system, 10GbE works out of the box. Under Proxmox (or any mainline Linux), the link never comes up.

**Root cause:** The upstream `amd-xgbe` kernel driver uses CL73 backplane auto-negotiation for 10GBase-T ports. CL73 is the wrong protocol for copper — the external Aquantia PHY needs to handle negotiation via MDIO sideband instead. AMD ships patches for their embedded platforms (Ryzen Embedded V3000 series) that add MDIO AN mode support, but these have not been upstreamed.

## Hardware

| Field | Value |
|-------|-------|
| NAS | ASUSTOR AS6806T (LockerStor Gen3) |
| SoC | AMD Rembrandt (Yellow Carp) |
| 10GbE MAC | AMD XGBE (PCI `0000:e8:00.2`, `0000:e8:00.3`) |
| 10GbE PHY | Aquantia AQR113C (CL45 MDIO, address 0) |
| Port mode | 6 (`XGBE_PORT_MODE_10GBASE_T`) |
| Connection type | 2 (`XGBE_CONN_TYPE_MDIO`) |
| Port speeds | 0x1c (1G + 2.5G + 10G) |

## Solution

Three things are required:

1. **Patch the `amd-xgbe` kernel module** — adds MDIO AN mode so the Aquantia PHY handles copper negotiation
2. **Load the `aquantia` kernel module** — provides the AQR113C PHY driver (already in the kernel, just not loaded by default)
3. **Ensure `aquantia` loads before `amd-xgbe`** — via `softdep` in `/etc/modprobe.d/` and adding `aquantia` to the initramfs (using `/etc/modules-load.d/` alone is too late — `amd-xgbe` loads via PCI auto-detect very early in boot)

## Patches

### Individual AMD patches (from source)

The original patches live in [`kernel-6.12.40/`](kernel-6.12.40/), downloaded from the [AMD Ryzen Embedded V3000 driver package](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-embedded/ryzen-embedded-v3000-series.html).

| Patch | Description | Why needed |
|-------|------------|------------|
| [**0014**](kernel-6.12.40/0014-amd-xgbe-extend-driver-functionality-to-support-10Gb.patch) | Extend driver for 10GBase-T MDIO AN | **Critical.** Adds `XGBE_AN_MODE_MDIO` — lets the external AQR113C PHY handle copper negotiation instead of CL73 backplane AN. Without this, the link never comes up. |
| [**0017**](kernel-6.12.40/0017-amd-xgbe-avoid-sleeping-in-atomic-context.patch) | Avoid sleeping in atomic context | Bug fix. Fixes kernel warning in `xgbe_powerdown()`. |
| [**0031**](kernel-6.12.40/0031-amd-xgbe-add-missing-tx-and-rx-ethtool-error-counter.patch) | Add missing TX/RX ethtool error counters | Adds proper error counters to ethtool statistics. |
| [**0032**](kernel-6.12.40/0032-amd-xgbe-add-support-for-new-AN-sequence.patch) | New KR AN sequence + CDR delay tuning | Adds `an_kr_workaround` with improved KR training sequence. Infrastructure for 0123. |
| [**0033**](kernel-6.12.40/0033-amd-xgbe-handle-link-incompatibility-by-restarting-A.patch) | Restart AN on incompatible-link | Handles hotplug/unplug link incompatibility for Inphi re-driver PHYs. |
| [**0035**](kernel-6.12.40/0035-amd-xgbe-WA-patch-to-fix-the-AN-issue.patch) | Rate-limit `phy_start_aneg()` for AQR PHY | **Important for stability.** AQR PHYs fail AN when `phy_start_aneg()` is called repeatedly while AN is in progress. Applied manually (depends on 0034 context). |
| [**0123**](kernel-6.12.40/0123-amd-xgbe-kr-workaround-do-not-apply-to-Base-T.patch) | Disable KR workaround for Base-T ports | **Important.** Disables KR-specific workarounds for 10GBase-T ports where they don't apply. Applied partially (only the `an_kr_workaround = 0` line). |

### Combined patch

[`kernel-6.17.13/`](kernel-6.17.13/) contains a [combined patch](kernel-6.17.13/as6806t-xgbe-combined.patch) with all changes merged into a single file, tested against **Proxmox VE kernel 6.17.13-3-pve**.

### Precompiled module

There's also a [precompiled `amd-xgbe.ko`](kernel-6.17.13/bin/amd-xgbe.ko) in [`kernel-6.17.13/bin/`](kernel-6.17.13/bin/) — I left it here for my own future convenience. You, of course, would never trust a random kernel module found on the Internet. Right? *Right?*

## Build Instructions

### Prerequisites

- Proxmox VE kernel source tree (matching your running kernel)
- Kernel headers and build tools (`build-essential`, `linux-headers-$(uname -r)`)
- The running kernel's `Module.symvers` (copy from `/lib/modules/$(uname -r)/build/`)

### Build

```bash
cd /path/to/kernel-source

# Apply the combined patch
git apply /path/to/as6806t-xgbe-combined.patch

# Prepare kernel build (if not already done)
cp /boot/config-$(uname -r) .config
make olddefconfig
make modules_prepare

# Copy Module.symvers from installed kernel headers
cp /lib/modules/$(uname -r)/build/Module.symvers .

# Build just the xgbe module
make M=drivers/net/ethernet/amd/xgbe modules

# Strip debug symbols
strip --strip-debug drivers/net/ethernet/amd/xgbe/amd-xgbe.ko
```

### Install

```bash
# Back up original module
cp /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/amd/xgbe/amd-xgbe.ko \
   /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/amd/xgbe/amd-xgbe.ko.bak

# Install patched module
cp drivers/net/ethernet/amd/xgbe/amd-xgbe.ko \
   /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/amd/xgbe/amd-xgbe.ko

# Ensure aquantia loads BEFORE amd-xgbe (boot ordering is critical)
echo "softdep amd-xgbe pre: aquantia" > /etc/modprobe.d/amd-xgbe.conf
echo "aquantia" >> /etc/initramfs-tools/modules

# Update module dependencies and rebuild initramfs
depmod -a
update-initramfs -u
```

> **Boot ordering matters:** The `amd-xgbe` driver loads very early via PCI auto-detect (~1.4s into boot). If the `aquantia` PHY driver isn't loaded yet, the MAC can't find the PHY and 10GbE silently fails. Using `/etc/modules-load.d/` alone loads `aquantia` too late. The `softdep` ensures correct ordering whenever `amd-xgbe` loads, and adding `aquantia` to the initramfs makes it available from the earliest boot stage.

### Test (without reboot)

```bash
modprobe -r amd-xgbe
modprobe aquantia
modprobe amd-xgbe

# Bring up the interface
ip link set nic4 up
# Apply your network config or:
# ip addr add 192.168.x.x/24 dev nic4

# Verify
ethtool nic4 | grep "Speed\|Link detected"
# Expected: Speed: 10000Mb/s, Link detected: yes
```

## Compatibility

| Kernel | Status |
|--------|--------|
| 6.17.13-3-pve (Proxmox 9) | Tested, working |
| 6.12.x | Should work (patches originate from this version) |
| Other versions | Patch may need context adjustments |

> **Note:** When Proxmox updates the kernel package, the patched module will be overwritten. You'll need to reinstall after kernel updates.

## Tested On

- **ASUSTOR AS6806T** (LockerStor Gen3, 6-bay)
- Proxmox VE with kernel 6.17.13-3-pve
- Direct 10GbE copper connection to PC (RJ45)
- Link: 10Gbps/Full, ~0.3ms latency

## Credits

- AMD patches from the [Ryzen Embedded V3000 driver package](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-embedded/ryzen-embedded-v3000-series.html)
- Original patch authors: Raju Rangoju, Kalyan Rankireddy, Ramesh Garidapuri (AMD)
- See also: [Reddit discussion on ASUSTOR 10GbE issues](https://www.reddit.com/r/asustor/comments/1h9zvs9/)
