#!/usr/bin/env python3
"""Pack a staging directory into a deterministic tar (gzip or xz) the way
opkg-build does it: ./-prefixed members, root:root ownership, sorted traversal,
fixed mtime, and a gzip header with mtime=0 so two runs of the same input
produce the same bytes.

usage: mktar.py OUTPUT.tar.gz STAGEDIR [--gzip|--xz|--no-compress] [--mtime EPOCH]
                          [--no-dirs]   omit directory entries (outer ipk layer)
"""
import gzip
import lzma
import os
import sys
import tarfile


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    out, root = argv[1], argv[2]
    rest = argv[3:]
    comp = "xz" if out.endswith(".xz") else "gz"
    if "--gzip" in rest:
        comp = "gz"
    if "--xz" in rest:
        comp = "xz"
    if "--no-compress" in rest:
        comp = "none"
    no_dirs = "--no-dirs" in rest
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    if "--mtime" in rest:
        mtime = int(rest[rest.index("--mtime") + 1])

    if not os.path.isdir(root):
        print(f"mktar.py: no such directory: {root}", file=sys.stderr)
        return 1

    plain = out + ".plain"
    with tarfile.open(plain, "w", format=tarfile.GNU_FORMAT) as tf:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            rel = os.path.relpath(dirpath, root)
            prefix = "." if rel == "." else "./" + rel
            if not no_dirs:
                _add(tf, dirpath, prefix + "/", mtime)
            for name in sorted(filenames):
                _add(tf, os.path.join(dirpath, name), prefix + "/" + name, mtime)

    with open(plain, "rb") as src:
        if comp == "gz":
            with gzip.GzipFile(out, "wb", compresslevel=9, mtime=0) as dst:
                _copy(src, dst)
        elif comp == "xz":
            with lzma.open(out, "wb", preset=6) as dst:
                _copy(src, dst)
        else:
            with open(out, "wb") as dst:
                _copy(src, dst)
    os.unlink(plain)
    print(out)
    return 0


def _copy(src, dst, chunk=1024 * 1024):
    while True:
        buf = src.read(chunk)
        if not buf:
            return
        dst.write(buf)


def _add(tf, src, arc, mtime):
    ti = tf.gettarinfo(src, arcname=arc)
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = mtime
    if ti.isreg():
        with open(src, "rb") as fh:
            tf.addfile(ti, fh)
    else:
        tf.addfile(ti)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
