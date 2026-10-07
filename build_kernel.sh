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
DEFCONFIG="zuma_defconfig"
KERNEL_IMAGE="${BUILD_DIR}/arch/arm64/boot/Image"
DTB_DIR="${BUILD_DIR}/arch/arm64/boot/dts/google"
MODULES_DIR="${BUILD_DIR}/modules"

# Build options
JOBS=$(nproc)
CLANG_VERSION="r547379"
LLVM=1

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
    
    # Set up cross-compile tools
    export ARCH=arm64
    export SUBARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-
    export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    export CLANG_TRIPLE=aarch64-linux-gnu-
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
    
    make O="${BUILD_DIR}" "${DEFCONFIG}"
    
    # Enable additional configs
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --enable KSU \
        --enable KPROBES \
        --enable EXT4_FS \
        --enable BLUETOOTH_POWERSAVE_EXCLUDE \
        --enable WIFI_POWERSAVE_EXCLUDE \
        --enable DEBUG_REBOOT \
        --set-str LOCALVERSION "-kernelsu-next"
    
    # Run make olddefconfig to resolve dependencies
    make O="${BUILD_DIR}" olddefconfig
    
    success "Kernel configured"
}

# Build kernel
build_kernel() {
    log "Building kernel (${BUILD_TYPE})..."
    
    cd "${KERNEL_DIR}"
    
    make O="${BUILD_DIR}" -j"${JOBS}" \
        LLVM=1 \
        LLVM_IAS=1 \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        KCFLAGS="${KCFLAGS}" \
        Image
    
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
build_modules() {
    if [[ "$BUILD_MODULES" == true ]]; then
        log "Building modules..."
        
        cd "${KERNEL_DIR}"
        make O="${BUILD_DIR}" -j"${JOBS}" modules
        
        # Install modules to staging directory
        make O="${BUILD_DIR}" INSTALL_MOD_PATH="${MODULES_DIR}" modules_install
        
        # Strip modules to reduce size
        find "${MODULES_DIR}" -name "*.ko" -exec ${CROSS_COMPILE}strip --strip-unneeded {} \; 2>/dev/null || true
        
        success "Modules built and installed to ${MODULES_DIR}"
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
        
        # Copy modules
        if [[ -d "${MODULES_DIR}" ]]; then
            mkdir -p "${ANYKERNEL_DIR}/modules"
            cp -r "${MODULES_DIR}/lib/modules"/* "${ANYKERNEL_DIR}/modules/" 2>/dev/null || true
        fi
        
        # Update anykernel.sh with our properties
        cat > "${ANYKERNEL_DIR}/anykernel.sh" << 'EOF'
# AnyKernel3 setup
properties() {
    kernel.string=Tensor G3 KernelSU Next by @yourusername
    do.devicecheck=1
    do.modules=1
    do.cleanup=1
    do.cleanuponabort=1
    device.name1=zuma
    device.name2=shusky
    device.name3=husky
    device.name4=akita
    device.name5=tokay
    supported.versions=14
    supported.patchlevels=
}

# Import functions
. tools/ak3-core.sh

# Kernel install
dump_boot
write_boot

# Install modules
if [ "$do.modules" == 1 ]; then
    for module in modules/*; do
        if [ -f "$module" ]; then
            ui_print "Installing $(basename $module)..."
            cp -f "$module" "$ramdisk/lib/modules/"
        fi
    done
fi
EOF
        
        # Create flashable zip
        cd "${ANYKERNEL_DIR}"
        zip -r9 "${DIST_DIR}/KernelSU-Next-zuma-$(date +%Y%m%d).zip" . -x ".git*" -x "README.md" -x "*.zip"
        
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