#!/usr/bin/env python3
"""Offline compatibility check: built kernel/boot.img vs the stock crDroid 10.14 kernel.

Everything here is local and deterministic - no device needed. It answers the
question "would this kernel still carry the ROM's drivers and be accepted by the
bootloader", not "does it boot" (that needs hardware).

Checks
  1. config parity    every =y/=m entry of the stock kernel must match ours
  2. module drift     we must not turn anything into =m (the ROM ships no modules)
  3. subsystems       a fixed list of kernel features the ROM depends on
  4. boot.img shape   128 MiB, header v0, page 4096, QCOM kernel wrapper, AVB blocks
  5. device tree      appended DTB set identical to the stock image
  6. ramdisk          byte-identical to the stock ramdisk
  7. cmdline          stock cmdline must be an exact prefix of ours

Usage:
  compat_check.py --config out/.config --bootimg out/boot.img \
                  --stock-config prebuilt/stock-kernel.config \
                  --stock-dtb prebuilt/stock-dtb.sha256 \
                  --stock-ramdisk prebuilt/stock-ramdisk.sha256 \
                  --allowlist prebuilt/compat-allowlist.txt \
                  --report out/compat-report.md
"""
import argparse
import hashlib
import os
import struct
import sys

PASS, FAIL, NOTE = "PASS", "FAIL", "NOTE"


class Report:
    def __init__(self):
        self.rows = []
        self.failed = 0

    def add(self, check, status, detail):
        self.rows.append((check, status, detail))
        if status == FAIL:
            self.failed += 1

    def markdown(self):
        out = ["| check | result | detail |", "|---|---|---|"]
        icon = {PASS: "PASS", FAIL: "**FAIL**", NOTE: "note"}
        for c, s, d in self.rows:
            out.append(f"| {c} | {icon[s]} | {d} |")
        out.append("")
        out.append(f"**{self.failed} failure(s)**" if self.failed else "**all checks passed**")
        return "\n".join(out)


def load_config(path):
    cfg = {}
    if not path or not os.path.exists(path):
        return cfg
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cfg[k] = v
    return cfg


def load_allowlist(path):
    allowed = {}
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split(None, 1)
            allowed[parts[0]] = parts[1] if len(parts) > 1 else ""
    return allowed


def load_hashes(path):
    if not path or not os.path.exists(path):
        return []
    return [l.strip() for l in open(path, encoding="utf-8") if l.strip()]


def split_boot(path):
    """decompose a cepheus boot.img (header v0 + QCOM kernel wrapper)"""
    d = open(path, "rb").read()
    magic, kern_size, _, ramdisk_size, _, _, _, _, page, _, _ = struct.unpack_from("<8s10I", d, 0)
    cmdline = d[64:64 + 512].split(b"\x00")[0].decode(errors="replace")
    kblob = d[page:page + kern_size]
    rd_off = page * (1 + (kern_size + page - 1) // page)
    ramdisk = d[rd_off:rd_off + ramdisk_size]
    wrapper = kblob[:16]
    img_size = struct.unpack_from("<I", kblob, 16)[0] if wrapper == b"UNCOMPRESSED_IMG" else 0
    raw = kblob[20:20 + img_size]
    dtb_region = kblob[20 + img_size:] if img_size else b""
    avb_vbmeta = d.find(b"AVB0", rd_off + ramdisk_size)
    avbf = d[-64:][:4]
    return dict(data=d, magic=magic, kern_size=kern_size, ramdisk_size=ramdisk_size,
                page=page, cmdline=cmdline, kblob=kblob, wrapper=wrapper,
                img_size=img_size, raw=raw, dtb_region=dtb_region,
                ramdisk=ramdisk, avb_vbmeta=avb_vbmeta, avbf=avbf, size=len(d))


def dtb_hashes(region):
    out, p = [], 0
    fdt = bytes.fromhex("d00dfeed")
    while True:
        p = region.find(fdt, p)
        if p < 0:
            break
        total = struct.unpack_from(">I", region, p + 4)[0]
        if total <= 0 or p + total > len(region):
            break
        out.append(hashlib.sha256(region[p:p + total]).hexdigest())
        p += total
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config")
    ap.add_argument("--bootimg")
    ap.add_argument("--stock-config", default="prebuilt/stock-kernel.config")
    ap.add_argument("--stock-dtb", default="prebuilt/stock-dtb.sha256")
    ap.add_argument("--stock-ramdisk", default="prebuilt/stock-ramdisk.sha256")
    ap.add_argument("--allowlist", default="prebuilt/compat-allowlist.txt")
    ap.add_argument("--report", default="out/compat-report.md")
    ap.add_argument("--expect-partition-size", type=int, default=134217728)
    a = ap.parse_args()

    r = Report()
    ours = load_config(a.config)
    stock = load_config(a.stock_config)
    allow = load_allowlist(a.allowlist)

    # ---- 1/2 config parity ---------------------------------------------------
    if not stock or not ours:
        r.add("config parity", FAIL, f"missing config (stock={bool(stock)}, ours={bool(ours)})")
    else:
        drift = []
        for k, v in stock.items():
            if v not in ("y", "m") or k in allow:
                continue
            if k not in ours:
                drift.append(f"{k}: {v} -> absent")
            elif ours[k] != v:
                drift.append(f"{k}: {v} -> {ours[k]}")
        extra_mods = [k for k, v in ours.items()
                      if v == "m" and k not in allow and stock.get(k) != "m"]
        n_stock = sum(1 for v in stock.values() if v in ("y", "m"))
        if drift:
            r.add("config parity", FAIL,
                  f"{len(drift)}/{n_stock} stock entries differ: " + "; ".join(drift[:8]))
        else:
            r.add("config parity", PASS, f"all {n_stock} stock =y/=m entries match")
        if extra_mods:
            r.add("module drift", FAIL, "became =m but ROM ships no modules: " + ", ".join(extra_mods[:8]))
        else:
            r.add("module drift", PASS, "no =m introduced")

    # ---- 3 subsystems the ROM relies on -------------------------------------
    required = {
        "CONFIG_ANDROID_BINDER_IPC": "binder",
        "CONFIG_ANDROID_BINDERFS": "binderfs (init mounts it)",
        "CONFIG_CONFIGFS_FS": "configfs",
        "CONFIG_FUSE_FS": "FUSE /sdcard",
        "CONFIG_SDCARD_FS": "sdcardfs configfs nodes used by init/installd",
        "CONFIG_DM_VERITY": "dm-verity",
        "CONFIG_BLK_DEV_DM": "device-mapper",
        "CONFIG_SECURITY_SELINUX": "SELinux",
        "CONFIG_COMPAT": "32-bit apps",
        "CONFIG_OVERLAY_FS": "overlayfs (KSU modules)",
        "CONFIG_TMPFS_XATTR": "tmpfs xattr (KSU modules)",
        "CONFIG_EXT4_FS": "ext4 system",
        "CONFIG_F2FS_FS": "f2fs /data",
        "CONFIG_ZRAM": "zram swap",
    }
    missing = [f"{k} ({why})" for k, why in required.items() if ours.get(k) != "y"]
    if missing:
        r.add("subsystems", FAIL, "; ".join(missing))
    else:
        r.add("subsystems", PASS, f"{len(required)} required features present")

    # ---- 4/5/6/7 boot.img ----------------------------------------------------
    if not a.bootimg or not os.path.exists(a.bootimg):
        r.add("boot.img shape", NOTE, "no boot.img produced (RAMDISK not set)")
    else:
        b = split_boot(a.bootimg)
        problems = []
        if b["magic"] != b"ANDROID!":
            problems.append(f"bad header magic {b['magic']!r}")
        if b["size"] != a.expect_partition_size:
            problems.append(f"size {b['size']} != {a.expect_partition_size}")
        if b["page"] != 4096:
            problems.append(f"page_size {b['page']}")
        if b["wrapper"] != b"UNCOMPRESSED_IMG":
            problems.append(f"kernel wrapper {b['wrapper']!r}")
        if not (0 < b["img_size"] <= b["kern_size"]):
            problems.append("bad kernel payload size")
        if b["avb_vbmeta"] < 0:
            problems.append("no AVB0 block")
        if b["avbf"] != b"AVBf":
            problems.append("no trailing AvbFooter")
        if problems:
            r.add("boot.img shape", FAIL, "; ".join(problems))
        else:
            r.add("boot.img shape", PASS,
                  f"{b['size']:,} B, page {b['page']}, kernel {b['kern_size']:,} B, AVB ok")

        want = sorted(load_hashes(a.stock_dtb))
        got = dtb_hashes(b["dtb_region"])
        if not want:
            r.add("device tree", NOTE, "no stock DTB baseline")
        elif want == got:
            r.add("device tree", PASS, f"{len(got)} DTBs identical to stock")
        else:
            r.add("device tree", FAIL,
                  f"stock {len(want)} vs built {len(got)}; "
                  f"added={len(set(got) - set(want))} removed={len(set(want) - set(got))}")

        want_rd = load_hashes(a.stock_ramdisk)
        got_rd = hashlib.sha256(b["ramdisk"]).hexdigest()
        if not want_rd:
            r.add("ramdisk", NOTE, "no stock ramdisk baseline")
        elif got_rd == want_rd[0]:
            r.add("ramdisk", PASS, "byte-identical to stock")
        else:
            r.add("ramdisk", FAIL, "ramdisk differs from stock")

        bad = [c for c in b["cmdline"] if ord(c) < 0x20]
        if bad:
            r.add("cmdline encoding", FAIL,
                  "control characters in cmdline (params after them are ignored by the kernel)")
        else:
            r.add("cmdline encoding", PASS, "printable only, params are parseable")

        stock_cmd = ""
        for cand in ("prebuilt/boot.cmdline",):
            if os.path.exists(cand):
                stock_cmd = open(cand, encoding="utf-8").read().strip()
        if stock_cmd:
            if b["cmdline"].startswith(stock_cmd):
                extra = b["cmdline"][len(stock_cmd):].strip()
                r.add("cmdline", PASS, "stock cmdline preserved" + (f"; appended: {extra}" if extra else ""))
            else:
                r.add("cmdline", FAIL, "stock cmdline is not a prefix of the built one")

    md = r.markdown()
    if a.report:
        os.makedirs(os.path.dirname(a.report) or ".", exist_ok=True)
        open(a.report, "w", encoding="utf-8").write(md + "\n")
    print(md)
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
