#!/usr/bin/env python3
"""Validate built ipks without needing a router.

Checks, per package:
  * container layout matches what OpenWrt itself publishes (gzip tar with
    ./debian-binary, ./control.tar.gz, ./data.tar.gz, no doubled slashes)
  * control has the fields opkg needs and an opkg-parseable Version
  * every conffiles path actually ships in data.tar
  * every installed shell script passes `busybox sh -n` (falling back to dash),
    which is the shell that runs on the device
  * embed mode: the packed binary's sha256 matches payload.env and it passes the
    same ELF gate the build used
  * the Packages feed index agrees with the files on disk

usage: verify.py DIST_DIR [IPK ...]        # default: every *.ipk in DIST_DIR
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTROL_REQUIRED = ("Package", "Version", "Architecture", "Installed-Size", "Description")
MEMBERS = ("./debian-binary", "./control.tar.gz", "./data.tar.gz")
VERSION_RE = re.compile(r"^\d:[0-9A-Za-z][0-9A-Za-z.+-]*$|^\d[0-9A-Za-z.+-]*$")


class Syntax:
    """Syntax-check shell snippets with the interpreter the device would use."""

    def __init__(self):
        self.counter = 0
        if shutil.which("busybox"):
            self.argv = ["busybox", "sh"]
        elif shutil.which("dash"):
            self.argv = ["dash"]
        else:
            self.argv = [shutil.which("sh") or "/bin/sh"]

    def check(self, text, name):
        path = f"/tmp/qi-syntax-{os.getpid()}-{self.counter}.sh"
        self.counter += 1
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        try:
            proc = subprocess.run(self.argv + ["-n", path], capture_output=True, text=True)
        finally:
            os.unlink(path)
        if proc.returncode != 0:
            raise AssertionError(f"{name}: {' '.join(self.argv)} -n failed: {proc.stderr.strip()}")


def parse_control(text):
    fields, key = {}, None
    for line in text.splitlines():
        if not line:
            continue
        if line[0] not in " \t" and ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
        elif key:
            fields[key] += "\n" + line
    return fields


def read_member(archive, suffix):
    for member in archive.getmembers():
        if member.name.endswith(suffix) and member.isfile():
            return archive.extractfile(member).read()
    return None


def env_from(text):
    env = {}
    for line in (text or b"").decode("utf-8", "replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    return env


def normalize(name):
    """tarfile strips the trailing slash off directory entries on read, so "."
    and "./etc" are what a `tar tf` listing would print as "./" and "./etc/"."""
    return "./" if name in (".", "./") else name


def verify_ipk(ipk, syntax):
    problems, info = [], {}

    with tarfile.open(ipk, "r:*") as outer:
        names = [normalize(m.name) for m in outer.getmembers()]
        if sorted(names) != sorted(MEMBERS):
            return [f"container members are {names}, expected {list(MEMBERS)}"], {}
        if any("//" in n for n in names):
            problems.append(f"member paths contain a doubled slash: {names}")
        if (read_member(outer, "debian-binary") or b"").strip() != b"2.0":
            problems.append("debian-binary is not '2.0'")
        control_blob = read_member(outer, "control.tar.gz")
        data_blob = read_member(outer, "data.tar.gz")

    with tarfile.open(fileobj=io.BytesIO(control_blob), mode="r:*") as tf:
        control_text = (read_member(tf, "control") or b"").decode("utf-8")
        conffiles = [p for p in (read_member(tf, "conffiles") or b"").decode("utf-8").splitlines() if p]
        for suffix in ("postinst", "prerm"):
            body = read_member(tf, suffix)
            if body is None:
                problems.append(f"control.tar.gz: no {suffix}")
                continue
            try:
                syntax.check(body.decode("utf-8", "replace"), f"control.tar:{suffix}")
            except AssertionError as err:
                problems.append(str(err))

    fields = parse_control(control_text)
    for key in CONTROL_REQUIRED:
        if key not in fields:
            problems.append(f"control: missing {key}")
    if "Package" not in fields:
        return problems, info
    if fields.get("Version") and not VERSION_RE.match(fields["Version"]):
        problems.append(f"control: Version {fields['Version']!r} is not opkg-parseable")
    stem = os.path.basename(ipk)[: -len(".ipk")]
    parts = stem.split("_", 2)
    if len(parts) == 3 and fields.get("Architecture") != parts[2]:
        problems.append(f"control: Architecture {fields.get('Architecture')!r} "
                        f"does not match the file name {os.path.basename(ipk)}")

    binary = fields["Package"]
    with tarfile.open(fileobj=io.BytesIO(data_blob), mode="r:*") as tf:
        data_names = [normalize(m.name) for m in tf.getmembers()]
        for expect in (
            f"./usr/bin/{binary}",
            f"./etc/init.d/{binary}-rc",
            f"./etc/config/{binary}-rc",
            f"./usr/libexec/{binary}/payload.env",
            f"./usr/libexec/{binary}/fetch-payload.sh",
            f"./usr/libexec/{binary}/run-daemon.sh",
        ):
            if expect not in data_names:
                problems.append(f"data.tar: missing {expect}")

        env = env_from(read_member(tf, "payload.env"))
        info = env

        for path in conffiles:
            if "." + path not in data_names:
                problems.append(f"conffiles: {path} is not present in data.tar")

        installed_scripts = {
            f"./etc/init.d/{binary}-rc",
            f"./usr/bin/{binary}",
            f"./usr/libexec/{binary}/fetch-payload.sh",
            f"./usr/libexec/{binary}/run-daemon.sh",
        }
        for member in tf.getmembers():
            if not member.isfile():
                continue
            name = normalize(member.name)
            if name not in installed_scripts:
                continue
            body = tf.extractfile(member).read().decode("utf-8", "replace")
            if not body.startswith("#!"):
                problems.append(f"{name}: no shebang")
                continue
            # The procd init script shebang names rc.common, which -n would try
            # to execute as an interpreter; check the body only.
            head, _, rest = body.partition("\n")
            if not head.startswith("#!/bin/sh"):
                problems.append(f"{name}: unexpected shebang {head!r}")
            try:
                syntax.check(rest, f"data.tar:{name}")
            except AssertionError as err:
                problems.append(str(err))

        if env.get("PAYLOAD_MODE") == "embed":
            blob = read_member(tf, f"/payload/{binary}")
            if blob is None:
                problems.append("PAYLOAD_MODE=embed but data.tar has no payload binary")
            else:
                digest = hashlib.sha256(blob).hexdigest()
                if digest != env.get("BINARY_SHA256"):
                    problems.append(f"embedded payload sha256 {digest} != payload.env {env.get('BINARY_SHA256')}")
                probe = f"/tmp/qi-probe-{os.getpid()}-{binary}"
                with open(probe, "wb") as fh:
                    fh.write(blob)
                libc = "musl" if "musl" in env.get("EXPECTED_INTERP", "musl") else "glibc"
                proc = subprocess.run(
                    [sys.executable, os.path.join(ROOT, "lib", "elfcheck.py"), probe,
                     env.get("PAYLOAD_ARCH", ""), libc],
                    capture_output=True, text=True)
                os.unlink(probe)
                if proc.returncode != 0:
                    problems.append("embedded payload failed the ELF gate: " + proc.stderr.strip())
    return problems, info


def verify_index(dist, ipks):
    path = os.path.join(dist, "Packages")
    if not os.path.isfile(path):
        return ["no Packages index in the dist directory (lib/index.py did not run)"]
    blocks = {}
    for block in open(path, encoding="utf-8").read().split("\n\n"):
        fields = parse_control(block)
        if "Filename" in fields:
            blocks[fields["Filename"]] = fields
    problems = []
    for ipk in ipks:
        name = os.path.basename(ipk)
        entry = blocks.get(name)
        if entry is None:
            problems.append(f"index: {name} is missing from Packages")
            continue
        digest = hashlib.sha256(open(ipk, "rb").read()).hexdigest()
        if entry.get("SHA256sum") != digest:
            problems.append(f"index: {name} SHA256sum is {entry.get('SHA256sum')}, file is {digest}")
        if entry.get("Size") and entry["Size"] != str(os.path.getsize(ipk)):
            problems.append(f"index: {name} Size is {entry.get('Size')}, file is {os.path.getsize(ipk)}")
    return problems


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    dist = argv[1]
    ipks = argv[2:] or sorted(os.path.join(dist, n) for n in os.listdir(dist) if n.endswith(".ipk"))
    if not ipks:
        print(f"verify.py: no ipk files in {dist}", file=sys.stderr)
        return 1

    syntax = Syntax()
    print(f"# syntax checker: {' '.join(syntax.argv)} -n")
    bad = 0
    for ipk in ipks:
        problems, env = verify_ipk(ipk, syntax)
        if problems:
            bad += 1
            print(f"FAIL {os.path.basename(ipk)}")
            for problem in problems:
                print(f"     - {problem}")
        else:
            print(f"ok   {os.path.basename(ipk)}  "
                  f"mode={env.get('PAYLOAD_MODE', '?')} arch={env.get('IPK_ARCH', '?')} "
                  f"cli={env.get('CLI_VERSION', '?')} payload={env.get('PAYLOAD_ARCH', '?')}")

    index_problems = verify_index(dist, ipks)
    for problem in index_problems:
        print(f"FAIL {problem}")
    bad += 1 if index_problems else 0

    if bad:
        print(f"\n{bad} package(s)/check(s) failed")
        return 1
    print(f"\nall {len(ipks)} packages clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
