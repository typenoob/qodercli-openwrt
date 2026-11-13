#!/usr/bin/env python3
"""Generate an opkg feed index (Packages, Packages.gz) from ipk files.

The layout mirrors what OpenWrt itself publishes: the control fields verbatim,
then Filename/Size/SHA256sum immediately before the Description paragraph, and
an empty line between entries.

usage: index.py DIST_DIR [IPK ...]

With no explicit files every *.ipk currently in DIST_DIR is indexed, because
an opkg feed serves the whole directory - an index that describes only the
last build would hide the rest of the feed.
"""
import gzip
import hashlib
import io
import os
import sys
import tarfile


def read_control(ipk_path):
    with tarfile.open(ipk_path, "r:*") as outer:
        member = next((m for m in outer.getmembers() if m.name.endswith("control.tar.gz")), None)
        if member is None:
            raise ValueError(f"{ipk_path}: no control.tar.gz member")
        blob = outer.extractfile(member).read()
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as ctl:
        target = next((m for m in ctl.getmembers() if os.path.basename(m.name) == "control"), None)
        if target is None:
            raise ValueError(f"{ipk_path}: no control member inside control.tar.gz")
        return ctl.extractfile(target).read().decode("utf-8", "replace")


def field(block, name):
    for line in block.splitlines():
        if line.startswith(name + ":"):
            return line.split(":", 1)[1].strip()
    return None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    dist = argv[1]
    ipks = argv[2:]
    if not ipks:
        ipks = [os.path.join(dist, p) for p in sorted(os.listdir(dist))
                if p.endswith(".ipk")]
    entries = []

    for ipk in sorted(ipks):
        if not os.path.isfile(ipk):
            print(f"index.py: skipping missing file {ipk}", file=sys.stderr)
            continue
        control = read_control(ipk)
        name = field(control, "Package")
        arch = field(control, "Architecture")
        if not name or not arch:
            print(f"index.py: {ipk}: control lacks Package or Architecture", file=sys.stderr)
            continue
        with open(ipk, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        size = os.path.getsize(ipk)

        # Re-emit the control block, injecting Filename/Size/SHA256sum ahead of
        # Description the way the official indexes do.
        lines = control.rstrip("\n").splitlines()
        out, injected = [], False
        for line in lines:
            if line.startswith("Description:") and not injected:
                out.append(f"Filename: {os.path.basename(ipk)}")
                out.append(f"Size: {size}")
                out.append(f"SHA256sum: {digest}")
                injected = True
            out.append(line)
        entries.append("\n".join(out))

    entries.sort(key=lambda e: (field(e, "Package") or "", field(e, "Architecture") or ""))
    text = "\n\n".join(entries) + ("\n" if entries else "")

    plain = os.path.join(dist, "Packages")
    with open(plain, "w", encoding="utf-8") as fh:
        fh.write(text)
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0")) or None
    with gzip.GzipFile(os.path.join(dist, "Packages.gz"), "wb", compresslevel=9, mtime=epoch) as gz:
        gz.write(text.encode("utf-8"))
    print(f"{plain} ({len(entries)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
