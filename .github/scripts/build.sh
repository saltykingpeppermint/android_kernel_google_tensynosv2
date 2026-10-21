#!/usr/bin/env bash
set -e
set -o pipefail

BUILD_DIR="/tmp/kernel_build"

# Resolve OUR repository root from this script's own location while the
# invocation cwd is still the original one. build.sh cds into BUILD_DIR
# early, and the kernel source is copied with `cp -r ${KERNEL_SRC_DIR}/*`
# which skips dotfiles -- so `.github/` (where the AArch64 AnyKernel3
# toolset lives) is unreachable from anywhere in the build tree.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Surface the real build failure as a GitHub annotation.
# The bare "Process completed with exit code 2" is uninformative;
# this extracts the actual failure lines from the build log so we
# don't have to iterate blind.
#
# Everything goes into ONE annotation on purpose. GitHub allows only
# ~10 error annotations per check, and an earlier version that emitted
# one annotation per matching line had all 10 slots eaten by harmless
# bpf_doc.py SyntaxWarnings, crowding the real error out entirely.
# A single packed annotation cannot be crowded out.
#
# Only HARD errors are matched (case-INSENSITIVE, because
# scripts/gen_autoksyms.sh prints "ERROR: '<path>' whitelist file not
# found" and a case-sensitive "error:" pattern produced zero
# annotations). Warnings are filtered out; if nothing hard matches we
# fall back to the raw tail so we are never blind again.
BUILD_LOG="/tmp/kernel_build.log"
# emit_failure must be SIGPIPE-proof and `set -e`-proof. Both rules
# were learned the hard way:
#   1. A reader that closes early (`head -n 15`) sends SIGPIPE to the
#      producer. With `set -o pipefail` that becomes exit 141 inside
#      the trap, and `set -e` then aborts the trap before it writes a
#      single annotation. Run #107 lost BOTH jobs to exactly this,
#      the moment `make -k` started producing hundreds of error lines
#      instead of a handful.
#   2. So every stage here writes into a FILE rather than into a pipe
#      some downstream command might abandon, and the 15-line cap is
#      applied by awk stopping itself instead of by head.
emit_failure() {
  rc="${1:-$?}"
  set +e
  set +o pipefail
  echo "::group::Build log tail (rc=${rc})"
  tail -n 300 "${BUILD_LOG}" 2>/dev/null
  echo "::endgroup::"
  # Dedupe by leading source file. Without this one broken file eats
  # the whole annotation budget: run #106 emitted 14 identical
  # mm/vmscan.c lines and said nothing about any other file.
  # Broadened after a run emitted only
  #   make[1]: *** [scripts/Makefile.vmlinux:34: vmlinux] Error 1
  # and nothing about why. The actual cause was link-vmlinux.sh saying
  # "pahole (pahole) is not available", which matched none of the
  # original patterns and was therefore invisible.
  grep -iE "error:|error [0-9]+|undefined reference|No rule to make target|Traceback|fatal|Killed|make.*\*\*\*|command not found|cannot (find|open|access)|is not available|too old|syntax error|invalid|No such file" \
       "${BUILD_LOG}" 2>/dev/null \
     | grep -viE "syntaxwarning|deprecat" > /tmp/kernel_build.raw
  awk -F: '!seen[$1]++ {print; if (++n == 15) exit}' \
      /tmp/kernel_build.raw > /tmp/kernel_build.hits
  if [ -s /tmp/kernel_build.hits ]; then
    hits="$(tr '\n' '|' < /tmp/kernel_build.hits)"
  else
    hits="(no hard-error pattern matched)"
  fi
  # The grep above is only ever as good as its pattern, and it just
  # proved it can miss the cause completely. The run log cannot be
  # downloaded unauthenticated, so this annotation is the ONLY channel
  # available -- append the raw tail unconditionally instead of hoping
  # the pattern happened to catch something actionable.
  tail -n 25 "${BUILD_LOG}" 2>/dev/null > /tmp/kernel_build.tail
  echo "::error::BUILD FAILED (rc=${rc}) :: ${hits} :: LOG_TAIL :: $(tr '\n' '|' < /tmp/kernel_build.tail)"
  exit "${rc}"
}
on_err() { emit_failure "$?"; }
trap on_err ERR

echo "=== Setting up isolated in-tree build ==="
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Copy kernel source into isolated dir (this IS our build tree, in-tree)
cp -r "${KERNEL_SRC_DIR}"/* "${BUILD_DIR}/"
cp -r "${KERNEL_SRC_DIR}/kernelsu-next" "${BUILD_DIR}/kernelsu-next" 2>/dev/null || true

cd "${BUILD_DIR}"

# Clean any build artifacts
rm -rf out .config .config.old include/config include/generated
rm -rf arch/arm64/include/generated
rm -f Module.symvers modules.builtin modules.order

# Apply KernelSU Next Kconfig source into main Kconfig.
# Skipped when KernelSU is disabled -- see ENABLE_KSU above.
if [ "${ENABLE_KSU}" = "true" ]; then
  if ! grep -q "kernelsu-next/kernel/Kconfig" Kconfig; then
    if grep -q 'source "security/Kconfig"' Kconfig; then
      sed -i '/source "security\/Kconfig"/a source "kernelsu-next\/kernel\/Kconfig"' Kconfig
    elif grep -q 'source "crypto/Kconfig"' Kconfig; then
      sed -i '/source "crypto\/Kconfig"/i source "kernelsu-next\/kernel\/Kconfig"' Kconfig
    elif grep -q 'source "lib/Kconfig"' Kconfig; then
      sed -i '/source "lib\/Kconfig"/i source "kernelsu-next\/kernel\/Kconfig"' Kconfig
    else
      echo 'source "kernelsu-next/kernel/Kconfig"' >> Kconfig
    fi
  fi
fi

# Apply power save exclusion Kconfig options
if ! grep -q "BLUETOOTH_POWERSAVE_EXCLUDE" google-devices/zuma/Kconfig.ext.zuma; then
  printf '\nconfig BLUETOOTH_POWERSAVE_EXCLUDE\n  bool "Exclude Bluetooth from power saving"\n  default y\n\nconfig WIFI_POWERSAVE_EXCLUDE\n  bool "Exclude WiFi from power saving"\n  default y\n' >> google-devices/zuma/Kconfig.ext.zuma
fi

# Copy modified source files from our repo
cp "${OUR_REPO_DIR}/google-modules/bluetooth/broadcom/nitrous.c" \
   google-modules/bluetooth/broadcom/nitrous.c
cp "${OUR_REPO_DIR}/google-modules/wlan/bcm4389/Kbuild" \
   google-modules/wlan/bcm4389/Kbuild
cp "${OUR_REPO_DIR}/google-modules/power/reset/pixel-zuma-reboot.c" \
   google-modules/power/reset/pixel-zuma-reboot.c
# Restart-retry logic lives in kernel/reboot.c's kernel_restart();
# overlay our patched copy over the freshly-cloned upstream source.
mkdir -p kernel
cp "${OUR_REPO_DIR}/kernel/reboot.c" kernel/reboot.c

# Drop orphaned vendor-hook exports.
#
# Upstream 16.0.0-sultan has a latent one-line bug: kernel/sched/
# vendor_hooks.c exports 109 tracepoints while include/trace/hooks/
# sched.h only declares 108. The extra one,
# android_rvh_effective_cpu_util, is never declared, so
# EXPORT_TRACEPOINT_SYMBOL_GPL() expands into references to the
# nonexistent __tracepoint_/__traceiter_ symbols and clang fails
# with "use of undeclared identifier".
#
# It survives upstream because their config keeps
# CONFIG_TRIM_UNUSED_KSYMS=y, under which the export macro emits only
# a __ksymtab_strings entry and never references the symbol at
# compile time. We turn trimming off (the whitelist it needs is a
# Google-internal Bazel path that does not exist here), which
# exposes the bug.
#
# Nothing calls this tracepoint anywhere in the tree -- fair.c only
# uses an unrelated function also named effective_cpu_util() -- so
# dropping the dead export is safe. Do it generically so it keeps
# working if upstream adds or removes more hooks.
if [ -d include/trace/hooks ]; then
  grep -rhoE 'DECLARE_(RESTRICTED_)?HOOK\(\s*[a-z0-9_]+' include/trace/hooks/ 2>/dev/null \
    | grep -oE '[a-z0-9_]+$' | sort -u > /tmp/hook_declared.txt
  grep -oE 'EXPORT_TRACEPOINT_SYMBOL_GPL\(\s*android_r?vh_[a-z0-9_]+' kernel/sched/vendor_hooks.c 2>/dev/null \
    | grep -oE 'android_r?vh_[a-z0-9_]+$' | sort -u > /tmp/hook_exported.txt
  comm -13 /tmp/hook_declared.txt /tmp/hook_exported.txt > /tmp/hook_orphans.txt
  if [ -s /tmp/hook_orphans.txt ]; then
    echo "=== Removing orphaned vendor-hook exports ==="
    cat /tmp/hook_orphans.txt
    while IFS= read -r orphan; do
      [ -z "${orphan}" ] && continue
      sed -i "s|EXPORT_TRACEPOINT_SYMBOL_GPL(${orphan});|/* orphan export removed: ${orphan} is never declared */|" \
           kernel/sched/vendor_hooks.c
    done < /tmp/hook_orphans.txt
  else
    echo "=== No orphaned vendor-hook exports found ==="
  fi
fi

# Restore the missing shrinker_rwsem declaration.
#
# mm/vmscan.c calls down_write()/up_write()/up_read()/
# down_read_trylock()/rwsem_is_contended() on &shrinker_rwsem in 14
# places, every one of them guarded by CONFIG_MEMCG -- but nothing in
# the tree declares that symbol. include/linux/shrinker.h has no
# mention of it, and there is no DECLARE_RWSEM(shrinker_rwsem)
# anywhere, so mm/vmscan.o fails with "use of undeclared identifier
# 'shrinker_rwsem'" for any config with MEMCG=y, which every Pixel
# config has. Another lossy merge in 16.0.0-sultan.
#
# Config cannot work around this: CONFIG_SHRINKER_DEBUG, the only
# other candidate, is declared in lib/Kconfig.debug as
# `depends on NEVER`, so it is permanently unselectable.
#
# Mainline keeps this as a file-scope static beside its sibling
# shrinker locks, so restore exactly that. Every reference is inside
# mm/vmscan.c, so static is correct.
if grep -q 'DEFINE_RWLOCK(shrinker_rwlock)' mm/vmscan.c \
   && ! grep -q 'DECLARE_RWSEM(shrinker_rwsem)' mm/vmscan.c; then
  echo "=== Restoring missing DECLARE_RWSEM(shrinker_rwsem) in mm/vmscan.c ==="
  awk '{print} /^static DEFINE_RWLOCK\(shrinker_rwlock\);$/ {print "#ifdef CONFIG_MEMCG"; print "static DECLARE_RWSEM(shrinker_rwsem);"; print "#endif"}' \
       mm/vmscan.c > mm/vmscan.c.tmp && mv mm/vmscan.c.tmp mm/vmscan.c
fi
if ! grep -q 'DECLARE_RWSEM(shrinker_rwsem)' mm/vmscan.c; then
  echo "::error::mm/vmscan.c is missing DECLARE_RWSEM(shrinker_rwsem); vmscan.o cannot compile with MEMCG=y"
  exit 1
fi
grep -n -B2 -A4 'DECLARE_RWSEM(shrinker_rwsem)' mm/vmscan.c

# Always build the EdgeTPU telemetry and tracepoint objects.
#
# google-modules/edgetpu/rio/drivers/edgetpu/Kbuild has:
#
#   ifdef CONFIG_EDGETPU_TELEMETRY_TRACE
#   edgetpu-objs	+= edgetpu-telemetry.o edgetpu-trace.o
#   endif
#
# and then `rio-objs := rio-core.o ... $(edgetpu-objs)`. Every rio-*.c
# calls the edgetpu tracepoints unconditionally, but the ONLY
# translation unit that defines them is gated here: edgetpu-trace.c is
# nothing but `#define CREATE_TRACE_POINTS` plus the trace header.
#
# CONFIG_EDGETPU_TELEMETRY_TRACE is defined by no Kconfig anywhere in
# this tree, so auto.conf can never carry it and that ifdef can never
# open. The result is a driver that cannot link no matter what config
# is chosen:
#
#   ld.lld: error: undefined symbol: __traceiter_edgetpu_client_create
#   >>> referenced by edgetpu.h:372 (.../trace/events/edgetpu.h:372)
#   >>>   google-modules/edgetpu/rio/drivers/edgetpu/rio.o
#   ld.lld: error: too many errors emitted, stopping now
#
# Same shape as the orphaned vendor-hook exports fixed above: a lossy
# merge that kept the call sites and lost the definitions.
#
# Drop the gate rather than disable the driver, which would cost the
# Tensor TPU.
#
# IMPORTANT: only edgetpu-trace.o is un-gated. A previous attempt also
# un-gated edgetpu-telemetry.o and immediately produced:
#
#   edgetpu-telemetry.c:46:5: error: redefinition of
#       'edgetpu_telemetry_init'
#
# for the same reason this whole patch exists. edgetpu-telemetry.h
# chooses between real prototypes and static inline stubs with
# `#if IS_ENABLED(CONFIG_EDGETPU_TELEMETRY_TRACE)` ... `#else` ..., and
# that symbol is defined by no Kconfig anywhere, so the stubs are
# ALWAYS active. The .c file then defines the same functions a second
# time. Leaving it out costs nothing: the header already supplies
# working no-op stubs, so rio-*.c need neither the object nor the
# config.
ET_KB="google-modules/edgetpu/rio/drivers/edgetpu/Kbuild"
if [ -f "${ET_KB}" ] && grep -q 'CONFIG_EDGETPU_TELEMETRY_TRACE' "${ET_KB}"; then
  echo "=== Un-gating edgetpu-trace.o from CONFIG_EDGETPU_TELEMETRY_TRACE ==="
  # NB: Ubuntu's awk is mawk, which does not support the \s shorthand,
  # so these patterns spell the character classes out.
  awk '
    /^[ \t]*ifdef[ \t]+CONFIG_EDGETPU_TELEMETRY_TRACE[ \t]*$/ {
      print "edgetpu-objs += edgetpu-trace.o"
      print "# CI patch: CONFIG_EDGETPU_TELEMETRY_TRACE is defined by no Kconfig in"
      print "# this tree, so this gate could never open and rio-*.c were left calling"
      print "# tracepoints nobody defined (__traceiter_edgetpu_* undefined at link)."
      print "# Only edgetpu-trace.o is un-gated; edgetpu-telemetry.o must stay out"
      print "# because edgetpu-telemetry.h guards on the same impossible symbol and"
      print "# therefore always supplies static inline stubs, which the .c file then"
      print "# redefines. See .github/scripts/build.sh."
      gate = 1; next
    }
    gate == 1 && /^[ \t]*edgetpu-objs[ \t]*\+=[ \t]*edgetpu-telemetry\.o/ { next }
    gate == 1 && /^[ \t]*endif[ \t]*$/ { gate = 0; next }
    { print }
  ' "${ET_KB}" > "${ET_KB}.tmp" && mv "${ET_KB}.tmp" "${ET_KB}"
fi
if [ -f "${ET_KB}" ] && grep -q 'ifdef[[:space:]]*CONFIG_EDGETPU_TELEMETRY_TRACE' "${ET_KB}"; then
  echo "::error::could not un-gate edgetpu-trace.o; rio would fail to link with undefined __traceiter_edgetpu_*"
  exit 1
fi
grep -n -B1 -A2 'edgetpu-trace\.o' "${ET_KB}" 2>/dev/null || true

# Apply build configs
if [ "${ENABLE_KSU}" = "true" ]; then
  if ! grep -q "CONFIG_KSU=y" build.config.common; then
    printf '\nCONFIG_KSU=y\nCONFIG_KPROBES=y\nCONFIG_EXT4_FS=y\n' >> build.config.common
  fi
fi
if ! grep -q "CONFIG_BLUETOOTH_POWERSAVE_EXCLUDE=y" build.config.common; then
  printf '\nCONFIG_BLUETOOTH_POWERSAVE_EXCLUDE=y\nCONFIG_WIFI_POWERSAVE_EXCLUDE=y\n' >> build.config.common
fi

# Setup environment. O= (empty) overrides KBUILD_OUTPUT?=out -> in-tree build.
#
# Toolchain MUST be pure LLVM here. Setting CROSS_COMPILE alongside
# LLVM=1 makes this kernel's Makefile probe flags with GCC
# semantics, so cc-option accepts GCC-only options (-fipa-pta,
# -fwhole-program, -fuse-linker-plugin, -fno-fat-lto-objects) and
# hands them to clang, which rejects them; -Werror then turns those
# into hard errors during prepare0/missing-syscalls. With a pure
# LLVM toolchain the Makefile's cc-option probes use clang's real
# supported set, so only valid flags survive. LLVM=1 already implies
# CC=clang, LD=ld.lld, AR=llvm-ar, NM=llvm-nm, OBJCOPY=llvm-objcopy,
# OBJDUMP=llvm-objdump, READELF=llvm-readelf, STRIP=llvm-strip.
export ARCH=arm64
export SUBARCH=arm64
unset CROSS_COMPILE
unset CROSS_COMPILE_ARM32
unset CLANG_TRIPLE
export LLVM=1
export LLVM_IAS=1
export KCONFIG_NOTIMESTAMP=1
export KBUILD_OUTPUT=

echo "=== Generating .config (in-tree) ==="

# `may-sync-config=` passed on the command line OVERRIDES the
# Makefile's own `may-sync-config := 1` (lines 330/347/352 are plain
# `:=`, not `override`), so `ifdef may-sync-config` (line 828) is
# false. That deletes BOTH the `include include/config/auto.conf.cmd`
# (line 832) and the multi-target SYNC pattern rule (line 853) -- the
# only rule that re-invokes `$(MAKE) syncconfig` and can recurse
# forever. Config goals are unaffected: they take the
# `ifdef config-build` branch (line 717) which never reaches 832/853.
# Use the CLANG defconfig, not zuma_defconfig.
#
# zuma_defconfig is the GCC config: it sets CONFIG_LTO_GCC=y, and
# Makefile:783-793 then hardcodes GCC-only flags into KBUILD_CFLAGS
# (-fipa-pta -fno-fat-lto-objects -fuse-linker-plugin
# -fwhole-program) and reassigns AR/NM to gcc-ar/gcc-nm. Building it
# with clang/LLVM dies in prepare0/missing-syscalls because clang
# rejects those flags and -Werror promotes the rejections to errors.
#
# gki-stock_defconfig is the matching CLANG config
# (CONFIG_CC_IS_CLANG=y, CONFIG_LTO_NONE=y, CONFIG_CFI_CLANG=y) and
# is what this tree actually builds with LLVM=1. It also sets
# CONFIG_MODULES=y with NO CONFIG_INTEGRATE_MODULES, so KPROBES is
# satisfiable (arch/Kconfig:52-54 `KPROBES depends on MODULES`) and
# KernelSU is buildable here.
make O= may-sync-config= gki-stock_defconfig

# Layer the Tensor G3 device fragment on top of the GKI base, the same
# way Google's own build assembles it. gki-stock_defconfig is the
# generic clang/GKI base; arch/arm64/configs/zuma_defconfig is this
# device's fragment (849 options, CONFIG_LOCALVERSION="-Sultan").
#
# The fragment has to be MERGED, never used on its own: it defines no
# base options at all -- no CONFIG_SMP, MMU, MODULES, NET or BLOCK --
# so `make zuma_defconfig` alone would produce a kernel with almost
# everything disabled and it would not boot.
#
# Hand-patching the GKI base is what kept burning CI cycles. Run #108
# needed CONFIG_SOC_ZUMA added by hand to clear the aoc #error. Run #110
# then failed across lwis, mali GPU DVFS, BCL and modem_notifier,
# because a generic base has no Tensor device options: it selects LWIS
# platform `casablanca`, whose headers (lwis_commands.h, lwis_trace.h)
# do not exist for zuma, and it leaves CONFIG_PM_QOS and the S2MPG14
# PMIC options off, leaving exynos_pm_qos_* and
# S2MPG14_PM_SMPL_WARN_CTRL undeclared. Merging the fragment supplies
# every one of those at once instead of one per CI cycle.
./scripts/kconfig/merge_config.sh -m .config arch/arm64/configs/zuma_defconfig

# The root Kconfig gates google-devices/zuma/Kconfig.ext.zuma (45
# Google/Exynos driver Kconfigs: zram, clk, cpufreq, power, pinctrl,
# ...) behind the KCONFIG_EXT_ZUMA choice symbol, which defaults to
# KCONFIG_EXT_NONE. Without this the build would be generic GKI with
# no WiFi/BT/charging/display drivers and would not boot on a Pixel 8.
# The merged fragment already sets it; enable it here anyway so this
# guard stays meaningful if the fragment ever stops carrying it.
./scripts/config --file .config --enable KCONFIG_EXT_ZUMA

# zuma_defconfig sets CONFIG_LTO_GCC=y because it was authored for a
# GCC toolchain. The Makefile's LTO_GCC branch emits GCC-only flags
# (-fipa-pta -fno-fat-lto-objects -fuse-linker-plugin -fwhole-program)
# and reassigns AR/NM to gcc-ar/gcc-nm; clang rejects those and -Werror
# promotes it to a hard failure in prepare0. We build with LLVM=1, so
# drop it. The LTO choice then falls back to LTO_NONE, the same value
# gki-stock_defconfig and Google's own clang build use.
./scripts/config --file .config --disable LTO_GCC

# Gunyah is Qualcomm's type-1 hypervisor. It arrives via the generic GKI
# base (gki-stock_defconfig sets CONFIG_GUNYAH=y) and zuma_defconfig
# never mentions it, so it is not part of what this device actually
# builds. With INTEGRATE_MODULES=y forcing MODULES=n it becomes a hard
# failure rather than dead weight: drivers/virt/gunyah/vm_mgr.c:182
# calls module_refcount(), which is only declared under CONFIG_MODULES,
# and clang 17 promotes the implicit declaration to an error.
./scripts/config --file .config --disable GUNYAH

# vclk.h chooses between real prototypes and static inline stubs with
# `#if IS_ENABLED(CONFIG_CMUCAL_DEBUG)`, but cmucal-debug.c guards its
# definitions with CONFIG_DEBUG_FS instead. With DEBUG_FS=y and
# CMUCAL_DEBUG unset both halves are active at once: the header emits a
# `static inline vclk_debug_clk_get_rate` and the .c file then defines a
# global with the same signature, which is a redefinition error. Turning
# CMUCAL_DEBUG on makes vclk.h switch to the extern declarations so the
# two agree.
./scripts/config --file .config --enable CMUCAL_DEBUG

# Two zram implementations, and this is a consequence of the base config
# choice rather than a bug in the tree. The merge brought them together:
#
#   gki-stock_defconfig:  CONFIG_ZRAM=m     (generic upstream zram)
#   zuma_defconfig:       CONFIG_ZRAM_GS=m  (Google's Pixel zram)
#
# The device fragment is SILENT on the generic ZRAM -- it has its own --
# so merge_config.sh has nothing to overwrite and gki-stock's setting
# survives. Both then build their own zcomp.c, and both define a global
# `zcomp_available_algorithm`, which the link stage rejects as a
# duplicate symbol. Note this is the first error in several runs that
# occurs after every .c file has compiled, so the source tree is now
# compiling end to end.
#
# Google's is the right one: zuma_defconfig asks for it explicitly, and
# it adds zcomp_cpu.c (multi-CPU compression) and zcomp_eh.c (the
# Emerald Hill hardware compressor) that the generic driver does not
# have. Drop the generic. CONFIG_ZSMALLOC stays on because it is the
# shared backing allocator both implementations use, not a competitor.
./scripts/config --file .config --disable ZRAM

# BTF generation is what stopped the build at the FINAL link step,
# after every source file had already compiled. gki-stock_defconfig
# sets CONFIG_DEBUG_INFO_BTF=y, and scripts/link-vmlinux.sh's gen_btf()
# then requires pahole:
#
#   if ! [ -x "$(command -v ${PAHOLE})" ]; then
#       echo >&2 "BTF: ${1}: pahole (${PAHOLE}) is not available"
#
# The workflow installs bc, bison, flex, lld and friends but not
# `dwarves`, which is the package that provides pahole -- and that
# message matches no error pattern, which is why the diagnostic
# annotation showed only `make[1]: *** [scripts/Makefile.vmlinux:34:
# vmlinux] Error 1` with no explanation attached.
#
# Rather than add the dependency, drop BTF. It is not needed to boot,
# and there are two further risks in keeping it on this particular
# build: every BTF record is derived from full DWARF debug info on an
# unusually large all-built-in kernel, and BTF has hard size ceilings
# that large kernels are known to hit. Skipping it removes a
# dependency, a slow post-link pass and a size limit all at once. The
# only thing lost is eBPF CO-RE type information.
./scripts/config --file .config --disable DEBUG_INFO_BTF --disable DEBUG_INFO_BTF_MODULES

# gki-stock_defconfig is a generic GKI snapshot and carries no
# Tensor/Exynos SoC identity at all. Layering the device drivers in
# via KCONFIG_EXT_ZUMA is not sufficient on its own, because once
# built they have to know WHICH SoC they target. Without it:
#
#   google-modules/soc/gs/include/soc/google/exynos-pmu-if.h:39
#       #error "Unknown CONFIG_SOC"
#   google-modules/aoc/aoc-interface.h:19
#       #error "Unsupported platform!"
#
# aoc-interface.h dispatches to aoc-interface-zuma.h / -gs201.h /
# -gs101.h purely on CONFIG_SOC_*. Falling through to the #error
# leaves every AoC translation unit compiling with no platform header
# at all, which is exactly the cascade run #108 reported: incomplete
# struct CMD_SYS_VERSION_GET, undeclared AUDIO_OUTPUT_SINKS, and
# -Wshift-count-overflow on shifts computed from an empty type. One
# missing symbol, not a dozen separate bugs.
#
# zuma_defconfig sets both at lines 747-748.
./scripts/config --file .config --enable SOC_GOOGLE --enable SOC_ZUMA

# gki-stock_defconfig ships two settings that only make sense on
# Google's internal Bazel build machines:
#   CONFIG_TRIM_UNUSED_KSYMS=y
#   CONFIG_UNUSED_KSYMS_WHITELIST="/mnt/disks/build-disk/src/android/
#       common-android14-6.1-2024-04/out/bazel/.../abi_symbollist.raw"
# The whitelist is an absolute Google-internal path that does not
# exist on a GitHub runner, so scripts/gen_autoksyms.sh:35 fails and
# prints "ERROR: '<path>' whitelist file not found" before exiting 1
# -- killing the build at Makefile:1330 (include/generated/
# autoksyms.h) with no compiler output at all.
#
# Turn the whole autoksyms trimming machinery off instead of trying
# to satisfy it: TRIM_UNUSED_KSYMS only prunes unused EXPORT_SYMBOL
# entries for Google's KMI restriction, and keeping a superset of
# exported symbols is always safe (it can never cause an unresolved
# symbol). Also drop the bogus whitelist so nothing can re-read it.
./scripts/config --file .config \
  --disable TRIM_UNUSED_KSYMS \
  --undefine UNUSED_KSYMS_WHITELIST

./scripts/config --file .config \
  --enable BLUETOOTH_POWERSAVE_EXCLUDE --enable WIFI_POWERSAVE_EXCLUDE \
  --enable DEBUG_REBOOT
# zuma_defconfig carries CONFIG_LOCALVERSION="-Sultan". Only replace it
# when KernelSU is really being built, otherwise a KSU-less kernel
# reports `uname -r` as -kernelsu-next, which sends anyone debugging a
# flashed device after the wrong thing.
if [ "${ENABLE_KSU}" = "true" ]; then
  ./scripts/config --file .config --set-str LOCALVERSION "-kernelsu-next"
fi
if [ "${ENABLE_KSU}" = "true" ]; then
  ./scripts/config --file .config --enable KSU --enable KPROBES --enable EXT4_FS
fi

# Finalize config (resolves all deps and defaults).
make O= may-sync-config= olddefconfig

# Sanity: our own options must have survived dependency resolution.
if ! grep -q '^CONFIG_KCONFIG_EXT_ZUMA=y' .config; then
  echo "::error::CONFIG_KCONFIG_EXT_ZUMA lost; zuma device drivers would NOT be built"
  exit 1
fi
# Fires at config time rather than minutes into the build, which is
# how run #108 cost a full cycle: the SoC symbol was simply absent
# and the failure only surfaced as a wall of downstream AoC errors.
if ! grep -q '^CONFIG_SOC_ZUMA=y' .config; then
  echo "::error::CONFIG_SOC_ZUMA lost; Exynos and AoC drivers would hit 'Unsupported platform!'"
  exit 1
fi
# Verify the device fragment actually merged. Without it the build is a
# generic GKI kernel carrying none of the Tensor device options, which
# is precisely what produced run #110's LWIS / Mali GPU / BCL /
# modem_notifier failures. INTEGRATE_MODULES is set only by
# zuma_defconfig and is the option that most changes how the build
# behaves -- it forces MODULES=n -- so it makes a good canary.
if ! grep -q '^CONFIG_INTEGRATE_MODULES=y' .config; then
  echo "::error::arch/arm64/configs/zuma_defconfig did not merge into .config; drivers would build with the wrong platform options"
  exit 1
fi
# A duplicate-symbol failure only appears at the link stage, after every
# .c file in the tree has compiled -- roughly a 30-minute cycle to
# discover for a one-line config problem. Catch it here instead.
# Deliberately anchored so CONFIG_ZRAM_GS is not matched.
if grep -q '^CONFIG_ZRAM=' .config; then
  echo "::error::CONFIG_ZRAM re-enabled alongside CONFIG_ZRAM_GS; both define zcomp_available_algorithm and the link will fail"
  exit 1
fi
# Guard against the silent autoksyms killer: this check fires at
# config time instead of 2 minutes into the build with no message.
if grep -q '^CONFIG_UNUSED_KSYMS_WHITELIST=' .config; then
  echo "::error::CONFIG_UNUSED_KSYMS_WHITELIST still set to a non-existent Google-internal path; gen_autoksyms.sh would fail silently"
  exit 1
fi
if grep -q '^CONFIG_TRIM_UNUSED_KSYMS=y' .config; then
  echo "::error::CONFIG_TRIM_UNUSED_KSYMS re-enabled; autoksyms trimming would fail on the missing whitelist"
  exit 1
fi
if [ "${ENABLE_KSU}" = "true" ]; then
  if ! grep -q '^CONFIG_KSU=y' .config; then
    echo "::error::CONFIG_KSU did not survive olddefconfig"
    exit 1
  fi
fi
echo "=== =m symbols (modules; informational) ==="
grep -c '=m$' .config || true

# Generate auto.conf / auto.conf.cmd / autoconf.h. This MUST go
# through make rather than invoking `conf` directly: Kconfig.include
# runs `$(srctree)/scripts/cc-version.sh`, and `srctree` is only in
# the environment because the Makefile exports it (line 300).
# `syncconfig` maps 1:1 onto `conf --syncconfig` via simple-targets.
mkdir -p include/config include/generated
make O= may-sync-config= syncconfig

# Fail fast with an actionable message if any config header is absent.
for f in .config include/config/auto.conf include/config/auto.conf.cmd \
         include/generated/autoconf.h; do
  if [ ! -s "$f" ]; then
    echo "::error::Missing or empty $f after syncconfig"
    exit 1
  fi
done

# Belt and suspenders: keep .config older than the generated files so
# nothing can consider them out of date. The build reads configuration
# from auto.conf/autoconf.h contents, never from .config's mtime.
touch -d "2000-01-01 00:00:00 UTC" .config

ls -la .config include/config/ include/generated/autoconf.h

echo "=== Building kernel (in-tree) ==="

# The zuma_defconfig fragment sets CONFIG_INTEGRATE_MODULES=y, which
# forces MODULES=n (kernel/module/Kconfig). Every device driver that
# layers in through KCONFIG_EXT_ZUMA is therefore compiled straight
# into the Image instead of being emitted as a .ko. That is the more
# robust outcome for a flashable zip: there is nothing left to load at
# boot and no module install path that can be got wrong. It does mean
# `make modules` has no rule to make, so Image/dtbs is the whole
# build. The staging block below stays conditional on CONFIG_MODULES
# so this script still works if the fragment is ever changed to
# ship modules again.
# MAKE_KEEP_GOING was "-k" for the whole debug phase. 16.0.0-sultan
# turned out to be a lossy merge carrying several independent source
# bugs (an undeclared tracepoint export, a missing DECLARE_RWSEM, a
# config-gated file that could never be gated open), and stopping at the
# first failure cost one 10-30 minute CI cycle per bug, so letting make
# carry on surfaced every broken translation unit in a single run.
#
# The tree has compiled clean since run #117, so this is back to "".
# -k would not have hidden a genuine breakage -- any failed prerequisite
# leaves vmlinux and thus Image unbuildable, so the AK3 step would have
# failed anyway -- but it costs the fail-fast behaviour and only earns
# its keep while there are many bugs per run to collect.
MAKE_KEEP_GOING=""
# Capture both pipeline statuses explicitly instead of leaning on
# pipefail: a signal death in the pipeline (run #107 exited 141,
# SIGPIPE) skipped the ERR trap and reported nothing at all, which
# cost a full CI cycle to discover. Reporting unconditionally means
# we always learn whether make, tee, or the pipeline died.
set +e
set +o pipefail
# Passing KCFLAGS on the command line overrides every assignment to it in
# the Makefile, so this string must carry anything the tree relied on
# setting itself. Exactly one such flag exists, and losing it cost a
# whole CI cycle:
#
#   Makefile:10: KCFLAGS += -D__ANDROID_COMMON_KERNEL__
#
# Run #111's two Mali errors looked unrelated and neither mentioned the
# macro, but both are its absence:
#   - version_compat_defs.h:230 redefinition of vm_flags_set. The guard
#     is `!((6.3 <= V) || ((6.1.25 <= V) && __ANDROID_COMMON_KERNEL__))`.
#     This kernel is 6.1.145 so the version half alone should have
#     suppressed the block -- it did not, because the macro was missing.
#   - mali_kbase_mmap.c:350 undeclared tmp_info. Line 350 sits in the
#     #else half of `#ifdef __ANDROID_COMMON_KERNEL__` and uses a
#     variable only declared in the #if half.
# Re-declaring the macro fixes both.
#
# Include path: google-modules/lwis/Kbuild adds
#   ccflags-y += -I$(abspath $(KERNEL_SRC)/$(M))
# and $(M) -- the module source directory -- is only set when the object
# is a loadable module. LWIS is declared as `bool` in its Kconfig, so it
# is always built-in, $(M) comes out empty, and the -I resolves to the
# top of the tree. Both LWIS failures (lwis_trace.h and lwis_commands.h
# not found) are that single broken path: all 37 LWIS headers live in
# google-modules/lwis/, which nothing else puts on the include path for a
# built-in object. Note this is NOT a wrong-platform problem -- the Kbuild
# maps CONFIG_SOC_ZUMA=y to platform/casablanca/, so casablanca really is
# this device's LWIS platform.
#
# Warnings promoted to errors: a 6.1 tree compiled with a newer clang
# than it was written for. Relax exactly the classes seen so far rather
# than blanket-disabling -Werror, which would let genuinely broken code
# end up flashed onto a phone. The frame limit is raised to 8192 rather
# than dropped: arm64 stacks are 16 KiB so 2096 bytes was never at risk
# and the guard is worth keeping at a sane bound.
KCFLAGS="-D__ANDROID_COMMON_KERNEL__ -Wno-error=format-security -Wno-error=unused-but-set-variable -Wno-error=unused-const-variable -Wno-error=parentheses-equality -Wno-error=division-by-zero -Wframe-larger-than=8192 -I${BUILD_DIR}/google-modules/lwis"
make O= may-sync-config= -j"$(nproc)" ${MAKE_KEEP_GOING} \
  LLVM=1 LLVM_IAS=1 KCFLAGS="${KCFLAGS}" \
  Image dtbs 2>&1 | tee "${BUILD_LOG}"
MAKE_RC=${PIPESTATUS[0]}
TEE_RC=${PIPESTATUS[1]}
set -e
set -o pipefail
echo "=== make rc=${MAKE_RC} tee rc=${TEE_RC} ==="
if [ "${MAKE_RC}" -ne 0 ] || [ "${TEE_RC}" -ne 0 ]; then
  emit_failure "${MAKE_RC}"
fi

echo "=== Build outputs ==="
ls -la arch/arm64/boot/Image

# Locate the built device trees. The path is deliberately NOT hardcoded:
# this tree keeps its DTS sources outside arch/arm64/boot/dts, so the
# previous `cp arch/arm64/boot/dts/google/*.dtb ... || true` matched
# nothing on every single build and its failure was swallowed by the
# trailing `|| true` -- which is how a zip shipped with an empty dtb/
# directory and no device tree in it at all. Fail loudly from here on:
# a kernel flashed with a missing DTB does not come up, and a silent
# skip is indistinguishable from a working build in the CI log.
#
# find | sort (not a glob) so the list is deterministic across runners,
# which matters because these blobs are concatenated in this order.
DTB_LIST="$(find . -name '*.dtb' -not -path './.git/*' -not -path './out/*' | LC_ALL=C sort)"
DTBCOUNT="$(printf '%s\n' "${DTB_LIST}" | sed '/^$/d' | wc -l)"
if [ "${DTBCOUNT}" -eq 0 ]; then
  echo "::error::make dtbs produced no .dtb anywhere under $(pwd)"
  find . \( -name '*.dtb*' -o -name '*.dtbo' \) -not -path './.git/*' | head -n 25
  exit 1
fi
echo "=== Found ${DTBCOUNT} .dtb ==="
printf '%s\n' "${DTB_LIST}"

# Copy artifacts. Unquoted expansion of DTB_LIST is intentional: these
# are kernel build paths, which contain no whitespace.
mkdir -p "${DIST_DIR}"
cp arch/arm64/boot/Image "${DIST_DIR}/Image-${BUILD_TYPE}"
cp .config "${DIST_DIR}/config-${BUILD_TYPE}"
cp vmlinux "${DIST_DIR}/vmlinux-${BUILD_TYPE}" 2>/dev/null || true
mkdir -p "${DIST_DIR}/dtb"
cp ${DTB_LIST} "${DIST_DIR}/dtb/"

echo "=== Creating AnyKernel3 flashable zip ==="
AK3_DIR="/tmp/anykernel3"
rm -rf "${AK3_DIR}"
# Pin AnyKernel3 to the same era as the reference build that is known to
# flash on this device -- its updater-script declares AK_BASE_VERSION=
# 20231020. Tracking HEAD instead shipped a newer core that restructured
# ramdisk handling and added hard aborts around vendor ramdisk unpacking,
# and on this platform the DTB lives in vendor_kernel_boot, so that new
# code sits directly on the flash route. For scale: the reference
# ak3-core.sh is 33634 bytes against HEAD's 35350, and they differ by
# 1037 diff lines, the bulk of it newly added abort conditions.
git clone https://github.com/osm0sis/AnyKernel3.git "${AK3_DIR}"
AK3_COMMIT="$(git -C "${AK3_DIR}" rev-list -1 --before='2023-10-21T00:00:00' HEAD)"
if [ -z "${AK3_COMMIT}" ]; then
  echo "::error::could not resolve an AnyKernel3 commit dated before 2023-10-21"
  exit 1
fi
git -C "${AK3_DIR}" checkout --quiet "${AK3_COMMIT}"
echo "=== AnyKernel3 pinned to ${AK3_COMMIT} ==="

# ------------------------------------------------------------------------
# 1. Replace AK3's 32-bit toolset with AArch64 binaries.
#
# osm0sis/AnyKernel3 builds EVERY executable in tools/ for 32-bit ARM
# (ELFCLASS32 / EM_ARM), verified byte-for-byte against
# osm0sis/AnyKernel3@master -- so this is upstream's own state, not
# something our checkout did wrong. Pixel 8 / 8 Pro / 8a are Tensor G3
# (zuma), and Google dropped 32-bit execution entirely at Tensor G3 (the
# Pixel 8 ships "exclusively with 64-bit binaries"), so none of those
# tools can execute at all. The flash then dies inside update-binary:
#
#   bb=$AKHOME/tools/busybox;  $bb --install -s bin;
#   if [ $? != 0 -o -z "$(ls bin)" ]; then abort "Busybox setup failed"
#
# which is exactly the device-side "failed to initialise busybox / error 1"
# -- and it fires before any kernel content is touched, which is why both
# v0.1.0 and v0.2.0 died identically no matter how correct the packaging
# around them became. update-binary is byte-identical to the reference
# (sha256 3422BB25...), so the busybox binary was the ONLY difference in
# that code path.
#
# The reference zip known to flash on this device carries an all-AArch64
# toolset instead. Its busybox is byte-identical (sha256 C629FCE4B0DD3BA9)
# to osm0sis' official busybox-ndk `busybox-arm64`, which is where ours is
# taken from; the other six come from that proven zip.
AK3_TOOLS_SRC="${REPO_ROOT}/.github/ak3-tools"
if [ ! -d "${AK3_TOOLS_SRC}" ]; then
  echo "::error::AArch64 AnyKernel3 toolset missing at ${AK3_TOOLS_SRC}"
  exit 1
fi
cp -f "${AK3_TOOLS_SRC}/"* "${AK3_DIR}/tools/"
chmod 755 "${AK3_DIR}"/tools/*
echo "=== AnyKernel3 tools replaced with AArch64 ==="

# Turn this entire bug class into a red build instead of a device-side
# abort: every ELF in the toolset must be 64-bit AArch64 (e_ident[4]==2,
# e_machine==183/0xB7). ak3-core.sh is skipped because it is not an ELF.
for tool in "${AK3_DIR}"/tools/*; do
  [ -f "${tool}" ] || continue
  [ "$(od -An -tx1 -N4 "${tool}" | tr -d ' \n')" = "7f454c46" ] || continue
  tool_class="$(od -An -tu1 -j4 -N1 "${tool}" | tr -d ' \n')"
  tool_machine="$(od -An -tu1 -j18 -N2 "${tool}" | tr -s ' ' | awk '{ print (256 * $2) + $1 }')"
  if [ "${tool_class}" != "2" ] || [ "${tool_machine}" != "183" ]; then
    echo "::error::AK3 tool $(basename "${tool}") is ELF${tool_class}/machine=${tool_machine}, not AArch64 -- this 64-bit-only device cannot execute it and the flash would abort with 'Busybox setup failed'"
    exit 1
  fi
  echo "  AArch64 OK: $(basename "${tool}")"
done

# ------------------------------------------------------------------------
# 2. Slot-detection fallback, matching the reference zip exactly.
#
# anykernel.sh sets is_slot_device=1, and setup_ak() in ak3-core.sh turns
# an undetected slot into a HARD abort ("Unable to determine active
# slot. Aborting..."). Stock AK3 only tries getprop and /proc/cmdline,
# but newer Pixels pass androidboot.slot_suffix through /proc/bootconfig
# instead. The proven reference carries this extra guarded fallback --
# with it applied our ak3-core.sh becomes byte-identical to that file
# (sha256 0767a6b0d9ca1656). It only runs when getprop and cmdline both
# came up empty.
if ! grep -q '/proc/bootconfig' "${AK3_DIR}/tools/ak3-core.sh"; then
  if ! bash -n "${AK3_DIR}/tools/ak3-core.sh"; then
    echo "::error::ak3-core.sh does not parse before patching"
    exit 1
  fi
  # The anchor must match ONLY the bare `androidboot.slot=` line: the
  # `androidboot.slot_suffix=` lines cannot match because `slot` is
  # followed by `_`, not `=`. Verified against a fixture before shipping.
  SLOT_LINE="$(grep -n 'androidboot\.slot=' "${AK3_DIR}/tools/ak3-core.sh" | head -n1 | cut -d: -f1 || true)"
  if [ -z "${SLOT_LINE}" ]; then
    echo "::error::could not locate the slot-detection line in ak3-core.sh"
    exit 1
  fi
  cat > /tmp/ak3-bootconfig-fallback << 'SLOTEOF'
        [ "$slot" ] || slot=$(grep -o 'androidboot.slot_suffix = ".*"$' /proc/bootconfig | cut -d '"' -f2 | cut -c 2);
SLOTEOF
  # `sed N r file` appends file contents after line N -- deliberately
  # chosen over an inline sed replacement to avoid fighting with the $(),
  # single quotes and double quotes the replacement line is full of.
  sed -i "${SLOT_LINE}r /tmp/ak3-bootconfig-fallback" "${AK3_DIR}/tools/ak3-core.sh"
  if ! bash -n "${AK3_DIR}/tools/ak3-core.sh" || ! grep -q '/proc/bootconfig' "${AK3_DIR}/tools/ak3-core.sh"; then
    echo "::error::bootconfig slot fallback did not apply cleanly to ak3-core.sh"
    exit 1
  fi
  echo "=== ak3-core.sh: bootconfig slot fallback applied after line ${SLOT_LINE} ==="
fi

rm -f "${AK3_DIR}/Image" "${AK3_DIR}/Image.lz4" "${AK3_DIR}/dtb"
rm -rf "${AK3_DIR}/modules"

# Ship the kernel lz4-compressed, exactly as the reference build does --
# a ~15 MB payload instead of a ~90 MB one. AK3 injects whichever
# Image* it finds into the boot image, and the reference zip carries
# Image.lz4 rather than a bare Image.
command -v lz4 >/dev/null || { echo "::error::lz4 missing from the runner"; exit 1; }
lz4 -9 -f arch/arm64/boot/Image "${AK3_DIR}/Image.lz4"

# A single concatenated `dtb` FILE is what AK3's automatic
# multi-partition setup keys on (`[ -f dtb -o -d vendor_ramdisk -o -d
# vendor_patch ]`). With no such file neither branch fires, so nothing
# reaches vendor_kernel_boot and the device tree is never flashed. An
# empty dtb/ directory does not satisfy `-f dtb`, which is precisely the
# state the last zip shipped in. The reference build's dtb holds four
# blobs back to back -- verified by counting the d00dfeed magic at
# offsets 0, 385357, 770706 and 1156923 -- so concatenate in the same
# stable sorted order.
printf '%s\n' "${DTB_LIST}" | xargs cat > "${AK3_DIR}/dtb"
ls -la "${AK3_DIR}/Image.lz4" "${AK3_DIR}/dtb"
# With CONFIG_INTEGRATE_MODULES=y (set by the zuma fragment) the device
# drivers are built into the Image and no .ko files exist at all. Stage
# modules only when CONFIG_MODULES=y, so a built-in build skips this
# cleanly instead of dying on an empty find result -- but keep the
# zero-module hard error when modules ARE expected, because a silent
# skip there would ship a kernel missing its WiFi/BT/charging drivers.
# AK3 re-packs the whole ramdisk from its ramdisk/ dir
# (ak3-core.sh:266 `find . | cpio`), so anything placed here is merged
# into the boot image. The modules/ dir is only for KernelSU/Magisk
# helper modules, NOT for .ko installation, and do.modules=1
# additionally requires do.systemless=1 -- so keep do.modules=0 and
# ship any .ko files via the ramdisk instead.
if grep -q '^CONFIG_MODULES=y' .config; then
  MODREL="$(cat include/config/kernel.release 2>/dev/null || echo unknown)"
  RDRAM="${AK3_DIR}/ramdisk"
  MODDIR="${RDRAM}/lib/modules/${MODREL}"
  mkdir -p "${MODDIR}"
  # Best-effort strip: CFI/CFI-kcfi .ko files may not strip cleanly and
  # that is not fatal, so ignore strip failures but not copy failures.
  find . -name '*.ko' -not -path './.git/*' -print0 \
    | xargs -0 -r -n50 llvm-strip --strip-debug 2>/dev/null || true
  KOCOUNT=$(find . -name '*.ko' -not -path './.git/*' | wc -l)
  if [ "${KOCOUNT}" -eq 0 ]; then
    echo "::error::CONFIG_MODULES=y but no .ko modules were built; zuma device drivers (WiFi/BT/charging) would be missing"
    exit 1
  fi
  find . -name '*.ko' -not -path './.git/*' -exec cp {} "${MODDIR}/" \;
  echo "=== Staged ${KOCOUNT} .ko into ramdisk /lib/modules/${MODREL} ==="
else
  echo "=== CONFIG_MODULES=n: drivers are built into the Image, nothing to stage ==="
fi

cat > "${AK3_DIR}/anykernel.sh" << 'AKEOF'
### AnyKernel3 Ramdisk Mod Script
## Tensor G3 / zuma

### AnyKernel setup
# begin properties
properties() { '
kernel.string=Tensor G3 Kernel (zuma)
do.devicecheck=1
do.modules=0
do.cleanup=1
do.cleanuponabort=1
device.name1=zuma
device.name2=shiba
device.name3=shusky
device.name4=husky
device.name5=akita
supported.versions=-
'; } # end properties

# NB: `tokay` (Pixel 9, Tensor G4) is deliberately absent from that
# list. do_devicecheck() in update-binary compares each name with an
# EXACT `==` against four properties (ro.product.device, ro.build.product,
# ro.product.vendor.device, ro.vendor.product.device), so including tokay
# would authorise flashing a G3 Image onto a G4 device. Only Tensor G3
# Pixels belong there: shiba (Pixel 8), husky (Pixel 8 Pro), akita
# (Pixel 8a).
#
# NB: `shiba` was missing until now -- the list read zuma/shusky/husky/
# akita, and `shusky` is the shared source-tree name for the shiba/husky
# pair, never a retail property value. Because do_devicecheck aborts with
# "Unsupported device" on no match, every plain Pixel 8 would have been
# refused. `zuma` (the Tensor G3 SoC name) and `shusky` are kept: an
# exact match can only ever widen to another G3 name, never to a G4 one.
#
# NB: the properties above MUST stay at column 0. update-binary reads
# them with file_getprop(), which is literally
#   grep "^$2=" anykernel.sh
# -- anchored to the start of the line. Indenting them by even one space
# made every single read return empty, so the device check, the version
# check and the kernel string had all been silently inert for the whole
# of the debugging phase.

# boot image installation
block=boot;
is_slot_device=1;
. tools/ak3-core.sh;
split_boot;
flash_boot;

# vendor_kernel_boot installation (for dtb)
block=vendor_kernel_boot;
is_slot_device=1;
reset_ak;
split_boot;
flash_boot;
AKEOF

cd "${AK3_DIR}"
if [ "${ENABLE_KSU}" = "true" ]; then
  AK3_ZIP="KernelSU-Next-zuma-${BUILD_TYPE}-${GITHUB_RUN_NUMBER}.zip"
else
  AK3_ZIP="TensorG3-kernel-zuma-${BUILD_TYPE}-${GITHUB_RUN_NUMBER}.zip"
fi
zip -r9 "${DIST_DIR}/${AK3_ZIP}" . -x ".git*" -x "README.md" -x "*.zip"

echo "=== Build completed successfully! ==="
