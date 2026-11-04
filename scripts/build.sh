#!/usr/bin/env bash
# cepheus (Xiaomi Mi 9) kernel build: crDroid 16.0 base + KernelSU-Next (manual hook)
#
# Same script runs in the cloud sandbox (Alpine/musl, host clang) and on GitHub
# Actions (Ubuntu, proton-clang).  Everything is env-configurable.
set -euo pipefail

# ---- configuration -----------------------------------------------------------
KERNEL_REPO="${KERNEL_REPO:-https://github.com/crdroidandroid/android_kernel_xiaomi_cepheus}"
KERNEL_REF="${KERNEL_REF:-16.0}"
# pin the exact base commit so an upstream re-base cannot silently change
# the tree we patch (empty => just track the branch tip)
KERNEL_SHA="${KERNEL_SHA-aa587668f86bd02ff1d7f825f5a89a886a84c8d8}"

KSU_REPO="${KSU_REPO:-https://github.com/KernelSU-Next/KernelSU-Next}"
# last legacy commit that still reports UAPI 5 == what manager v3.4.2 speaks
KSU_SHA="${KSU_SHA:-e3292239f3b8384cc52bdc6f23995d643271a7ce}"
KSU_VERSION="${KSU_VERSION_OVERRIDE:-33355}"          # manager v3.4.2 versionCode
KSU_TAG="${KSU_VERSION_TAG_OVERRIDE:-v3.4.2}"
KSU_MANAGER_PACKAGE="${KSU_MANAGER_PACKAGE:-com.rifsxd.ksunext}"

ENABLE_KSU="${ENABLE_KSU:-1}"                          # 0 => pure kernel (Magisk)
DEFCONFIG="${DEFCONFIG:-cepheus_defconfig}"

JOBS="${JOBS:-$(nproc)}"
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/out}"
TOOLCHAIN="${TOOLCHAIN:-host}"                         # host | proton
PROTON_REF="${PROTON_REF:-master}"
CLANG_PREFIX="${CLANG_PREFIX:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="$WORK/kernel"
log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

mkdir -p "$WORK" "$OUT"

# ---- 1. sources --------------------------------------------------------------
if [ ! -d "$KERNEL_DIR/.git" ]; then
  log "cloning kernel $KERNEL_REF"
  git clone --depth=1 -b "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL_DIR"
  if [ -n "$KERNEL_SHA" ]; then
    log "pinning base to $KERNEL_SHA"
    git -C "$KERNEL_DIR" fetch -q --depth=1 origin "$KERNEL_SHA"
    git -C "$KERNEL_DIR" checkout -q FETCH_HEAD
  fi
else
  log "reusing kernel checkout"
fi
cd "$KERNEL_DIR"
log "kernel base: $(grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL)' Makefile | tr -d ' ' | tr '\n' ' ')"

if [ "$ENABLE_KSU" = "1" ]; then
  KSU_SRC="$WORK/ksu-next"
  if [ ! -d "$KSU_SRC/kernel" ]; then
    log "cloning KernelSU-Next @ ${KSU_SHA:0:8}"
    rm -rf "$KSU_SRC"; git init -q "$KSU_SRC"
    git -C "$KSU_SRC" remote add origin "$KSU_REPO"
    git -C "$KSU_SRC" fetch -q --depth=1 origin "$KSU_SHA"
    git -C "$KSU_SRC" checkout -q FETCH_HEAD
  fi

  log "installing KernelSU-Next into drivers/kernelsu"
  rm -rf drivers/kernelsu; mkdir -p drivers/kernelsu
  cp -a "$KSU_SRC/kernel/." drivers/kernelsu/
  rm -f drivers/kernelsu/include/uapi                    # dangling symlink -> materialise
  cp -a "$KSU_SRC/uapi" drivers/kernelsu/include/uapi
  test -f drivers/kernelsu/include/uapi/app_profile.h
  grep -q 'kernelsu' drivers/Makefile
  grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig
fi

# ---- 2. deterministic kernel-side integration --------------------------------
# KernelSU's Kbuild mutates kernel sources with `$(shell sed -i ...)` while make
# is already running: with -j the target file is often compiled before the edit
# lands (undefined symbols) or after it (nondeterministic build).  We therefore
# apply exactly the changes that matter, before make starts.
python3 - "$KERNEL_DIR" "$ENABLE_KSU" <<'PYEOF'
import os, sys
root, enable_ksu = sys.argv[1], sys.argv[2] == "1"

def edit(rel, fn):
    p = os.path.join(root, rel)
    s = open(p, encoding="utf-8").read()
    new = fn(s)
    if new != s:
        open(p, "w", encoding="utf-8").write(new)
        print(f"    patched {rel}")
    else:
        print(f"    already patched {rel}")

if enable_ksu:
    # (a) manual-hook sentinel: KernelSU's Kbuild greps kernel/reboot.c for this
    def reboot(s):
        if "ksu_handle_sys_reboot" in s:
            return s
        s = s.replace(
            "#include <linux/uaccess.h>\n",
            "#include <linux/uaccess.h>\n#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n"
            "\t\t\t\t void __user **arg);\n#endif\n", 1)
        old = ("SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
               "\t\tvoid __user *, arg)\n{\n"
               "\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n"
               "\tchar buffer[256];\n\tint ret = 0;\n")
        assert s.count(old) == 1, "reboot() body changed upstream"
        return s.replace(old, old + "\n#ifdef CONFIG_KSU\n"
                        "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n", 1)
    edit("kernel/reboot.c", reboot)

    # (b) struct seccomp needs filter_count (KSU app_profile resets it)
    def seccomp(s):
        if "filter_count" in s:
            return s
        s = s.replace("#include <linux/thread_info.h>\n",
                      "#include <linux/thread_info.h>\n#include <linux/atomic.h>\n", 1)
        old = "struct seccomp {\n\tint mode;\n\tstruct seccomp_filter *filter;\n};\n"
        assert s.count(old) == 1
        return s.replace(old, "struct seccomp {\n\tint mode;\n\tatomic_t filter_count;\n"
                              "\tstruct seccomp_filter *filter;\n};\n", 1)
    edit("include/linux/seccomp.h", seccomp)

    # (c) selinux_inode()/selinux_cred() accessors (upstream 5.x) used by KSU
    def objsec(s):
        if "selinux_inode" in s:
            return s
        anchor = "#endif /* _SELINUX_OBJSEC_H_ */\n"
        assert s.count(anchor) == 1
        return s.replace(anchor,
            "/* KernelSU compat: accessors added upstream in 5.x */\n"
            "static inline struct inode_security_struct *selinux_inode(const struct inode *inode)\n"
            "{\n\treturn inode->i_security;\n}\n\n"
            "static inline struct task_security_struct *selinux_cred(const struct cred *cred)\n"
            "{\n\treturn cred->security;\n}\n\n" + anchor, 1)
    edit("security/selinux/include/objsec.h", objsec)

    # (d) neutralise the racing build-time mutations in KernelSU's own Kbuild
    kb = os.path.join(root, "drivers/kernelsu/Kbuild")
    lines, n = [], 0
    for line in open(kb, encoding="utf-8").read().splitlines(keepends=True):
        t = line.lstrip()
        if t.startswith("$(shell sed -i") or t.startswith("ccflags-y += -DKSU_HAS_PATH_UMOUNT"):
            lines.append("# [ksu-ksun] disabled for deterministic build: " + line); n += 1
        else:
            lines.append(line)
    open(kb, "w", encoding="utf-8").write("".join(lines))
    print(f"    neutralised {n} build-time source mutations in KernelSU Kbuild")
else:
    # pure kernel (Magisk): no KernelSU sources on disk, so kconfig must not
    # source drivers/kernelsu/Kconfig and drivers/ must not descend into it
    for rel, pat, repl in (
        ("drivers/Kconfig", 'source "drivers/kernelsu/Kconfig"',
         '# [ksu-ksun] source "drivers/kernelsu/Kconfig"'),
        ("drivers/Makefile", "obj-y += kernelsu/", "# [ksu-ksun] obj-y += kernelsu/"),
    ):
        p = os.path.join(root, rel)
        t = open(p, encoding="utf-8").read()
        if repl in t:
            print("    already detached " + rel)
        else:
            assert pat in t, rel
            open(p, "w", encoding="utf-8").write(t.replace(pat, repl, 1))
            print("    detached kernelsu from " + rel)
# (d) dtc: pkg-config finds libyaml on the runner, but the host link then
# uses the clang toolchain's ld and dies on every yaml_* symbol. We never
# emit YAML, so build dtc with -DNO_YAML unconditionally.
p = os.path.join(root, 'scripts/dtc/Makefile')
t = open(p, encoding='utf-8').read()
if 'DTC_FORCE_NO_YAML' not in t:
    a = t.index('ifeq ($(shell pkg-config --exists yaml-0.1')
    b_ = t.index('endif'+chr(10), a) + len('endif'+chr(10))
    t = (t[:a]
         + '# DTC_FORCE_NO_YAML: keep dtc free of libyaml (no YAML output needed)'+chr(10)
         + 'HOST_EXTRACFLAGS += -DNO_YAML'+chr(10)
         + t[b_:])
    open(p, 'w', encoding='utf-8').write(t)
    print('    patched scripts/dtc/Makefile (NO_YAML)')
else:
    print('    already patched scripts/dtc/Makefile')
PYEOF

# ---- 3. defconfig ------------------------------------------------------------
cfg="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"
set_cfg() {  # $1 = key, $2 = value ("" => disable)
  sed -i "/^$1=/d; /^# $1 is not set/d" "$cfg"
  if [ -z "$2" ]; then echo "# $1 is not set" >> "$cfg"; else echo "$1=$2" >> "$cfg"; fi
}
# the ROM's init.rc/installd.rc still create/chmod /config/sdcardfs, so keep the
# driver even though Android 14 uses FUSE for /sdcard (zero-cost parity with stock)
set_cfg CONFIG_SDCARD_FS y
set_cfg CONFIG_KSU "$([ "$ENABLE_KSU" = 1 ] && echo y)"
if [ "$ENABLE_KSU" = "1" ]; then
  set_cfg CONFIG_KSU_MANUAL_HOOK y
  set_cfg CONFIG_KSU_DEBUG ""
fi
log "defconfig KSU: $(grep -E 'CONFIG_KSU' "$cfg" | tr '\n' ' ')"

# ---- 4. toolchain ------------------------------------------------------------
export ARCH=arm64
if [ "$TOOLCHAIN" = "proton" ]; then
  if [ ! -d "$WORK/proton-clang" ]; then
    log "cloning proton-clang"
    git clone -q --depth=1 -b "$PROTON_REF" https://github.com/kdrag0n/proton-clang.git "$WORK/proton-clang"
  fi
  export PATH="$WORK/proton-clang/bin:$PATH"
fi
# newer clang (19+) promotes a few 4.14-era warnings to errors; keep the build
# toolchain-agnostic instead of patching vendor trees
export KCFLAGS="${KCFLAGS:--Wno-unknown-warning-option -Wno-default-const-init-var-unsafe -Wno-enum-conversion}"
CC_BIN="${CC_BIN:-clang}"
# ccache pays off massively on kernel rebuilds (tens of minutes -> minutes)
if [ "${USE_CCACHE:-1}" = "1" ] && command -v ccache >/dev/null 2>&1; then
  CC_BIN="ccache $CC_BIN"
  log "ccache: $(ccache --version | head -1)"
fi
TRIPLE="${TRIPLE:-${CLANG_PREFIX}aarch64-linux-gnu-}"
export CROSS_COMPILE="${CROSS_COMPILE:-$TRIPLE}"
# 32-bit compat vDSO needs an ARM32 ld; the kernel looks it up as
# CROSS_COMPILE_COMPAT (arch/arm64/kernel/vdso32/Makefile), not _ARM32
export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-${CLANG_PREFIX}arm-linux-gnueabi-}"
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-$CROSS_COMPILE_COMPAT}"
log "clang: $($CC_BIN --version | head -1)"
log "cross: $CROSS_COMPILE"

MK=(O="$OUT" ARCH=arm64 CC="$CC_BIN" CLANG_TRIPLE="${CLANG_TRIPLE:-$TRIPLE}"
    CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT"
    HOSTCC="${HOSTCC:-gcc}" HOSTCXX="${HOSTCXX:-g++}")

# ---- 5. build ----------------------------------------------------------------
log "configuring"
make -j"$JOBS" "${MK[@]}" "$DEFCONFIG" >/dev/null

if [ "$ENABLE_KSU" = "1" ]; then
  grep -qx 'CONFIG_KSU=y' "$OUT/.config"              || { echo "FATAL: CONFIG_KSU missing"; exit 1; }
  grep -qx 'CONFIG_KSU_MANUAL_HOOK=y' "$OUT/.config"  || { echo "FATAL: manual hook not selected"; exit 1; }
  log "KSU config OK"
else
  ! grep -qx 'CONFIG_KSU=y' "$OUT/.config" || { echo "FATAL: pure kernel still has KSU"; exit 1; }
  log "pure kernel: CONFIG_KSU off"
fi

BUILD_ARGS=("${MK[@]}")
if [ "$ENABLE_KSU" = "1" ]; then
  BUILD_ARGS+=(KSU_VERSION_OVERRIDE="$KSU_VERSION" KSU_VERSION_TAG_OVERRIDE="$KSU_TAG"
               KSU_MANAGER_PACKAGE="$KSU_MANAGER_PACKAGE")
fi

log "building Image.gz-dtb (-j$JOBS)"
make -j"$JOBS" "${BUILD_ARGS[@]}" Image.gz-dtb

# ---- 6. assertions -----------------------------------------------------------
BOOT_DIR="$OUT/arch/arm64/boot"
log "artefacts"
ls -lh "$BOOT_DIR"/Image* | sed 's/^/    /'
[ -s "$BOOT_DIR/Image" ] || { echo "FATAL: no Image"; exit 1; }

if [ "$ENABLE_KSU" = "1" ]; then
  fail=0
  for s in ksu_handle_execveat ksu_handle_faccessat ksu_handle_stat ksu_handle_vfs_read \
           ksu_handle_sys_reboot ksu_handle_input_handle_event ksu_lsm_hook_init; do
    if nm "$OUT/vmlinux" 2>/dev/null | grep -qE " (T|t) $s\$"; then printf '    ok   %s\n' "$s"
    else printf '    FAIL %s\n' "$s"; fail=1; fi
  done
  for o in fs/exec.o fs/open.o fs/stat.o fs/read_write.o drivers/input/input.o kernel/reboot.o; do
    n=$(nm "$OUT/$o" 2>/dev/null | grep -c ' U ksu_' || true)
    printf '    hook refs %-24s %s\n' "$o" "$n"
    [ "${n:-0}" -ge 1 ] || { echo "    FAIL: no ksu_ reference in $o"; fail=1; }
  done
  nm "$OUT/vmlinux" | grep -qE ' (T|t) ksu_shell_su_allowed_for_current$' \
    && printf '    ok   shell_su_adb_only present\n' || true
  [ "$fail" = 0 ] || { echo "FATAL: KernelSU hooks missing"; exit 1; }
fi

strings -a "$BOOT_DIR/Image" 2>/dev/null | grep -m1 '^Linux version' | sed 's/^/    /' || true

# ---- 7. package --------------------------------------------------------------
cp "$BOOT_DIR/Image.gz-dtb" "$OUT/Image.gz-dtb" 2>/dev/null || true
cp "$BOOT_DIR/Image.gz" "$OUT/Image.gz" 2>/dev/null || true
cp "$BOOT_DIR/Image" "$OUT/Image"

if [ "${PACKAGE_ANY_KERNEL:-1}" = "1" ]; then
  log "packaging AnyKernel3"
  AK="$WORK/AnyKernel3"
  [ -d "$AK" ] || git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3.git "$AK"
  rm -f "$AK"/Image* "$AK"/*.zip 2>/dev/null || true
  cp "$OUT/Image.gz-dtb" "$AK/" 2>/dev/null || cp "$OUT/Image.gz" "$AK/"
  sed -i "s/^kernel.string=.*/kernel.string=cepheus 4.14 KSU-Next (crDroid 16.0 base)/" "$AK/anykernel.sh" 2>/dev/null || true
  ( cd "$AK" && zip -q -r9 "$OUT/cepheus-kernel-ksun.zip" . -x '.git/*' )
  ls -lh "$OUT/cepheus-kernel-ksun.zip" | sed 's/^/    /'
fi

resolve() { case "$1" in /*) echo "$1";; *) echo "$REPO_ROOT/$1";; esac; }
if [ -n "${RAMDISK:-}" ]; then
  RAMDISK="$(resolve "$RAMDISK")"
  CMDLINE_FILE="$(resolve "${CMDLINE_FILE:-prebuilt/boot.cmdline}")"
  if [ "$ENABLE_KSU" = "1" ]; then
    # allow_shell + shell_su_adb_only are module params, so they have to travel
    # in the kernel command line of the packed image
    cp "$CMDLINE_FILE" "$OUT/boot.cmdline"
    printf ' kernelsu.allow_shell=1 kernelsu.force_feature=shell_su_adb_only:1' >> "$OUT/boot.cmdline"
    CMDLINE_FILE="$OUT/boot.cmdline"
  fi
  AVB_VBMETA="$(resolve "${AVB_VBMETA:-prebuilt/boot.avb.vbmeta}")"
  [ -f "$RAMDISK" ] || { echo "FATAL: RAMDISK not found: $RAMDISK"; exit 1; }
  [ -f "$CMDLINE_FILE" ] || { echo "FATAL: CMDLINE_FILE not found: $CMDLINE_FILE"; exit 1; }
  log "building boot.img (header v0, qcom wrapper, stock layout)"
  python3 "$REPO_ROOT/scripts/mkboot_v0.py" \
    --kernel "$OUT/Image.gz-dtb" --ramdisk "$RAMDISK" \
    --cmdline-file "$CMDLINE_FILE" \
    --avb-vbmeta "$AVB_VBMETA" \
    --out "$OUT/boot.img" --pad-to "${BOOT_PARTITION_SIZE:-134217728}"
fi

if [ -f "$OUT/boot.img" ] && [ -f "$REPO_ROOT/prebuilt/stock-kernel.config" ]; then
  log "compatibility check (stock crDroid 10.14 baselines)"
  bash "$REPO_ROOT/scripts/compat-check.sh" "$OUT"
fi

log "done"
