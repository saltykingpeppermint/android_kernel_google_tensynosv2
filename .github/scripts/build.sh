#!/usr/bin/env bash
set -e
set -o pipefail

BUILD_DIR="/tmp/kernel_build"

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
  grep -iE "error:|error [0-9]+|undefined reference|No rule to make target|Traceback|fatal|Killed|make.*\*\*\*|command not found|cannot (find|open|access)" \
       "${BUILD_LOG}" 2>/dev/null \
     | grep -viE "syntaxwarning|deprecat" > /tmp/kernel_build.raw
  awk -F: '!seen[$1]++ {print; if (++n == 15) exit}' \
      /tmp/kernel_build.raw > /tmp/kernel_build.hits
  if [ -s /tmp/kernel_build.hits ]; then
    hits="$(tr '\n' '|' < /tmp/kernel_build.hits)"
  else
    hits="(no hard-error pattern matched) tail: $(tail -n 6 "${BUILD_LOG}" 2>/dev/null | tr '\n' '|')"
  fi
  echo "::error::BUILD FAILED (rc=${rc}) :: ${hits}"
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
# -k (keep going) is TEMPORARY triage mode. 16.0.0-sultan has proven
# to be a lossy merge carrying several independent source bugs (an
# undeclared tracepoint export, a missing DECLARE_RWSEM), and
# stopping at the first failure costs one ~10-30 minute CI cycle per
# bug. Letting make carry on surfaces every broken translation unit
# in a single run. Set MAKE_KEEP_GOING back to "" once the tree
# compiles clean.
MAKE_KEEP_GOING="-k"
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
ls -la arch/arm64/boot/dts/google/*.dtb 2>/dev/null || true

# Copy artifacts
mkdir -p "${DIST_DIR}"
cp arch/arm64/boot/Image "${DIST_DIR}/Image-${BUILD_TYPE}"
cp .config "${DIST_DIR}/config-${BUILD_TYPE}"
cp vmlinux "${DIST_DIR}/vmlinux-${BUILD_TYPE}" 2>/dev/null || true
mkdir -p "${DIST_DIR}/dtb"
cp arch/arm64/boot/dts/google/*.dtb "${DIST_DIR}/dtb/" 2>/dev/null || true

echo "=== Creating AnyKernel3 flashable zip ==="
AK3_DIR="/tmp/anykernel3"
rm -rf "${AK3_DIR}"
git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "${AK3_DIR}"
rm -f "${AK3_DIR}/Image" "${AK3_DIR}/dtb"
rm -rf "${AK3_DIR}/modules"
cp arch/arm64/boot/Image "${AK3_DIR}/"
mkdir -p "${AK3_DIR}/dtb"
cp arch/arm64/boot/dts/google/*.dtb "${AK3_DIR}/dtb/" 2>/dev/null || true
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

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;
write_boot;
## end boot install
AKEOF

cd "${AK3_DIR}"
if [ "${ENABLE_KSU}" = "true" ]; then
  AK3_ZIP="KernelSU-Next-zuma-${BUILD_TYPE}-${GITHUB_RUN_NUMBER}.zip"
else
  AK3_ZIP="TensorG3-kernel-zuma-${BUILD_TYPE}-${GITHUB_RUN_NUMBER}.zip"
fi
zip -r9 "${DIST_DIR}/${AK3_ZIP}" . -x ".git*" -x "README.md" -x "*.zip"

echo "=== Build completed successfully! ==="
