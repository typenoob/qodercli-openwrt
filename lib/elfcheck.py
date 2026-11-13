#!/usr/bin/env python3
"""Read an ELF file's machine type and PT_INTERP, and decide whether it can run
under a musl-only OpenWrt rootfs.

Exit 0 when the (arch, libc) pair matches what the caller expects, non-zero with
a reason otherwise. This is the gate that replaces the "strip newer gcc symbols"
idea: runnability on OpenWrt is decided by the ELF interpreter, not by symbol
versions.
"""
import json
import struct
import sys

EMachine = {
    0x03: ("x86", "386"),
    0x28: ("arm", "armv7"),
    0x3e: ("x86_64", "amd64"),
    0x8: ("mips", "mips"),
    0xa: ("mips", "mipsel"),
    0xb7: ("arm64", "aarch64"),
    0xf3: ("riscv64", "riscv64"),
    0xc0: ("arc", "arc"),
}


def read_elf(path):
    with open(path, "rb") as fh:
        head = fh.read(64)
    if head[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    ei_class, ei_data = head[4], head[5]
    if ei_class not in (1, 2):
        raise ValueError(f"unexpected ELF class {ei_class}")
    endian = "<" if ei_data == 1 else ">"

    if ei_class == 2:
        e_machine, = struct.unpack_from(endian + "H", head, 18)
        e_phoff, = struct.unpack_from(endian + "Q", head, 32)
        e_phentsize, e_phnum = struct.unpack_from(endian + "HH", head, 54)
        off_at, size_at, fmt = 8, 32, "Q"
    else:
        e_machine, = struct.unpack_from(endian + "H", head, 18)
        e_phoff, = struct.unpack_from(endian + "I", head, 28)
        e_phentsize, e_phnum = struct.unpack_from(endian + "HH", head, 42)
        off_at, size_at, fmt = 4, 16, "I"

    with open(path, "rb") as fh:
        fh.seek(e_phoff)
        table = fh.read(e_phentsize * e_phnum)
        for i in range(e_phnum):
            ph = table[i * e_phentsize:(i + 1) * e_phentsize]
            if struct.unpack_from(endian + "I", ph, 0)[0] != 3:  # PT_INTERP
                continue
            p_off, = struct.unpack_from(endian + fmt, ph, off_at)
            p_filesz, = struct.unpack_from(endian + fmt, ph, size_at)
            fh.seek(p_off)
            return e_machine, fh.read(p_filesz).rstrip(b"\0").decode("utf-8", "replace")
    return e_machine, None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path, want_arch = argv[1], (argv[2] if len(argv) > 2 else None)
    want_libc = argv[3] if len(argv) > 3 else "musl"

    try:
        e_machine, interp = read_elf(path)
    except (OSError, ValueError, struct.error) as err:
        print(json.dumps({"file": path, "error": str(err)}))
        return 2

    arch, arch_alias = EMachine.get(e_machine, (f"unknown-0x{e_machine:x}",) * 2)
    if interp is None:
        libc = "static"
    elif "musl" in interp:
        libc = "musl"
    elif "ld-linux" in interp or "ld.so" in interp:
        libc = "glibc"
    else:
        libc = "unknown"

    problems = []
    if want_arch and arch not in (want_arch, arch_alias) and libc != "static":
        problems.append(f"e_machine says {arch}, expected {want_arch}")
    if want_libc and libc != want_libc:
        problems.append(f"libc is {libc}, expected {want_libc}")
    if libc == "glibc":
        problems.append(
            "this is a glibc build: the loader it asks for does not exist on a stock "
            "musl OpenWrt rootfs, so execve fails with 'not found' regardless of symbol versions"
        )

    print(json.dumps({
        "file": path,
        "arch": arch,
        "arch_alias": arch_alias,
        "interp": interp,
        "libc": libc,
        "problems": problems,
    }, indent=2))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
