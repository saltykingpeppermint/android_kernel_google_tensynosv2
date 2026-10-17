#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build script for Tensor G3 (zuma) kernel with KernelSU Next and power saving exclusions
# Compatible with Google Stock ROMs and AOSP/LineageOS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KERNEL_DIR="$(pwd)"
BUILD_DIR="${KERNEL_DIR}/out"
DIST_DIR="${KERNEL_DIR}/dist"
ANYKERNEL_DIR="${KERNEL_DIR}/anykernel3"
DEFCONFIG="gki-stock_defconfig"
KERNEL_IMAGE="${BUILD_DIR}/arch/arm64/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/arm64/boot/dts/google"
MODULES_DIR="${BUILD_DIR}/modules"

# Build options
JOBS=$(nproc)
CLANG_VERSION="r547379"
LLVM=1

# KernelSU Next. Keep false for a guaranteed-bootable baseline kernel; flip to
# true once you have verified CONFIG_KSU survives olddefconfig. Requires
# CONFIG_KPROBES, which arch/Kconfig declares as `depends on MODULES` -- the
# clang defconfig (gki-stock) has MODULES=y so this is satisfiable there, unlike
# the old GCC zuma_defconfig which set INTEGRATE_MODULES=y and forced MODULES=n.
ENABLE_KSU=false

# Parse arguments
BUILD_TYPE="release"
CLEAN_BUILD=false
BUILD_MODULES=true
BUILD_DTB=true
CREATE_FLASHABLE=true
SIGN_BUILD=false

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -c, --clean           Clean build directory before building"
    echo "  -d, --debug           Build debug kernel"
    echo "  -j, --jobs N          Number of parallel jobs (default: $(nproc))"
    echo "  --no-modules          Skip building modules"
    echo "  --no-dtb              Skip building DTB"
    echo "  --no-flashable        Skip creating flashable zip"
    echo "  --sign                Sign the kernel image (requires keys)"
    echo "  -h, --help            Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -d|--debug)
            BUILD_TYPE="debug"
            shift
            ;;
        -j|--jobs)
            JOBS="$2"
            shift 2
            ;;
        --no-modules)
            BUILD_MODULES=false
            shift
            ;;
        --no-dtb)
            BUILD_DTB=false
            shift
            ;;
        --no-flashable)
            CREATE_FLASHABLE=false
            shift
            ;;
        --sign)
            SIGN_BUILD=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v clang &> /dev/null; then
        error "clang not found in PATH"
        exit 1
    fi
    
    if ! command -v lld &> /dev/null; then
        error "lld not found in PATH"
        exit 1
    fi
    
    if ! command -v python3 &> /dev/null; then
        error "python3 not found in PATH"
        exit 1
    fi
    
    success "Dependencies check passed"
}

# Clean build directory
clean_build() {
    if [[ "$CLEAN_BUILD" == true ]]; then
        log "Cleaning build directory..."
        rm -rf "${BUILD_DIR}"
        rm -rf "${DIST_DIR}"
        success "Build directory cleaned"
    fi
}

# Setup build environment
setup_environment() {
    log "Setting up build environment..."
    
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${DIST_DIR}"
    
    # Source build config
    source "${KERNEL_DIR}/build.config.common"
    source "${KERNEL_DIR}/google-devices/zuma/build.config.zuma"
    
    # Set up the toolchain.
    #
    # MUST be pure LLVM here. Setting CROSS_COMPILE alongside LLVM=1 makes the
    # Makefile probe compiler flags with GCC semantics, so cc-option accepts
    # GCC-only options (-fipa-pta, -fwhole-program, -fuse-linker-plugin,
    # -fno-fat-lto-objects) and hands them to clang, which rejects them;
    # -Werror then turns those into hard errors during prepare0.
    # LLVM=1 already implies CC=clang, LD=ld.lld, AR=llvm-ar, NM=llvm-nm,
    # OBJCOPY/OBJDUMP/READELF/STRIP=llvm-*.
    export ARCH=arm64
    export SUBARCH=arm64
    unset CROSS_COMPILE
    unset CROSS_COMPILE_ARM32
    unset CLANG_TRIPLE
    export LLVM=1
    export LLVM_IAS=1
    
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        export KBUILD_BUILD_HOST="kernel-build"
        export KBUILD_BUILD_USER="builder"
        export KBUILD_BUILD_TIMESTAMP="$(date -u +'%Y-%m-%d %H:%M:%S')"
        KCFLAGS="${KCFLAGS} -g -O0"
    fi
    
    success "Environment setup complete"
}

# Configure kernel
configure_kernel() {
    log "Configuring kernel..."
    
    cd "${KERNEL_DIR}"
    
    # Drop orphaned vendor-hook exports.
    #
    # Upstream 16.0.0-sultan ships kernel/sched/vendor_hooks.c exporting 109
    # tracepoints while include/trace/hooks/sched.h only declares 108. The
    # extra one, android_rvh_effective_cpu_util, is never declared, so it
    # expands into references to nonexistent __tracepoint_/__traceiter_
    # symbols and clang fails with "use of undeclared identifier". Upstream
    # hides this by keeping CONFIG_TRIM_UNUSED_KSYMS=y, under which the export
    # macro never references the symbol at compile time; we disable trimming,
    # which exposes it. Nothing in the tree calls the hook, so removing the
    # dead export is safe. Done generically so it tracks future hook changes.
    if [ -d "${KERNEL_DIR}/include/trace/hooks" ]; then
        grep -rhoE 'DECLARE_(RESTRICTED_)?HOOK\(\s*[a-z0-9_]+' "${KERNEL_DIR}/include/trace/hooks/" 2>/dev/null \
            | grep -oE '[a-z0-9_]+$' | sort -u > /tmp/hook_declared.txt
        grep -oE 'EXPORT_TRACEPOINT_SYMBOL_GPL\(\s*android_r?vh_[a-z0-9_]+' "${KERNEL_DIR}/kernel/sched/vendor_hooks.c" 2>/dev/null \
            | grep -oE 'android_r?vh_[a-z0-9_]+$' | sort -u > /tmp/hook_exported.txt
        comm -13 /tmp/hook_declared.txt /tmp/hook_exported.txt > /tmp/hook_orphans.txt
        while IFS= read -r orphan; do
            [ -z "${orphan}" ] && continue
            warn "Removing orphaned vendor-hook export: ${orphan}"
            sed -i "s|EXPORT_TRACEPOINT_SYMBOL_GPL(${orphan});|/* orphan export removed: ${orphan} is never declared */|" \
                 "${KERNEL_DIR}/kernel/sched/vendor_hooks.c"
        done < /tmp/hook_orphans.txt
    fi

    # Restore the missing shrinker_rwsem declaration.
    #
    # mm/vmscan.c uses &shrinker_rwsem in 14 places, all under CONFIG_MEMCG,
    # but nothing in the tree declares it, so vmscan.o fails with "use of
    # undeclared identifier" for any config with MEMCG=y. include/linux/
    # shrinker.h has no mention of it, and CONFIG_SHRINKER_DEBUG -- the only
    # other candidate -- is `depends on NEVER` in lib/Kconfig.debug, so it
    # cannot be enabled. Mainline keeps it as a file-scope static beside the
    # other shrinker locks; restore exactly that. All references are inside
    # mm/vmscan.c, so static is correct.
    if [ -f "${KERNEL_DIR}/mm/vmscan.c" ] \
       && grep -q 'DEFINE_RWLOCK(shrinker_rwlock)' "${KERNEL_DIR}/mm/vmscan.c" \
       && ! grep -q 'DECLARE_RWSEM(shrinker_rwsem)' "${KERNEL_DIR}/mm/vmscan.c"; then
        warn "Restoring missing DECLARE_RWSEM(shrinker_rwsem) in mm/vmscan.c"
        awk '{print} /^static DEFINE_RWLOCK\(shrinker_rwlock\);$/ {print "#ifdef CONFIG_MEMCG"; print "static DECLARE_RWSEM(shrinker_rwsem);"; print "#endif"}' \
             "${KERNEL_DIR}/mm/vmscan.c" > "${KERNEL_DIR}/mm/vmscan.c.tmp" \
            && mv "${KERNEL_DIR}/mm/vmscan.c.tmp" "${KERNEL_DIR}/mm/vmscan.c"
    fi
    if [ -f "${KERNEL_DIR}/mm/vmscan.c" ] \
       && ! grep -q 'DECLARE_RWSEM(shrinker_rwsem)' "${KERNEL_DIR}/mm/vmscan.c"; then
        error "mm/vmscan.c is missing DECLARE_RWSEM(shrinker_rwsem); vmscan.o cannot compile with MEMCG=y"
        exit 1
    fi

    make O="${BUILD_DIR}" "${DEFCONFIG}"

    # Layer the Tensor G3 device drivers onto the generic GKI defconfig. The
    # root Kconfig gates google-devices/zuma/Kconfig.ext.zuma (45 Google/
    # Exynos driver Kconfigs: zram, clk, cpufreq, power, pinctrl, ...) behind
    # the KCONFIG_EXT_ZUMA choice symbol, which defaults to KCONFIG_EXT_NONE.
    # Without this the build is generic GKI with no WiFi/BT/charging/display
    # drivers and will not boot on a Pixel 8.
    ./scripts/config --file "${BUILD_DIR}/.config" --enable KCONFIG_EXT_ZUMA

    # gki-stock_defconfig is a generic GKI snapshot with no Tensor/Exynos SoC
    # identity. The device drivers layered in above need CONFIG_SOC_ZUMA to
    # pick their platform header: without it exynos-pmu-if.h hits
    # #error "Unknown CONFIG_SOC" and aoc-interface.h hits
    # #error "Unsupported platform!", leaving every AoC source compiling
    # against no platform header and producing a cascade of bogus errors.
    ./scripts/config --file "${BUILD_DIR}/.config" --enable SOC_GOOGLE --enable SOC_ZUMA

    # gki-stock_defconfig ships two settings that only make sense on Google's
    # internal Bazel build machines:
    #   CONFIG_TRIM_UNUSED_KSYMS=y
    #   CONFIG_UNUSED_KSYMS_WHITELIST="/mnt/disks/build-disk/src/android/
    #       common-android14-6.1-2024-04/out/bazel/.../abi_symbollist.raw"
    # That whitelist is an absolute Google-internal path that does not exist on
    # this machine, so scripts/gen_autoksyms.sh:35 fails and prints
    # "ERROR: '<path>' whitelist file not found" before exiting 1, killing the
    # build at Makefile:1330 (include/generated/autoksyms.h) with no compiler
    # output. Trimmed exported symbols only serve Google's KMI restriction, and
    # keeping a superset of them is always safe, so turn it all off.
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --disable TRIM_UNUSED_KSYMS \
        --undefine UNUSED_KSYMS_WHITELIST

    # Enable additional configs.
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --enable BLUETOOTH_POWERSAVE_EXCLUDE \
        --enable WIFI_POWERSAVE_EXCLUDE \
        --enable DEBUG_REBOOT \
        --set-str LOCALVERSION "-kernelsu-next"
    if [[ "${ENABLE_KSU}" == "true" ]]; then
        ./scripts/config --file "${BUILD_DIR}/.config" \
            --enable KSU \
            --enable KPROBES \
            --enable EXT4_FS
    fi

    # Run make olddefconfig to resolve dependencies
    make O="${BUILD_DIR}" olddefconfig

    # Sanity-check that our options survived. These fire at config time rather
    # than minutes into the build with no message.
    if ! grep -q '^CONFIG_KCONFIG_EXT_ZUMA=y' "${BUILD_DIR}/.config"; then
        error "CONFIG_KCONFIG_EXT_ZUMA lost; zuma device drivers would NOT be built"
        exit 1
    fi
    if ! grep -q '^CONFIG_SOC_ZUMA=y' "${BUILD_DIR}/.config"; then
        error "CONFIG_SOC_ZUMA lost; Exynos and AoC drivers would hit 'Unsupported platform!'"
        exit 1
    fi
    if grep -q '^CONFIG_UNUSED_KSYMS_WHITELIST=' "${BUILD_DIR}/.config"; then
        error "CONFIG_UNUSED_KSYMS_WHITELIST still set to a non-existent Google-internal path; gen_autoksyms.sh would fail silently"
        exit 1
    fi
    if grep -q '^CONFIG_TRIM_UNUSED_KSYMS=y' "${BUILD_DIR}/.config"; then
        error "CONFIG_TRIM_UNUSED_KSYMS re-enabled; autoksyms trimming would fail on the missing whitelist"
        exit 1
    fi
    if [[ "${ENABLE_KSU}" == "true" ]]; then
        if ! grep -q '^CONFIG_KSU=y' "${BUILD_DIR}/.config"; then
            error "CONFIG_KSU did not survive olddefconfig"
            exit 1
        fi
    fi

    success "Kernel configured"
}

# Build kernel
build_kernel() {
    log "Building kernel (${BUILD_TYPE})..."
    
    cd "${KERNEL_DIR}"
    
    # CLANG_TRIPLE must NOT be passed here: it makes the Makefile fall back to
    # GCC-style flag probing, which rejects clang-incompatible options under
    # -Werror. LLVM=1 already selects the full LLVM toolchain.
    make O="${BUILD_DIR}" -j"${JOBS}" \
        LLVM=1 \
        LLVM_IAS=1 \
        KCFLAGS="${KCFLAGS}" \
        Image dtbs modules
    
    if [[ ! -f "${KERNEL_IMAGE}" ]]; then
        error "Kernel image not found at ${KERNEL_IMAGE}"
        exit 1
    fi
    
    success "Kernel image built: ${KERNEL_IMAGE}"
}

# Build DTB
build_dtb() {
    if [[ "$BUILD_DTB" == true ]]; then
        log "Building DTB..."
        
        cd "${KERNEL_DIR}"
        make O="${BUILD_DIR}" -j"${JOBS}" dtbs
        
        if [[ ! -d "${DTB_DIR}" ]]; then
            error "DTB directory not found"
            exit 1
        fi
        
        success "DTBs built in ${DTB_DIR}"
    fi
}

# Build modules
#
# gki-stock_defconfig sets CONFIG_MODULES=y (unlike the old GCC zuma_defconfig,
# which set CONFIG_INTEGRATE_MODULES=y and folded every =m driver into the
# Image). The 45 zuma device driver Kconfigs layered in via KCONFIG_EXT_ZUMA
# therefore produce real .ko modules that must be built and shipped, otherwise
# the kernel has no WiFi/BT/charging drivers.
build_modules() {
    if [[ "$BUILD_MODULES" == true ]]; then
        log "Building loadable modules..."

        cd "${KERNEL_DIR}"

        if ! grep -q '^CONFIG_MODULES=y' "${BUILD_DIR}/.config"; then
            warn "CONFIG_MODULES is not set; no .ko modules will be produced."
            warn "If you expected loadable modules, check ${DEFCONFIG}."
            success "Modules skipped (CONFIG_MODULES=n)"
            return
        fi

        make O="${BUILD_DIR}" -j"${JOBS}" LLVM=1 LLVM_IAS=1 modules

        KO_COUNT=$(find "${BUILD_DIR}" -name '*.ko' | wc -l)
        if [[ "${KO_COUNT}" -eq 0 ]]; then
            error "No .ko modules were built; zuma device drivers (WiFi/BT/charging) would be missing"
            exit 1
        fi

        success "Built ${KO_COUNT} loadable modules"
    fi
}

# Create AnyKernel3 zip
create_flashable_zip() {
    if [[ "$CREATE_FLASHABLE" == true ]]; then
        log "Creating flashable AnyKernel3 zip..."
        
        # Clone AnyKernel3 if not exists
        if [[ ! -d "${ANYKERNEL_DIR}" ]]; then
            log "Cloning AnyKernel3..."
            git clone https://github.com/osm0sis/AnyKernel3.git "${ANYKERNEL_DIR}"
        fi
        
        # Clean AnyKernel3
        rm -f "${ANYKERNEL_DIR}"/Image
        rm -f "${ANYKERNEL_DIR}"/dtb
        rm -f "${ANYKERNEL_DIR}"/dtbo.img
        rm -rf "${ANYKERNEL_DIR}"/modules
        
        # Copy kernel image
        cp "${KERNEL_IMAGE}" "${ANYKERNEL_DIR}/Image"
        
        # Copy DTBs
        if [[ -d "${DTB_DIR}" ]]; then
            mkdir -p "${ANYKERNEL_DIR}/dtb"
            cp "${DTB_DIR}"/*.dtb "${ANYKERNEL_DIR}/dtb/" 2>/dev/null || true
            cp "${DTB_DIR}"/google/*.dtb "${ANYKERNEL_DIR}/dtb/" 2>/dev/null || true
        fi
        
        # Stage the =m modules into the boot ramdisk overlay so they land in
        # /lib/modules and load on boot. AK3 re-packs the whole ramdisk from
        # its ramdisk/ dir, so anything placed here is merged into the boot
        # image. The modules/ dir is only for KernelSU/Magisk helper modules,
        # NOT for .ko installation, and do.modules=1 additionally requires
        # do.systemless=1 -- so keep do.modules=0 and ship the .ko via ramdisk.
        MODREL="$(cat "${BUILD_DIR}/include/config/kernel.release" 2>/dev/null || echo unknown)"
        RDRAM="${ANYKERNEL_DIR}/ramdisk"
        MODDIR="${RDRAM}/lib/modules/${MODREL}"
        mkdir -p "${MODDIR}"
        find "${BUILD_DIR}" -name '*.ko' -print0 2>/dev/null \
            | xargs -0 -r -n50 llvm-strip --strip-debug 2>/dev/null || true
        find "${BUILD_DIR}" -name '*.ko' -exec cp {} "${MODDIR}/" \; 2>/dev/null || true
        KO_STAGED=$(find "${MODDIR}" -name '*.ko' 2>/dev/null | wc -l)
        if [[ "${KO_STAGED}" -eq 0 ]]; then
            error "No .ko modules staged into the ramdisk; kernel would lack WiFi/BT/charging"
            exit 1
        fi
        log "Staged ${KO_STAGED} .ko into ramdisk /lib/modules/${MODREL}"

        # Update anykernel.sh with our properties.
        #
        # BLOCK and IS_SLOT_DEVICE are mandatory: AK3 uses them to locate and
        # write the boot partition. The Pixel 8 is an A/B device (GKI v4 boot
        # images), hence IS_SLOT_DEVICE=1 and BLOCK=boot.
        cat > "${ANYKERNEL_DIR}/anykernel.sh" << 'EOF'
### AnyKernel setup
# global properties
properties() {
    kernel.string=Tensor G3 Kernel (zuma)
    do.devicecheck=1
    do.modules=0
    do.cleanup=1
    do.cleanuponabort=1
    device.name1=zuma
    device.name2=shusky
    device.name3=husky
    device.name4=akita
    device.name5=tokay
    supported.versions=-
}

### AnyKernel install
# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# Import functions
. tools/ak3-core.sh;

# Kernel install
dump_boot;
write_boot;
## end boot install
EOF
        
        # Create flashable zip
        cd "${ANYKERNEL_DIR}"
        zip -r9 "${DIST_DIR}/TensorG3-kernel-zuma-$(date +%Y%m%d).zip" . -x ".git*" -x "README.md" -x "*.zip"
        
        success "Flashable zip created: ${DIST_DIR}/KernelSU-Next-zuma-$(date +%Y%m%d).zip"
    fi
}

# Sign kernel (optional)
sign_kernel() {
    if [[ "$SIGN_BUILD" == true ]]; then
        log "Signing kernel image..."
        
        if [[ ! -f "${KERNEL_DIR}/keys/releasekey.pk8" ]] || [[ ! -f "${KERNEL_DIR}/keys/releasekey.x509.pem" ]]; then
            warn "Signing keys not found, skipping signing"
            return
        fi
        
        python3 "${KERNEL_DIR}/scripts/sign-file" sha256 \
            "${KERNEL_DIR}/keys/releasekey.x509.pem" \
            "${KERNEL_DIR}/keys/releasekey.pk8" \
            "${KERNEL_IMAGE}" \
            "${KERNEL_IMAGE}.signed"
        
        mv "${KERNEL_IMAGE}.signed" "${KERNEL_IMAGE}"
        success "Kernel image signed"
    fi
}

# Copy artifacts to dist
copy_artifacts() {
    log "Copying artifacts to dist directory..."
    
    cp "${KERNEL_IMAGE}" "${DIST_DIR}/Image"
    cp "${BUILD_DIR}/.config" "${DIST_DIR}/config"
    cp "${BUILD_DIR}/vmlinux" "${DIST_DIR}/vmlinux" 2>/dev/null || true
    cp "${BUILD_DIR}/System.map" "${DIST_DIR}/System.map" 2>/dev/null || true
    
    if [[ -d "${DTB_DIR}" ]]; then
        cp -r "${DTB_DIR}" "${DIST_DIR}/dtb"
    fi
    
    if [[ -d "${MODULES_DIR}" ]]; then
        cp -r "${MODULES_DIR}" "${DIST_DIR}/modules"
    fi
    
    # Create build info
    cat > "${DIST_DIR}/build-info.txt" << EOF
Kernel: Tensor G3 (zuma) KernelSU Next
Version: $(cd "${KERNEL_DIR}" && git describe --tags --always --dirty 2>/dev/null || echo "unknown")
Build Date: $(date -u)
Build Type: ${BUILD_TYPE}
Compiler: $(clang --version | head -1)
Architecture: arm64
Features:
  - KernelSU Next (root)
  - Bluetooth power saving excluded
  - WiFi power saving excluded
  - Restart retry (10 attempts)
  - Compatible with Google Stock ROMs
  - Compatible with AOSP/LineageOS
EOF
    
    success "Artifacts copied to ${DIST_DIR}"
}

# Main build flow
main() {
    log "Starting kernel build for Tensor G3 (zuma)"
    log "Build type: ${BUILD_TYPE}"
    log "Jobs: ${JOBS}"
    
    check_dependencies
    clean_build
    setup_environment
    configure_kernel
    build_kernel
    build_dtb
    build_modules
    sign_kernel
    create_flashable_zip
    copy_artifacts
    
    success "Build completed successfully!"
    log "Output directory: ${DIST_DIR}"
    ls -la "${DIST_DIR}"
}

main "$@"