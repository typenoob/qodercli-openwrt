#!/usr/bin/env python3
"""Read a Qoder CLI release manifest.

usage:
  manifest.py MANIFEST.json ARCH_TOKEN [OS]   -> shell assignments
  manifest.py MANIFEST.json --list            -> one "os arch filename" per line

ARCH_TOKEN examples: amd64-musl, arm64-musl, amd64
"""
import json
import shlex
import sys


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    data = load(argv[1])
    files = data.get("files", [])

    if argv[2] == "--list":
        for f in files:
            print(f"{f.get('os')} {f.get('arch')} {f.get('url', '').rsplit('/', 1)[-1]}")
        print(f"# latest={data.get('latest')} published_at={data.get('published_at')}", file=sys.stderr)
        return 0

    token, wanted_os = argv[2], (argv[3] if len(argv) > 3 else "linux")
    matches = [f for f in files if f.get("os") == wanted_os and f.get("arch") == token]
    if not matches:
        have = ", ".join(f"{f.get('os')}/{f.get('arch')}" for f in files)
        print(f"manifest.py: no {wanted_os}/{token} entry in this channel; it offers: {have}", file=sys.stderr)
        return 1

    entry = matches[0]
    url = entry.get("url") or ""
    sha = entry.get("sha256") or ""
    if not url or not sha:
        print("manifest.py: entry is missing url or sha256", file=sys.stderr)
        return 1

    print(f"VERSION={shlex.quote(data.get('latest') or '')}")
    print(f"PUBLISHED_AT={shlex.quote(data.get('published_at') or '')}")
    print(f"URL={shlex.quote(url)}")
    print(f"SHA256={shlex.quote(sha)}")
    print(f"FILE={shlex.quote(url.rsplit('/', 1)[-1])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
