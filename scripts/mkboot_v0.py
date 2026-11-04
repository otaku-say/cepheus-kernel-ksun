#!/usr/bin/env python3
"""Build a cepheus boot.img (Android header v0) byte-compatible with the stock image.

Stock crDroid 10.14 boot.img layout (verified byte-by-byte):

    page 0             boot_img_hdr_v0, page_size 4096, header_version 0
    page 1 (4096)      kernel payload:
                         "UNCOMPRESSED_IMG" + u32 len(raw Image) + raw Image + appended DTBs
    next page          lz4-legacy ramdisk, verbatim from stock
    next page          AVB0 vbmeta block (704 B here) - stale by design, verification is off
    ...zero padding...
    last 64 B          AvbFooter struct ('AVBf') pointing at the vbmeta block

Input is the kernel build output Image.gz-dtb: gzip(Image) followed by the appended
DTBs, exactly what `make Image.gz-dtb` produces on this tree.  The gzip part is
expanded and re-wrapped with the QCOM "UNCOMPRESSED_IMG" header so the result is
structurally identical to the stock kernel payload.
"""
import argparse
import gzip
import hashlib
import os
import struct
import sys
import zlib

PAGE = 4096
QCOM_MAGIC = b"UNCOMPRESSED_IMG"
ZERO = bytes(1)


def split_gz_dtb(path):
    """(raw Image, appended DTBs) from Image.gz-dtb (or a raw Image)."""
    blob = open(path, "rb").read()
    if blob[:2] != b"\x1f\x8b":
        return blob, b""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = d.decompress(blob) + d.flush()
    return raw, d.unused_data


def build_header(kernel_size, ramdisk_size, cmdline, os_version, ids):
    cmd = cmdline.encode()[:511] + bytes(1)
    hdr = struct.pack(
        "<8s10I16s512s32s1024s",
        b"ANDROID!",
        kernel_size,
        0x00008000,      # kernel_addr
        ramdisk_size,
        0x01000000,      # ramdisk_addr
        0,               # second_size
        0,               # second_addr
        0x00000100,      # tags_addr
        PAGE,            # page_size
        0,               # header_version
        os_version,
        bytes(16),       # name
        cmd.ljust(512, bytes(1)),
        struct.pack("<8I", *ids),
        bytes(1024),     # extra_cmdline
    )
    return hdr


def pad(data, align=PAGE):
    return data + bytes((align - len(data) % align) % align)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True, help="Image.gz-dtb (or raw Image)")
    ap.add_argument("--ramdisk", required=True)
    ap.add_argument("--cmdline-file", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--pad-to", type=int, default=134217728,
                    help="pad to this size (boot partition size); 0 to skip")
    ap.add_argument("--os-version", type=lambda s: int(s, 0), default=0x1C000195)
    ap.add_argument("--no-qcom-wrapper", action="store_true")
    ap.add_argument("--avb-vbmeta", default=None,
                    help="stock AVB0 vbmeta block, placed on the page after the ramdisk")
    ap.add_argument("--no-avbf", action="store_true",
                    help="do not append the trailing AvbFooter struct")
    a = ap.parse_args()

    raw, dtb = split_gz_dtb(a.kernel)
    kblob = raw + dtb if a.no_qcom_wrapper else QCOM_MAGIC + struct.pack("<I", len(raw)) + raw + dtb
    ramdisk = open(a.ramdisk, "rb").read()
    # collapse any whitespace: the file may end with a newline before an
    # appended parameter list, and a newline inside the cmdline field is not a
    # separator for the kernel arg parser (the param would be dropped)
    cmdline = " ".join(open(a.cmdline_file, encoding="utf-8").read().split())

    # header id[]: sha1 over kernel+ramdisk with the length words, as mkbootimg does
    digest = hashlib.sha1()
    for part in (kblob, ramdisk):
        digest.update(part)
        digest.update(struct.pack("<I", len(part)))
    d = digest.digest()
    ids = struct.unpack("<8I", d + bytes(32 - len(d)))

    img = pad(build_header(len(kblob), len(ramdisk), cmdline, a.os_version, ids))
    img += pad(kblob)
    img += pad(ramdisk)

    vbmeta = b""
    if a.avb_vbmeta and os.path.exists(a.avb_vbmeta):
        vbmeta = open(a.avb_vbmeta, "rb").read()
        if vbmeta[:4] != b"AVB0":
            sys.exit("--avb-vbmeta is not an AVB0 block")
        orig_size = len(img)
        img += vbmeta
        print(f"  avb vbmeta  : {len(vbmeta)} B at {orig_size:,} (stale by design)")

    if a.pad_to:
        if vbmeta and not a.no_avbf:
            ftr = struct.pack(">4sIIQQQ28s", b"AVBf", 1, 0, orig_size, orig_size, len(vbmeta), bytes(28))
            img = img.ljust(a.pad_to - len(ftr), bytes(1)) + ftr
        else:
            img = img.ljust(a.pad_to, bytes(1))
        if len(img) > a.pad_to:
            sys.exit(f"image {len(img)} exceeds partition size {a.pad_to}")

    open(a.out, "wb").write(img)
    print(f"  kernel blob : {len(kblob):,} B (raw image {len(raw):,} + dtb {len(dtb):,})")
    print(f"  ramdisk     : {len(ramdisk):,} B")
    print(f"  cmdline     : {cmdline[:96]}{'...' if len(cmdline) > 96 else ''}")
    print(f"  boot.img    : {len(img):,} B -> {a.out}")


if __name__ == "__main__":
    main()
