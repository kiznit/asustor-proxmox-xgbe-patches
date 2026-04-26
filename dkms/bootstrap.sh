#!/usr/bin/env bash
#
# Bootstrap the DKMS package for the patched amd-xgbe driver.
#
# Usage:
#   sudo ./bootstrap.sh <path-to-kernel-source-tree>
#
# Example (using a Proxmox pve-kernel checkout):
#   sudo ./bootstrap.sh /root/pve-kernel/proxmox-kernel-6.17.13/ubuntu-kernel
#
# What this does:
#   1. Copies the xgbe source files from the kernel tree into ./src/
#   2. Applies the combined patch
#   3. Installs the result to /usr/src/amd-xgbe-asustor-<version>/
#   4. Registers and builds via DKMS for the running kernel
#   5. After this, every future kernel install will auto-rebuild the module.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root." >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-kernel-source-tree>" >&2
  exit 1
fi

KSRC="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH="${REPO_ROOT}/kernel-6.17/as6806t-xgbe-combined.patch"

XGBE_SRC_DIR="${KSRC}/drivers/net/ethernet/amd/xgbe"
if [[ ! -d "${XGBE_SRC_DIR}" ]]; then
  echo "Could not find ${XGBE_SRC_DIR}" >&2
  echo "Pass the root of a kernel source tree (the directory containing 'drivers/')." >&2
  exit 1
fi

if [[ ! -f "${PATCH}" ]]; then
  echo "Patch not found: ${PATCH}" >&2
  exit 1
fi

# Read package metadata from dkms.conf
PKG_NAME="$(grep '^PACKAGE_NAME=' "${SCRIPT_DIR}/dkms.conf" | cut -d'"' -f2)"
PKG_VERSION="$(grep '^PACKAGE_VERSION=' "${SCRIPT_DIR}/dkms.conf" | cut -d'"' -f2)"
DEST="/usr/src/${PKG_NAME}-${PKG_VERSION}"

echo "==> Copying xgbe sources from ${XGBE_SRC_DIR}"
mkdir -p "${SCRIPT_DIR}/src"
# Wipe any previous sources (but keep the Makefile)
find "${SCRIPT_DIR}/src" -maxdepth 1 -type f ! -name 'Makefile' -delete
cp "${XGBE_SRC_DIR}"/*.c "${XGBE_SRC_DIR}"/*.h "${SCRIPT_DIR}/src/"

echo "==> Applying patch ${PATCH}"
# The patch uses kernel-tree-relative paths (a/drivers/net/ethernet/amd/xgbe/file).
# Strip 6 path components so it applies inside src/ where the bare filenames live.
( cd "${SCRIPT_DIR}/src" && patch -p6 < "${PATCH}" )

echo "==> Installing to ${DEST}"
rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -r "${SCRIPT_DIR}/dkms.conf" "${SCRIPT_DIR}/src" "${DEST}/"

echo "==> Registering with DKMS"
# Remove any prior registration of this version (idempotent re-runs)
dkms remove -m "${PKG_NAME}" -v "${PKG_VERSION}" --all 2>/dev/null || true
dkms add     -m "${PKG_NAME}" -v "${PKG_VERSION}"
dkms build   -m "${PKG_NAME}" -v "${PKG_VERSION}"
dkms install -m "${PKG_NAME}" -v "${PKG_VERSION}" --force

echo "==> Installing module load configuration"
echo "softdep amd-xgbe pre: aquantia" > /etc/modprobe.d/amd-xgbe.conf
if ! grep -qx "aquantia" /etc/initramfs-tools/modules 2>/dev/null; then
  echo "aquantia" >> /etc/initramfs-tools/modules
fi
update-initramfs -u

echo
echo "Done. The patched amd-xgbe module is installed and registered with DKMS."
echo "It will be rebuilt automatically on every future kernel install/upgrade."
echo
echo "Verify with:  dkms status"
echo "Reboot, then: ethtool nic0 | grep -i 'speed\\|link detected'"
