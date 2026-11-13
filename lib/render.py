#!/usr/bin/env python3
"""Literal %%KEY%% substitution, so packager templates can contain shell
expansions and quoting that sed would otherwise mangle (&, backslashes, regex
metacharacters, or a bare `$@`).

usage: render.py TEMPLATE OUTPUT KEY=VALUE [KEY=VALUE ...]
"""
import re
import sys

PLACEHOLDER = re.compile(r"%%([A-Za-z_][A-Za-z0-9_]*)%%")


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    template, output, assignments = argv[1], argv[2], argv[3:]
    subs = {}
    for item in assignments:
        if "=" not in item:
            print(f"render.py: not a KEY=VALUE pair: {item}", file=sys.stderr)
            return 2
        key, value = item.split("=", 1)
        subs[key] = value

    with open(template, encoding="utf-8") as fh:
        text = fh.read()

    missing = sorted({tok for tok in PLACEHOLDER.findall(text) if tok not in subs})
    if missing:
        print(f"render.py: {template}: unfilled placeholders: {', '.join(missing)}", file=sys.stderr)
        return 1

    rendered = PLACEHOLDER.sub(lambda m: subs[m.group(1)], text)
    with open(output, "w", encoding="utf-8") as fh:
        fh.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
