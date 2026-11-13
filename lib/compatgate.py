#!/usr/bin/env python3
"""Gate for the closed compat layer before it is shipped inside an ipk.

The compat library exists because one musl loader error - "symbol not found" -
makes an otherwise perfectly valid payload unrunnable on rootfses whose
libstdc++ predates the symbol. Shipping a stub is only correct while four
things stay true, and this script refuses the build the moment any of them
stops being:

  1. the stub is self-contained: no PT_INTERP, no DT_NEEDED, nothing to load
  2. it exports exactly COMPAT_SYMBOLS - no more (dead weight, and a stub for a
     symbol the device already implements would shadow the real one), no less
  3. the payload really imports those symbols, otherwise the stub is useless
  4. it stays tiny, because the distro libstdc++ it replaces is megabytes

usage: compatgate.py SHIM PAYLOAD ARCH SHA256 SYMBOLS[,SYMBOLS] MAX_BYTES
exit: 0 acceptable, 1 refuse the package
"""
import hashlib
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import depcheck  # noqa: E402
import elfcheck  # noqa: E402

def sh(args):
    return subprocess.run(args, capture_output=True, text=True, check=False).stdout


def main(argv):
    if len(argv) < 7:
        print(__doc__)
        return 2
    shim, payload, arch, want_sha, want_syms, max_bytes = argv[1:7]
    max_bytes = int(max_bytes)
    symbols = [s for s in want_syms.split(",") if s]
    problems = []

    if not os.path.isfile(shim):
        print(f"compatgate: no such shim: {shim}", file=sys.stderr)
        return 1
    if not symbols:
        problems.append("COMPAT_SYMBOLS is empty - a compat layer with no symbols is a bug")

    try:
        e_machine, interp = elfcheck.read_elf(shim)
    except (OSError, ValueError, struct.error) as err:
        problems.append(f"shim is not a readable ELF: {err}")
        e_machine = None
        interp = None
    got_arch, _alias = elfcheck.EMachine.get(e_machine, (f"unknown-0x{e_machine:x}", ""))
    if interp is not None:
        problems.append(f"shim has PT_INTERP {interp!r}: it must load nothing")
    if got_arch != arch:
        problems.append(f"shim is {got_arch}, payload arch is {arch}")
    if sh(["readelf", "-d", shim]).count("(NEEDED)") > 0:
        problems.append(f"shim has DT_NEEDED entries: {depcheck.dt_needed(shim)}")

    size = os.path.getsize(shim)
    if size > max_bytes:
        problems.append(f"shim is {size} bytes, cap is {max_bytes} - a compat layer "
                        f"must not grow back into the distro library it replaces")
    sha = hashlib.sha256(open(shim, "rb").read()).hexdigest()
    if sha != want_sha:
        problems.append(f"shim sha256 {sha[:16]}... != etc/compat.conf {want_sha[:16]}...")

    exported = depcheck.exports(shim)
    for extra in sorted(exported - set(symbols)):
        problems.append(f"shim exports {extra}, which COMPAT_SYMBOLS does not cover")
    for missing in sorted(set(symbols) - exported):
        problems.append(f"shim does not export {missing}")

    imported, _weak = depcheck.imports(payload)
    for sym in sorted(set(symbols) - imported):
        problems.append(f"{os.path.basename(payload)} does not import {sym}: "
                        f"the stub is dead weight in this package")

    for p in problems:
        print(f"   REFUSED: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"   compat gate passed: {arch} shim, {size} bytes, "
          f"exports exactly {len(symbols)} symbol(s) the payload imports")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
