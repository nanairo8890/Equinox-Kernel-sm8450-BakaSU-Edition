#!/usr/bin/env bash
# Equinox Kernel by LF52406 - BakaSU edition by Nanairo (with the author's permission).
#
# Builds the kernel Image with BakaSU (the KernelSU/ submodule, built in), SUSFS v2.3.0,
# NoMount, BBR by default and Equinox's DroidSpaces KMI-safe profile.
# KernelSU-Next's production flow (build-production.sh) is not used by this edition.
#
#   CLANG_DIR=/path/to/clang/bin scripts/equinox/build-bakasu.sh [out dir]
#
# Any recent Clang works; release builds use AOSP clang-r584948. LTO=full selects
# full LTO like official Equinox (needs well over 10 GB of RAM); ThinLTO is the default.
#
# The kernel trusts the official BakaSU manager through the signing certificate built into
# BakaSU (manager/manager_sign.h); no extra certificate is passed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath -m "${1:-$ROOT/out}")
[ -n "${CLANG_DIR:-}" ] && export PATH="$CLANG_DIR:$PATH"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-Nanairo}" KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-Equinox}"
MAKE=(make -C "$ROOT" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION= PYTHON=python3)

for cmd in clang ld.lld make python3 cpio git; do
    command -v "$cmd" >/dev/null || { echo "[!] missing tool: $cmd"; exit 1; }
done

# BakaSU takes its version code from the commit count of the submodule (a full clone is needed)
[ -f "$ROOT/KernelSU/kernel/Kbuild" ] || git -C "$ROOT" submodule update --init KernelSU
[ "$(git -C "$ROOT/KernelSU" rev-parse --is-shallow-repository)" = false ] || { echo '[!] KernelSU/ is a shallow clone'; exit 1; }
[ "$(readlink "$ROOT/drivers/kernelsu")" = ../KernelSU/kernel ] || { echo '[!] drivers/kernelsu link missing'; exit 1; }

# Apply the SUSFS "hide own KSU sepolicy types" hotfix to the pristine submodule (idempotent).
# The submodule stays pinned/pristine in git; this patch introduces the change only at build time.
HOTFIX="$ROOT/scripts/equinox/patches/0001-susfs-hide-ksu-types.patch"
if git -C "$ROOT/KernelSU" apply --reverse --check "$HOTFIX" 2>/dev/null; then
    echo "[=] hotfix 0001-susfs-hide-ksu-types already applied"
else
    git -C "$ROOT/KernelSU" apply "$HOTFIX" || { echo '[!] cannot apply 0001-susfs-hide-ksu-types.patch'; exit 1; }
    echo "[+] applied hotfix 0001-susfs-hide-ksu-types"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
"${MAKE[@]}" -s gki_defconfig
(cd "$ROOT" && scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" \
    arch/arm64/configs/vendor/waipio_GKI.config \
    arch/arm64/configs/vendor/xiaomi_GKI.config \
    arch/arm64/configs/vendor/mondrian_GKI.config \
    arch/arm64/configs/vendor/debugfs.config \
    scripts/equinox/configs/gatito-bakasu.config \
    scripts/equinox/configs/droidspaces-kmi-safe.config)
if [ "${LTO:-thin}" != full ]; then
    "$ROOT/scripts/config" --file "$OUT/.config" --disable LTO_CLANG_FULL --enable LTO_CLANG_THIN
fi
"${MAKE[@]}" -s olddefconfig

for opt in KSU KSU_SUSFS KALLSYMS_ALL KPROBES EXT4_FS NOMOUNT SYSVIPC CFI_CLANG MODVERSIONS DEFAULT_BBR; do
    grep -q "^CONFIG_$opt=y" "$OUT/.config" || { echo "[!] CONFIG_$opt is not enabled"; exit 1; }
done

rm -f "$OUT/include/config/auto.conf" "$OUT/include/config/auto.conf.cmd"
"${MAKE[@]}" -s olddefconfig
"${MAKE[@]}" -s prepare
# BakaSU's preinit runner is built against the target UAPI headers
"${MAKE[@]}" -s headers
release=$("${MAKE[@]}" -s kernelrelease)
[ "$release" = 5.10.269-Nanairo-BakaSU ] || { echo "[!] unexpected kernel release: $release"; exit 1; }

"${MAKE[@]}" -j"$(nproc)" Image
echo "[+] $OUT/arch/arm64/boot/Image ($release)"
echo "    Package it with scripts/equinox/package-bakasu.sh; with KMI_BASELINE set to a clean"
echo "    Equinox vmlinux.symvers it also requires 0 changed CRCs and 0 removed exports."
