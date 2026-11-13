#!/usr/bin/env python3
"""Offline dependency closure check for a payload against a target rootfs.

Asks the question the musl loader asks: for every symbol the executable
imports, is there a library on the device that exports it by that name? A
musl-linked binary carries no symbol version requirements at all, so the
"glibcxx/gcc version" class of incompatibility shows up here as a plain missing
name - which the ELF-interpreter gate cannot see.

Weak imports (nm: "w") never abort a load, so they are reported separately from
strong ones ("U"), which do: that distinction is what makes a one-symbol compat
layer provably sufficient instead of guesswork.

LD_PRELOAD'd libraries are how a closed compat layer reaches the loader: a
differently named file would never be opened, because DT_NEEDED lookup is by
name. --preload therefore takes the shim itself and adds its exports to the
set the target may bind against, which is how "these few symbols are the whole
gap" becomes a checked claim instead of a hope.

usage:
  depcheck.py PAYLOAD SYSROOT [SYSROOT ...]     # check an executable
  depcheck.py --lib LIB SYSROOT [SYSROOT ...]   # check a shared library instead
  depcheck.py PAYLOAD SYSROOT --preload LIB     # ... after a closed compat layer
  depcheck.py --lib LIB --assert-symbols A,B --max-bytes N

--assert-symbols fails unless the target exports every listed symbol; --max-bytes
fails if the target is larger than N, which is what keeps a compat library from
growing back into the multi-megabyte distro build it replaced.

Each SYSROOT is a directory holding the target's libraries, either at its root
or under lib/.  Exit status: 0 everything resolves, 1 something does not.
"""
import os
import re
import subprocess
import sys

# Supplied by the dynamic loader itself, never by a file on disk.
LOADER_SYMBOLS = {
    "__libc_stack_end", "_dl_debug_state", "__tls_get_addr", "___tls_get_addr",
    "_dl_get_tls_static_info", "__system_property_get", "__register_atfork",
    "__libc_init_secure", "__libc_preinit_impl",
}


def sh(args):
    r = subprocess.run(args, capture_output=True, text=True, check=False)
    if r.returncode != 0 and not r.stdout:
        print(f"depcheck: {args[0]} failed: {r.stderr.strip()[:200]}", file=sys.stderr)
    return r.stdout


def dt_needed(binary):
    out = sh(["readelf", "-d", binary])
    return re.findall(r"\(NEEDED\)\s+Shared library:\s+\[(.*?)\]", out)


def verneed(binary):
    """Versioned import requirements: a glibc build leaks these onto musl."""
    out = sh(["readelf", "-V", binary])
    chunk = out.split("Version needs section", 1)
    if len(chunk) < 2:
        return []
    body = chunk[1].split("\n\n", 1)[0]
    lib = None
    pairs = []
    for line in body.splitlines():
        m = re.search(r"Name:\s+(\S+)", line)
        if m:
            lib = m.group(1)
        m = re.search(r"Version:\s+\S+\s+(?:\((\d+)\))?\s*:\s+([A-Za-z0-9_.+-]+)", line)
        if m and lib:
            pairs.append((lib, m.group(2)))
    return pairs


def imports(binary):
    strong, weak = set(), set()
    for line in sh(["nm", "-D", "-u", binary]).splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[-1].split("@")[0]
        (strong if parts[-2] == "U" else weak).add(name)
    return strong, weak


def exports(binary):
    out = set()
    for line in sh(["nm", "-D", "--defined-only", binary]).splitlines():
        parts = line.split()
        if parts:
            out.add(parts[-1].split("@")[0])
    return out


def locate(libname, sysroots):
    for root in sysroots:
        for cand in (os.path.join(root, libname), os.path.join(root, "lib", libname),
                     os.path.join(root, "usr", "lib", libname)):
            if os.path.exists(cand):
                return cand
    return None


def main(argv):
    mode_lib = 0
    preloads, want_symbols = [], []
    max_bytes = None
    args, i = [], 1
    while i < len(argv):
        a = argv[i]
        if a == "--lib":
            mode_lib = 1
        elif a == "--preload":
            i += 1
            preloads.append(argv[i])
        elif a == "--assert-symbols":
            i += 1
            want_symbols += [s for s in argv[i].split(",") if s]
        elif a == "--max-bytes":
            i += 1
            max_bytes = int(argv[i])
        else:
            args.append(a)
        i += 1
    argv = [argv[0]] + args
    if len(argv) < 2:
        print(__doc__)
        return 2
    target = argv[1]
    sysroots = argv[2:] or ["."]
    for root in sysroots:
        if not os.path.isdir(root):
            print(f"depcheck: not a directory: {root}", file=sys.stderr)
            return 2
    if not os.path.isfile(target):
        print(f"depcheck: no such file: {target}", file=sys.stderr)
        return 2

    libs = dt_needed(target)
    versions = verneed(target)
    strong, weak = imports(target)
    provided = set()
    present, absent = [], []
    for libname in libs:
        path = locate(libname, sysroots)
        if path is None:
            absent.append(libname)
        else:
            present.append(f"{libname} -> {path}")
            provided |= exports(path)
    for lib in preloads:
        if not os.path.isfile(lib):
            print(f"depcheck: no such preload library: {lib}", file=sys.stderr)
            return 2
        present.append(f"{lib} (preloaded)")
        provided |= exports(lib)

    size = os.path.getsize(target)
    miss_symbols = sorted(s for s in want_symbols if s not in exports(target))
    oversized = max_bytes is not None and size > max_bytes

    miss_strong = sorted(s for s in strong if s not in provided and s not in LOADER_SYMBOLS)
    miss_weak = sorted(s for s in weak if s not in provided and s not in LOADER_SYMBOLS)

    print(f"target: {target}" + ("  (shared library)" if mode_lib else ""))
    print(f"size_bytes: {size}")
    print(f"dt_needed: {libs}")
    print(f"resolved: {len(libs) - len(absent)}/{len(libs)}")
    for line in present:
        print(f"    {line}")
    print(f"absent_libraries: {absent}")
    print(f"verneed_entries: {versions if versions else 'none (musl-style, name-only binding)'}")
    print(f"imports: strong={len(strong)} weak={len(weak)}")
    print(f"missing_strong: {len(miss_strong)}")
    for m in miss_strong:
        print(f"    WILL NOT LOAD  {m}")
    print(f"missing_weak: {len(miss_weak)} (ignored by the loader)")
    for m in miss_weak[:10]:
        print(f"    weak           {m}")
    if mode_lib:
        print(f"exports: {sorted(exports(target))}")
    if want_symbols:
        print(f"assert_symbols: {len(want_symbols)} required, {len(miss_symbols)} missing")
        for m in miss_symbols:
            print(f"    NOT EXPORTED   {m}")
    if max_bytes is not None:
        print(f"max_bytes: {max_bytes} ({'within' if not oversized else 'OVER'})")

    ok = not miss_strong and not absent and not versions
    ok = ok and not miss_symbols and not oversized
    for lib in preloads:
        if dt_needed(lib):
            print(f"verdict: REFUSED - the preload {lib} is not self-contained "
                  f"(DT_NEEDED {dt_needed(lib)})")
            return 1
    if versions:
        print("verdict: REFUSED - the binary demands versioned symbols, i.e. it is a glibc build")
    elif not ok:
        print("verdict: REFUSED - the target rootfs cannot resolve this binary")
    else:
        print("verdict: OK - every strong import resolves on this rootfs")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
