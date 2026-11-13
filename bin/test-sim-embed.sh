#!/usr/bin/env bash
# Embed-mode counterpart to bin/test-sim.sh.
#
# An embed package ships the payload inside the ipk and runs it from
# /usr/libexec/<pkg>/payload/, so data_dir plays no part. That distinction used
# to be lost in fetch-payload.sh, which resolved every path through data_dir and
# so reported "no payload" for an embed install that was perfectly intact.
#
# Nothing here needs uci or a network: the checks are about where the scripts
# look.  The payload is a musl binary and this host has no musl loader, so a
# loader-level failure is the expected, asserted outcome.
#
# usage: bin/test-sim-embed.sh [IPK]   # default: newest embed ipk in dist/embed/
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
PASS=0; FAIL=0
ok()  { echo "  ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
note(){ echo "== $*"; }

if command -v busybox >/dev/null 2>&1; then
    ASHER="busybox sh"
elif command -v dash >/dev/null 2>&1; then
    ASHER=dash
else
    ASHER=$(command -v sh)
fi
run() { $ASHER "$@"; }

IPK=${1:-$(ls -1t "$ROOT"/dist/embed/*.ipk 2>/dev/null | head -1)}
if [ ! -f "${IPK:-}" ]; then
    echo "test-sim-embed: need an embed ipk; run" >&2
    echo "  bin/build.sh --variant qoder --arch x86_64 --mode embed   # -> dist/embed/" >&2
    exit 1
fi

FAKE=$(mktemp -d "$ROOT/work/semb.XXXXXX")
trap 'rm -rf "$FAKE"' EXIT
tar xzf "$IPK" -C "$FAKE"
tar xzf "$FAKE/data.tar.gz" -C "$FAKE"
rm -f "$FAKE"/debian-binary "$FAKE"/data.tar.gz "$FAKE"/control.tar.gz

BIN=$(tar xf "$IPK" -O ./control.tar.gz | tar xzO ./control | sed -n 's/^Package: //p' | head -1)
[ -n "$BIN" ] || { echo "test-sim-embed: cannot read Package from $IPK" >&2; exit 1; }
note "package under test: $BIN ($(basename "$IPK"))"

# Only path constants move; the logic stays byte-identical. /usr/libexec carries
# both the scripts and the embedded payload, so this covers PAYLOAD_PATH too.
find "$FAKE" -type f -print0 | while IFS= read -r -d '' f; do
    sed -i -e "s|/usr/libexec/$BIN|$FAKE/usr/libexec/$BIN|g" \
           -e "s|/usr/bin/$BIN|$FAKE/usr/bin/$BIN|g" \
           -e "s|/etc/$BIN-rc|$FAKE/etc/$BIN-rc|g" "$f"
done
chmod -R u+rwX "$FAKE"

ENV=$FAKE/usr/libexec/$BIN/payload.env
FETCH=$FAKE/usr/libexec/$BIN/fetch-payload.sh
ARCH=$(sed -n 's/^PAYLOAD_ARCH=//p' "$ENV")
MODE=$(sed -n 's/^PAYLOAD_MODE=//p' "$ENV")
PAYLOAD=$(sed -n 's/^PAYLOAD_PATH=//p' "$ENV")

if [ "$MODE" != embed ]; then
    echo "test-sim-embed: $IPK has PAYLOAD_MODE=$MODE, not embed" >&2
    exit 1
fi
[ -x "$PAYLOAD" ] || bad "embedded payload missing after unpack: $PAYLOAD"

# ---------------------------------------------------------------------------
note "1. --verify looks at the payload that ships in the package"
out=$(run "$FETCH" --verify 2>&1); code=$?
if echo "$out" | grep -q "no payload at"; then
    bad "verify used data_dir instead of PAYLOAD_PATH: $out"
elif [ "$code" = 0 ] || [ "$code" = 4 ]; then
    ok "verify reached the embedded payload (exit $code): $(echo "$out" | sed -n '1p')"
else
    bad "unexpected verify exit $code: $out"
fi

note "2. a replaced embedded payload is still detected"
cp "$PAYLOAD" "$FAKE/intact"
printf 'tampered' >> "$PAYLOAD"
out=$(run "$FETCH" --verify 2>&1); code=$?
if [ "$code" = 1 ] && echo "$out" | grep -qi "does not match"; then
    ok "tamper detected"
else
    bad "tamper NOT detected (code=$code): $out"
fi
cp "$FAKE/intact" "$PAYLOAD"; chmod 0755 "$PAYLOAD"; rm -f "$FAKE/intact"

note "3. the wrapper executes the embedded payload, not a data_dir copy"
out=$(run "$FAKE/usr/bin/$BIN" --version 2>&1)
if echo "$out" | grep -q "payload not installed"; then
    bad "wrapper looked outside PAYLOAD_PATH: $out"
elif echo "$out" | grep -qiE "ld-musl|not found|cannot execute|Exec format"; then
    ok "exec reached the ELF loader of the embedded binary"
else
    bad "unexpected wrapper output: $out"
fi

note "4. ELF gate on the payload that actually shipped"
if python3 "$ROOT/lib/elfcheck.py" "$PAYLOAD" "$ARCH" musl >/dev/null 2>&1; then
    ok "elfcheck accepted the embedded $ARCH musl payload"
else
    bad "elfcheck rejected the embedded payload"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
