#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Setup script for KernelSU Next integration
# Run this after cloning the repository

set -e

KERNEL_DIR="$(pwd)"

echo "Setting up KernelSU Next for Tensor G3 (zuma) kernel..."

# Verify KernelSU Next is present
if [[ ! -d "${KERNEL_DIR}/kernelsu-next" ]]; then
    echo "Cloning KernelSU Next..."
    git clone --depth=1 -b dev https://github.com/KernelSU-Next/KernelSU-Next.git kernelsu-next
fi

# Verify kernel source structure
echo "Verifying kernel structure..."
REQUIRED_DIRS=(
    "google-devices/zuma"
    "google-modules/bluetooth/broadcom"
    "google-modules/wlan/bcm4389"
    "google-modules/power/mitigation"
    "google-modules/power/reset"
    "kernelsu-next"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ ! -d "${KERNEL_DIR}/${dir}" ]]; then
        echo "ERROR: Missing required directory: ${dir}"
        exit 1
    fi
done

# Check for Kconfig integration
if ! grep -q "kernelsu-next/Kconfig" "${KERNEL_DIR}/Kconfig"; then
    echo "ERROR: KernelSU Next not integrated in main Kconfig"
    exit 1
fi

# Check for zuma Kconfig additions
if ! grep -q "BLUETOOTH_POWERSAVE_EXCLUDE" "${KERNEL_DIR}/google-devices/zuma/Kconfig.ext.zuma"; then
    echo "ERROR: Power saving exclusion configs not found in zuma Kconfig"
    exit 1
fi

# Verify nitrous.c modifications
if ! grep -q "BLUETOOTH_POWERSAVE_EXCLUDE" "${KERNEL_DIR}/google-modules/bluetooth/broadcom/nitrous.c"; then
    echo "ERROR: Bluetooth power saving exclusion not implemented in nitrous.c"
    exit 1
fi

# Verify WiFi Kbuild modifications
if ! grep -q "WIFI_POWERSAVE_EXCLUDE" "${KERNEL_DIR}/google-modules/wlan/bcm4389/Kbuild"; then
    echo "ERROR: WiFi power saving exclusion not implemented in Kbuild"
    exit 1
fi

# Verify restart retry in pixel-zuma-reboot.c
if ! grep -q "MAX_RESTART_RETRIES" "${KERNEL_DIR}/google-modules/power/reset/pixel-zuma-reboot.c"; then
    echo "ERROR: Restart retry mechanism not implemented"
    exit 1
fi

# Verify build config
if ! grep -q "CONFIG_KSU=y" "${KERNEL_DIR}/build.config.common"; then
    echo "ERROR: KernelSU config not in build.config.common"
    exit 1
fi

echo "✅ All checks passed! Kernel is ready to build."
echo ""
echo "To build the kernel:"
echo "  chmod +x build_kernel.sh"
echo "  ./build_kernel.sh"
echo ""
echo "To build with debug symbols:"
echo "  ./build_kernel.sh --debug"
echo ""
echo "Artifacts will be in: dist/"