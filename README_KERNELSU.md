# Tensor G3 (zuma) Kernel with KernelSU Next

Custom kernel for Google Pixel 8 series (Tensor G3/zuma) with KernelSU Next root solution, Bluetooth/WiFi power saving exclusions, and enhanced restart reliability.

## Features

### 🔐 KernelSU Next
- **Kernel-based root solution** for Android 14+
- Supports KernelSU manager app for per-app root management
- Module system based on Magic Mount and OverlayFS
- App Profile system for granular root permission control
- Compatible with GKI 2.0 (kernel 5.10+)

### 🔋 Power Saving Exclusions (Hardware Workarounds)
- **Bluetooth excluded from power saving** - Prevents Bluetooth connectivity issues during suspend/resume
- **WiFi excluded from power saving** - Prevents WiFi disconnection issues during suspend/resume
- These are software workarounds for hardware/firmware limitations

### 🔄 Enhanced Restart Reliability
- **10 restart retry attempts** with 1-second delay between attempts
- Logs each restart attempt for debugging
- Prevents boot loops from transient restart failures

### 📱 Compatibility
- ✅ **Google Stock ROMs** (Pixel 8/8 Pro/8a)
- ✅ **AOSP-based ROMs** (LineageOS, GrapheneOS, CalyxOS, etc.)
- ✅ **GKI 2.0** compatible
- ✅ **Android 14+** (API 34+)

## Supported Devices

| Device | Codename | SoC | Status |
|--------|----------|-----|--------|
| Pixel 8 | shusky | Tensor G3 (zuma) | ✅ Supported |
| Pixel 8 Pro | husky | Tensor G3 (zuma) | ✅ Supported |
| Pixel 8a | akita | Tensor G3 (zuma) | ✅ Supported |
| Pixel 9 | tokay | Tensor G4 (zumapro) | ❌ Not in this build |
| Pixel 7 | panther | Tensor G2 (gs201) | ❌ Not in this build |

## Building

### Prerequisites
- Ubuntu 22.04+ or similar Linux distribution
- 16GB+ RAM recommended
- 50GB+ free disk space
- LLVM/Clang 17+
- aarch64-linux-gnu toolchain

### Quick Build

```bash
# Clone repository
git clone https://github.com/saltykingpeppermint/android_kernel_google_tensynosv2.git
cd android_kernel_google_tensynos

# Make build script executable
chmod +x build_kernel.sh

# Build release kernel
./build_kernel.sh

# Build debug kernel
./build_kernel.sh --debug

# Clean build
./build_kernel.sh --clean
```

### Build Options

| Option | Description |
|--------|-------------|
| `-c, --clean` | Clean build directory before building |
| `-d, --debug` | Build debug kernel with symbols |
| `-j, --jobs N` | Number of parallel jobs (default: all cores) |
| `--no-modules` | Skip building kernel modules |
| `--no-dtb` | Skip building device tree blobs |
| `--no-flashable` | Skip creating flashable AnyKernel3 zip |
| `--sign` | Sign kernel image (requires keys in `keys/`) |

### Output Artifacts

After successful build, find artifacts in `dist/`:
- `Image` - Kernel image
- `config` - Kernel configuration
- `vmlinux` - Uncompressed kernel with symbols
- `System.map` - Kernel symbol map
- `dtb/` - Device tree blobs
- `modules/` - Kernel modules
- `KernelSU-Next-zuma-YYYYMMDD.zip` - Flashable AnyKernel3 zip

## Installation

### Via Recovery (Recommended)

1. Download the latest `KernelSU-Next-zuma-*.zip` from releases
2. Boot to custom recovery (TWRP, Lineage Recovery, etc.)
3. Flash the zip file
4. Reboot
5. Install KernelSU Manager app from [GitHub Releases](https://github.com/KernelSU-Next/KernelSU-Next/releases)

### Via Fastboot (Advanced)

```bash
# Flash kernel image
fastboot flash boot_a Image
fastboot flash boot_b Image

# Flash dtbo if needed
fastboot flash dtbo_a dtb/google/...dtbo
fastboot flash dtbo_b dtb/google/...dtbo
```

## Configuration Options

### Kernel Configs (in `zuma_defconfig` or via `make menuconfig`)

| Config | Default | Description |
|--------|---------|-------------|
| `CONFIG_KSU` | `y` | Enable KernelSU Next |
| `CONFIG_KSU_DEBUG` | `n` | Enable KernelSU debug logging |
| `CONFIG_KSU_DISABLE_MANAGER` | `n` | Disable manager integration |
| `CONFIG_KSU_DISABLE_POLICY` | `n` | Disable per-app profiles |
| `CONFIG_BLUETOOTH_POWERSAVE_EXCLUDE` | `y` | Exclude BT from power saving |
| `CONFIG_WIFI_POWERSAVE_EXCLUDE` | `y` | Exclude WiFi from power saving |
| `CONFIG_DEBUG_REBOOT` | `m` | Enable reboot debugging |

### Runtime Control (via /proc or sysfs)

```bash
# Check Bluetooth power saving status
cat /proc/bluetooth/sleep/lpm

# Disable Bluetooth LPM (if not excluded at compile time)
echo 0 > /proc/bluetooth/sleep/lpm

# Check WiFi power saving (via dhd driver)
# Note: Controlled at compile time via CONFIG_WIFI_POWERSAVE_EXCLUDE
```

## KernelSU Next Usage

### Install Manager App
1. Download latest `KernelSU.apk` from [releases](https://github.com/KernelSU-Next/KernelSU-Next/releases)
2. Install on device
3. Open app and grant root permissions

### App Profiles
- Configure per-app root access in KernelSU Manager
- Profiles: `Root`, `Unroot`, `Shell only`, `Custom`
- Settings persist across reboots

### Module System
- Place Magisk/KernelSU modules in `/data/adb/modules/`
- Modules auto-mounted on boot
- Supports both Magic Mount and OverlayFS

## Troubleshooting

### Bootloop after flash
1. Boot to recovery
2. Flash stock boot image
3. Check `dmesg` / `logcat` for errors
4. Try debug build for more logging

### KernelSU not working
1. Verify `CONFIG_KSU=y` in kernel config
2. Check KernelSU Manager app version compatibility
3. Verify SELinux is enforcing
4. Check `dmesg | grep -i kernelsu`

### Bluetooth/WiFi issues
- Power saving exclusions are compile-time only
- To re-enable power saving, rebuild with `CONFIG_BLUETOOTH_POWERSAVE_EXCLUDE=n`
- These are workarounds - actual hardware issues need firmware fixes

### Restart failures
- Kernel will retry restart up to 10 times
- Check `dmesg` for "Restart attempt X of 10" messages
- If all retries fail, hardware issue likely

## Development

### Adding KernelSU Next Updates
```bash
cd kernelsu-next
git pull origin dev
# Copy updated files to kernel source if needed
```

### Upstream Kernel Updates
```bash
# Merge upstream changes
git fetch https://github.com/kerneltoast/android_kernel_google_tensynos.git 16.0.0-sultan
git merge FETCH_HEAD
# Resolve conflicts, rebuild
```

### Custom Configurations
Edit `google-devices/zuma/zuma_defconfig` or use:
```bash
make O=out menuconfig
```

## License

- **Kernel**: GPL-2.0-only
- **KernelSU Next**: GPL-2.0-only (kernel), GPL-3.0-or-later (userspace)
- **Broadcom WiFi**: Proprietary (GPL-2.0 with exceptions)
- **Google modifications**: GPL-2.0-only

## Credits

- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) - KernelSU Next project
- [kerneltoast](https://github.com/kerneltoast/android_kernel_google_tensynos) - Base Tensor kernel
- [osm0sis](https://github.com/osm0sis/AnyKernel3) - AnyKernel3 installation framework
- Google - Pixel kernel source

## Disclaimer

**This kernel includes software workarounds for hardware issues.** The Bluetooth and WiFi power saving exclusions prevent the hardware from entering low-power states that cause connectivity problems. This may slightly reduce battery life but improves stability.

**Root access modifies system security.** Use responsibly. Some apps (banking, DRM, SafetyNet/Play Integrity) may detect root and refuse to work.

**Flash at your own risk.** Always backup your data and have a way to restore stock firmware.

## Support

- Issues: [GitHub Issues](https://github.com/saltykingpeppermint/android_kernel_google_tensynosv2/issues)
- KernelSU Next: [Discord](https://discord.gg/kernelsu) | [Telegram](https://t.me/KernelSU_Next)
- Pixel Kernel Development: [XDA Forum](https://forum.xda-developers.com/c/google-pixel-8-pro-development.14102/)
