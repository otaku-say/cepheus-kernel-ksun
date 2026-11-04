#!/usr/bin/env python3
"""Generate deterministic patches against crDroid cepheus 16.0 (Linux 4.14.355)
and against KernelSU-Next legacy @ e3292239.

Outputs to patches/kernel/*.patch and patches/ksu/*.patch and verifies each
one applies with `patch --dry-run -p1` on the pristine source.
"""
import os, shutil, subprocess, sys, urllib.request

SRC = "src"
OUT_K = "patches/kernel"
OUT_S = "patches/ksu"
BASE_CRDROID = "https://raw.githubusercontent.com/crdroidandroid/android_kernel_xiaomi_cepheus/16.0/"
KSU_SHA = "e3292239f3b8384cc52bdc6f23995d643271a7ce"
BASE_KSU = f"https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/{KSU_SHA}/"


def fetch(base, path, dst):
    if not os.path.exists(dst):
        urllib.request.urlretrieve(base + path, dst)
    return dst


def workfiles(rel):
    """return (orig, new) temp paths for a source-relative path"""
    tag = rel.replace("/", "__")
    o = os.path.join(SRC, "A__" + tag)
    n = os.path.join(SRC, "B__" + tag)
    return o, n


def make_rel(rel, base, transform):
    o, n = workfiles(rel)
    fetch(base, rel, o)
    data = open(o, "rb").read().decode("utf-8", "surrogateescape")
    newdata = transform(data)
    assert newdata != data, "transform produced no change for " + rel
    open(n, "wb").write(newdata.encode("utf-8", "surrogateescape"))
    os.makedirs(os.path.dirname(o + ".x") or ".", exist_ok=True)
    # produce unified diff with a/ b/ prefixes
    import difflib
    a = data.splitlines(keepends=True)
    b = newdata.splitlines(keepends=True)
    diff = list(difflib.unified_diff(a, b, fromfile="a/" + rel, tofile="b/" + rel, n=3))
    return "".join(diff)


def write_patch(path, diff):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w", encoding="utf-8", newline="\n").write(diff)
    print(f"  wrote {path} ({len(diff.splitlines())} lines)")


def verify(patchfile, rel, base):
    """apply patch onto pristine copy and confirm it lands"""
    o, n = workfiles(rel)
    fetch(base, rel, o)
    tmp = os.path.join(SRC, "V__" + rel.replace("/", "__"))
    shutil.copyfile(o, tmp)
    r = subprocess.run(["patch", "-p1", "--dry-run", "-f", "-i", os.path.abspath(patchfile)],
                       cwd=os.path.dirname(tmp), input="", capture_output=True, text=True)
    if r.returncode != 0:
        # try from a dir where a/<rel> exists
        os.makedirs(os.path.join(SRC, "vt", os.path.dirname(rel)), exist_ok=True)
        shutil.copyfile(o, os.path.join(SRC, "vt", rel))
        r = subprocess.run(["patch", "-p1", "--dry-run", "-f", "-i", os.path.abspath(patchfile)],
                           cwd=os.path.join(SRC, "vt"), capture_output=True, text=True)
    ok = r.returncode == 0
    print(f"  verify {os.path.basename(patchfile)}: {'OK' if ok else 'FAIL'}")
    if not ok:
        print(r.stdout, r.stderr)
    return ok


# ---------------------------------------------------------------- kernel patches

def t_reboot(s):
    anchor = "#include <linux/uaccess.h>\n"
    decl = ("#include <linux/uaccess.h>\n"
            "#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n"
            "\t\t\t\t void __user **arg);\n"
            "#endif\n")
    assert s.count(anchor) == 1
    s = s.replace(anchor, decl, 1)

    fn = ("SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
          "\t\tvoid __user *, arg)\n{\n"
          "\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n"
          "\tchar buffer[256];\n"
          "\tint ret = 0;\n")
    assert s.count(fn) == 1, "reboot syscall body not found"
    s = s.replace(fn, fn +
                  "\n#ifdef CONFIG_KSU\n"
                  "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
                  "#endif\n", 1)
    return s


def t_seccomp(s):
    anchor = "#include <linux/thread_info.h>\n"
    assert s.count(anchor) == 1
    s = s.replace(anchor, anchor + "#include <linux/atomic.h>\n", 1)
    old = "struct seccomp {\n\tint mode;\n\tstruct seccomp_filter *filter;\n};\n"
    assert s.count(old) == 1
    s = s.replace(old, "struct seccomp {\n\tint mode;\n\tatomic_t filter_count;\n\tstruct seccomp_filter *filter;\n};\n", 1)
    return s


def t_objsec(s):
    anchor = "#endif /* _SELINUX_OBJSEC_H_ */\n"
    assert s.count(anchor) == 1
    helpers = (
        "/* KernelSU compatibility: accessors added upstream in 5.x */\n"
        "static inline struct inode_security_struct *selinux_inode(const struct inode *inode)\n"
        "{\n"
        "\treturn inode->i_security;\n"
        "}\n"
        "\n"
        "static inline struct task_security_struct *selinux_cred(const struct cred *cred)\n"
        "{\n"
        "\treturn cred->security;\n"
        "}\n"
        "\n")
    return s.replace(anchor, helpers + anchor, 1)


def t_ksu_kbuild(s):
    """Neutralise every build-time source mutation; we apply those patches ourselves
    deterministically (see patches/kernel)."""
    out = []
    n = 0
    for line in s.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith("$(shell sed -i") or stripped.startswith("ccflags-y += -DKSU_HAS_PATH_UMOUNT"):
            out.append("# [ksu-ksun] disabled for deterministic build: " + line)
            n += 1
        else:
            out.append(line)
    assert n >= 5, f"expected several mutations, found {n}"
    print(f"  neutralised {n} build-time mutations in KSU Kbuild")
    return "".join(out)


def main():
    os.makedirs(SRC, exist_ok=True)
    jobs = [
        (OUT_K + "/0001-reboot-ksu-sentinel.patch", "kernel/reboot.c", BASE_CRDROID, t_reboot),
        (OUT_K + "/0002-seccomp-filter-count.patch", "include/linux/seccomp.h", BASE_CRDROID, t_seccomp),
        (OUT_K + "/0003-selinux-compat-helpers.patch", "security/selinux/include/objsec.h", BASE_CRDROID, t_objsec),
        (OUT_S + "/0001-disable-kbuild-source-mutations.patch", "kernel/Kbuild", BASE_KSU, t_ksu_kbuild),
    ]
    ok = True
    for path, rel, base, fn in jobs:
        print(f"* {path}")
        diff = make_rel(rel, base, fn)
        write_patch(path, diff)
        ok &= verify(path, rel, base)
    print("all patches verified" if ok else "SOME PATCHES FAILED TO APPLY")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
