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

The original patches live in [`kernel-6.12/`](kernel-6.12/), downloaded from the [AMD Ryzen Embedded V3000 driver package](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-embedded/ryzen-embedded-v3000-series.html).

| Patch | Description | Why needed |
|-------|------------|------------|
| [**0014**](kernel-6.12/0014-amd-xgbe-extend-driver-functionality-to-support-10Gb.patch) | Extend driver for 10GBase-T MDIO AN | **Critical.** Adds `XGBE_AN_MODE_MDIO` — lets the external AQR113C PHY handle copper negotiation instead of CL73 backplane AN. Without this, the link never comes up. |
| [**0017**](kernel-6.12/0017-amd-xgbe-avoid-sleeping-in-atomic-context.patch) | Avoid sleeping in atomic context | Bug fix. Fixes kernel warning in `xgbe_powerdown()`. |
| [**0031**](kernel-6.12/0031-amd-xgbe-add-missing-tx-and-rx-ethtool-error-counter.patch) | Add missing TX/RX ethtool error counters | Adds proper error counters to ethtool statistics. |
| [**0032**](kernel-6.12/0032-amd-xgbe-add-support-for-new-AN-sequence.patch) | New KR AN sequence + CDR delay tuning | Adds `an_kr_workaround` with improved KR training sequence. Infrastructure for 0123. |
| [**0033**](kernel-6.12/0033-amd-xgbe-handle-link-incompatibility-by-restarting-A.patch) | Restart AN on incompatible-link | Handles hotplug/unplug link incompatibility for Inphi re-driver PHYs. |
| [**0035**](kernel-6.12/0035-amd-xgbe-WA-patch-to-fix-the-AN-issue.patch) | Rate-limit `phy_start_aneg()` for AQR PHY | **Important for stability.** AQR PHYs fail AN when `phy_start_aneg()` is called repeatedly while AN is in progress. Applied manually (depends on 0034 context). |
| [**0123**](kernel-6.12/0123-amd-xgbe-kr-workaround-do-not-apply-to-Base-T.patch) | Disable KR workaround for Base-T ports | **Important.** Disables KR-specific workarounds for 10GBase-T ports where they don't apply. Applied partially (only the `an_kr_workaround = 0` line). |

### Combined patch

[`kernel-6.17/`](kernel-6.17/) contains a [combined patch](kernel-6.17/as6806t-xgbe-combined.patch) with all changes merged into a single file. Tested against **Proxmox VE kernels 6.17.13-3-pve and 6.17.13-4-pve**. This is what the DKMS bootstrap script applies.

## Installation (recommended): DKMS

The [`dkms/`](dkms/) folder contains a self-contained DKMS package that auto-rebuilds the patched module on every kernel upgrade. **This is the recommended approach** — it survives Proxmox kernel updates without manual intervention.

### Prerequisites on the NAS

```bash
apt install dkms build-essential pve-headers-$(uname -r) git
```

### One-time setup

You need a Proxmox kernel source tree on the NAS to extract the xgbe sources. The Proxmox kernel sources live at <https://git.proxmox.com/?p=pve-kernel.git>. Match the branch to your running kernel (e.g. `trixie-6.17` for kernel 6.17.x):

```bash
# Get the Proxmox kernel source
cd /root
git clone --branch trixie-6.17 https://git.proxmox.com/git/pve-kernel.git
cd pve-kernel
make build-dir-fresh
# This populates proxmox-kernel-<ver>/ubuntu-kernel/ with the prepared kernel tree.
# (The build may fail late on the ZFS package — that's fine, the kernel tree is
# already prepared by that point and is all we need.)
```

### Bootstrap the DKMS package

Copy this repository to the NAS, then run:

```bash
cd /root/asustor-proxmox-xgbe-patches/dkms
sudo ./bootstrap.sh /root/pve-kernel/proxmox-kernel-6.17.13/ubuntu-kernel
```

The script will:
1. Copy `drivers/net/ethernet/amd/xgbe/` sources from the kernel tree into [`dkms/src/`](dkms/src/)
2. Apply [`as6806t-xgbe-combined.patch`](kernel-6.17/as6806t-xgbe-combined.patch) on top
3. Install everything to `/usr/src/amd-xgbe-asustor-1.0.0/`
4. Register with DKMS, build, and install the module for the running kernel
5. Configure the `aquantia` softdep + initramfs

After this, **every future `apt upgrade` that pulls a new kernel will trigger an automatic rebuild** of the patched module. No more manual recompiles.

### Verify

```bash
dkms status
# amd-xgbe-asustor/1.0.0, 6.17.13-4-pve, x86_64: installed

# Reboot, then:
ethtool nic0 | grep -i "speed\|link detected"
# Expected: Speed: 10000Mb/s, Link detected: yes
```

### When DKMS may break

DKMS rebuilds against whatever kernel headers are installed. The build will fail if the upstream kernel changes an API the patch depends on (typically only on major version bumps like 6.17 → 6.18). When that happens:

1. Clone an updated kernel source tree matching the new kernel branch
2. Re-run `bootstrap.sh` against it (regenerate the patched sources)
3. If the patch itself needs changes to apply, fix it in [`kernel-6.17/as6806t-xgbe-combined.patch`](kernel-6.17/as6806t-xgbe-combined.patch) and bump `PACKAGE_VERSION` in [`dkms/dkms.conf`](dkms/dkms.conf)

> Routine kernel point-release upgrades (e.g. 6.17.13 → 6.17.15) need no action — DKMS rebuilds automatically.

> **Boot ordering matters:** The `amd-xgbe` driver loads very early via PCI auto-detect (~1.4s into boot). If the `aquantia` PHY driver isn't loaded yet, the MAC can't find the PHY and 10GbE silently fails. Using `/etc/modules-load.d/` alone loads `aquantia` too late. The `softdep` ensures correct ordering whenever `amd-xgbe` loads, and adding `aquantia` to the initramfs makes it available from the earliest boot stage. The bootstrap script configures both.

## Manual build (alternative)

If you prefer a one-off build without DKMS:

```bash
# On the NAS, with a kernel source tree at /root/pve-kernel/proxmox-kernel-6.17.13/ubuntu-kernel
cd /root/pve-kernel/proxmox-kernel-6.17.13/ubuntu-kernel

# Apply the combined patch (the tree is not a git repo, so use plain patch)
patch -p1 < /root/asustor-proxmox-xgbe-patches/kernel-6.17/as6806t-xgbe-combined.patch

# Prepare the build
cp /boot/config-$(uname -r) .config
make olddefconfig
cp /lib/modules/$(uname -r)/build/Module.symvers .
make modules_prepare

# Build just the xgbe module
make M=drivers/net/ethernet/amd/xgbe modules
strip --strip-debug drivers/net/ethernet/amd/xgbe/amd-xgbe.ko

# Install
cp /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/amd/xgbe/amd-xgbe.ko{,.bak}
cp drivers/net/ethernet/amd/xgbe/amd-xgbe.ko \
   /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/amd/xgbe/

echo "softdep amd-xgbe pre: aquantia" > /etc/modprobe.d/amd-xgbe.conf
echo "aquantia" >> /etc/initramfs-tools/modules
depmod -a
update-initramfs -u
```

### Test (without reboot)

```bash
modprobe -r amd-xgbe
modprobe aquantia
modprobe amd-xgbe

# Bring up the interface
ip link set nic0 up
# Apply your network config or:
# ip addr add 192.168.x.x/24 dev nic0

# Verify
ethtool nic0 | grep "Speed\|Link detected"
# Expected: Speed: 10000Mb/s, Link detected: yes
```

## Compatibility

| Kernel | Status |
|--------|--------|
| 6.17.13-3-pve (Proxmox 9) | Tested, working |
| 6.17.13-4-pve (Proxmox 9) | Tested, working (via DKMS) |
| 6.17.x point releases | Should work via DKMS auto-rebuild |
| 6.12.x | Individual patches originate from this series; combined patch not validated here |
| Other versions | Patch may need context adjustments |

## Tested On

- **ASUSTOR AS6806T** (LockerStor Gen3, 6-bay)
- Proxmox VE with kernels 6.17.13-3-pve and 6.17.13-4-pve
- Direct 10GbE copper connection to PC (RJ45)
- Link: 10Gbps/Full, ~0.6ms latency

## Credits

- AMD patches from the [Ryzen Embedded V3000 driver package](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-embedded/ryzen-embedded-v3000-series.html)
- Original patch authors: Raju Rangoju, Kalyan Rankireddy, Ramesh Garidapuri (AMD)
- See also: [Reddit discussion on ASUSTOR 10GbE issues](https://www.reddit.com/r/asustor/comments/1h9zvs9/)
