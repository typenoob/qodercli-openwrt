#!/usr/bin/env bash
# Behavioural test for the on-device scripts, run under busybox ash (the shell
# OpenWrt actually gives you) inside a fake root. No router needed.
#
# What it can prove on a glibc build host:
#   * the stub resolves the payload path and hands off to exec (the exec itself
#     must fail, because a musl loader is not present here - that failure is the
#     assertion, and it is the same one a mis-picked glibc build would produce)
#   * checksum verification, extraction, the space gate, and --verify
#   * argument and environment construction of the daemon launcher
#
# usage: bin/test-sim.sh [IPK]        # default: newest qodercli x86_64 stub ipk
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source "$ROOT/etc/variants.conf"

PASS=0
FAIL=0
ok() { echo "  ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
note() { echo "== $*"; }

ASHER="busybox sh"
if ! command -v busybox >/dev/null 2>&1; then
    ASHER="dash"
    echo "test-sim: busybox not found, falling back to $ASHER" >&2
fi

IPK=${1:-}
if [ -z "$IPK" ]; then
    IPK=$(ls -1t "$ROOT"/dist/qodercli_*_x86_64.ipk 2>/dev/null | head -1)
fi
if [ -z "$IPK" ] || [ ! -f "$IPK" ]; then
    echo "test-sim: need a qodercli x86_64 stub ipk; run bin/build.sh --variant qoder --arch x86_64" >&2
    exit 1
fi

# The payload this test installs must match the ipk's baked hashes.
tar xf "$IPK" -O ./control.tar.gz > /tmp/sim-ctl-$$.tar.gz 2>/dev/null || tar xf "$IPK" -O control.tar.gz > /tmp/sim-ctl-$$.tar.gz
rm -rf /tmp/sim-ctl-$$ && mkdir -p /tmp/sim-ctl-$$
tar xzf /tmp/sim-ctl-$$.tar.gz -C /tmp/sim-ctl-$$
BIN=$(sed -n 's/^Package: //p' /tmp/sim-ctl-$$/control | head -1)
rm -rf /tmp/sim-ctl-$$ /tmp/sim-ctl-$$.tar.gz
note "package under test: $BIN  ($(basename "$IPK"))"

PAYLOAD_TARBALL=$(ls -1 "$ROOT"/work/cache/${BIN}-linux-x64-musl.tar.gz 2>/dev/null | head -1)
if [ -z "$PAYLOAD_TARBALL" ]; then
    echo "test-sim: $ROOT/work/cache/${BIN}-linux-x64-musl.tar.gz is missing (build.sh downloads it)" >&2
    exit 1
fi

# On real storage, not under /tmp: /tmp is tmpfs on the build host too, and the
# storage gate would (correctly) refuse to install there - see group 8.
mkdir -p "$ROOT/work"
FAKE=$(mktemp -d "$ROOT/work/sim.XXXXXX")
trap 'rm -rf "$FAKE"' EXIT
DATA=$FAKE/data
LOG=$FAKE/out.log

tar xzf "$IPK" -C "$FAKE"
tar xzf "$FAKE/data.tar.gz" -C "$FAKE"
rm -f "$FAKE"/debian-binary "$FAKE"/data.tar.gz "$FAKE"/control.tar.gz
mkdir -p "$DATA"

# Re-point the installed tree at the fake root. Only path constants move; the
# logic under test stays byte-identical.
find "$FAKE" -type f | while read -r f; do
    sed -i \
        -e "s|/usr/libexec/$BIN|$FAKE/usr/libexec/$BIN|g" \
        -e "s|/usr/bin/$BIN|$FAKE/usr/bin/$BIN|g" \
        -e "s|/etc/$BIN-rc|$FAKE/etc/$BIN-rc|g" \
        "$f"
done
chmod -R u+rwX "$FAKE"

# Point the package's own uci file at the fake root, the way an operator would
# with `uci set`, and give the box a `uci` that can read it. Without this the
# scripts silently fall back to their compiled-in defaults and the uci code
# path - the one real devices actually take - goes untested.
CFG=$FAKE/etc/config/$BIN-rc
sed -i \
    -e "s|option home '/root'|option home '$FAKE'|" \
    -e "s|option directory '/root'|option directory '$FAKE'|" \
    -e "s|option data_dir '[^']*'|option data_dir '$DATA'|" \
    "$CFG"

mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/uci" <<'UCISHIM'
#!/bin/sh
# Minimal stand-in for `uci -q get <pkg>.<section>.<option>`, reading the
# config file named by $FAKE_UCI_CONFIG. Test fixture, not shipped.
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    *.config.*) key=${last##*.} ;;
    *) exit 1 ;;
esac
[ -f "$FAKE_UCI_CONFIG" ] || exit 1
v=$(sed -n "s/^[[:space:]]*option[[:space:]]\{1,\}$key[[:space:]]\{1,\}//p" \
    "$FAKE_UCI_CONFIG" | tail -1 | tr -d "'\"")
[ -n "$v" ] || exit 1
printf '%s\n' "$v"
UCISHIM
chmod 0755 "$FAKE/bin/uci"
export FAKE_UCI_CONFIG=$CFG
PATH=$FAKE/bin:$PATH
export PATH

run() { $ASHER "$@"; }

# ---------------------------------------------------------------------------
note "1. stub before the payload exists"
out=$(run "$FAKE/usr/bin/$BIN" --version 2>&1); code=$?
echo "$out" | grep -q "payload not installed" && [ "$code" = 127 ] \
    && ok "exit 127 with fetch hint: $(echo "$out" | tail -1)" \
    || bad "expected 'payload not installed'/127, got code=$code: $out"

# ---------------------------------------------------------------------------
note "2. fetch-payload.sh --from the official tarball, into $DATA"
out=$(run "$FAKE/usr/libexec/$BIN/fetch-payload.sh" --from "$PAYLOAD_TARBALL" --dir "$DATA" 2>&1); code=$?
printf '%s\n' "$out" >> "$LOG"
if [ "$code" = 0 ] && [ -x "$DATA/$BIN" ]; then
    ok "checksum verified, payload installed ($(stat -c %s "$DATA/$BIN") bytes)"
else
    bad "install path failed (code=$code): $out"
fi
echo "$out" | grep -q "ld-musl-x86_64.so.1" \
    && ok "musl loader guard fired (this host has no /lib/ld-musl-x86_64.so.1)" \
    || bad "loader guard did not mention the missing musl interpreter"

# ---------------------------------------------------------------------------
note "3. --verify agrees with the hashes baked at build time"
out=$(run "$FAKE/usr/libexec/$BIN/fetch-payload.sh" --dir "$DATA" --verify 2>&1); code=$?
# This host has no musl loader, so the expected verdict is 4 (payload intact,
# rootfs cannot run it) - never 1, which would mean the shipped hash is wrong.
[ "$code" = 1 ] && bad "verify rejected the payload hash it installed itself: $out"
if [ "$code" = 0 ]; then
    ok "verify clean: $(echo "$out" | sed -n '1p')"
elif [ "$code" = 4 ]; then
    ok "verify clean apart from the absent loader on this host: $(echo "$out" | sed -n '1p')"
else
    bad "unexpected verify exit $code: $out"
fi

# ---------------------------------------------------------------------------
note "4. corrupt payload is detected"
cp "$DATA/$BIN" "$FAKE/keep"
printf 'tampered' >> "$DATA/$BIN"
out=$(run "$FAKE/usr/libexec/$BIN/fetch-payload.sh" --dir "$DATA" --verify 2>&1); code=$?
[ "$code" != 0 ] && echo "$out" | grep -qi "does not match" \
    && ok "tamper detected: $(echo "$out" | sed -n '1p')" || bad "tamper NOT detected"
mv "$FAKE/keep" "$DATA/$BIN"

# ---------------------------------------------------------------------------
note "5. stub hands off to the payload (exec must reach the loader)"
out=$(run "$FAKE/usr/bin/$BIN" --version 2>&1); code=$?
if echo "$out" | grep -q "payload not installed"; then
    bad "stub still thinks the payload is missing: $out"
elif echo "$out" | grep -qiE "ld-musl|not found|cannot execute|Exec format"; then
    ok "exec reached the ELF loader and failed here, not in our code (code=$code)"
else
    bad "unexpected stub output: $out (code=$code)"
fi

# ---------------------------------------------------------------------------
note "6. daemon launcher argument construction"
# Swap the real payload for a probe so the flags are observable.
cat > "$FAKE/usr/bin/$BIN" <<'PROBE'
#!/bin/sh
echo "ARGS:$*"
echo "HOME:$HOME"
env | grep "=qoder_pat_for_test" | sed 's/^/TOKENENV:/'
PROBE
chmod 0755 "$FAKE/usr/bin/$BIN"
printf 'qoder_pat_for_test\n' > "$FAKE/etc/$BIN-rc/token"
chmod 600 "$FAKE/etc/$BIN-rc/token"

out=$(run "$FAKE/usr/libexec/$BIN/run-daemon.sh" 2>&1); code=$?
echo "$out" | grep -q "ARGS:remote-control --directory" \
    && ok "remote-control + --directory present" || bad "no remote-control args: $out"
echo "$out" | grep -q -- "--capacity 1" && ok "capacity defaults to 1" || bad "capacity default missing: $out"
echo "$out" | grep -q -- "--spawn same-dir" && ok "spawn default passed through" || bad "spawn missing: $out"
echo "$out" | grep -q -- "--name " && ok "--name derived (hostname)" || bad "--name missing: $out"
echo "$out" | grep -q "HOME:$FAKE" && ok "HOME taken from config default" || bad "HOME wrong: $out"

# The token has to leave under the name this edition actually reads. Measured on
# a CN device: QODER_PERSONAL_ACCESS_TOKEN alone still reported "Not logged in",
# while QODERCN_DEVICE_TOKEN reached the cloud and came back as HTTP 401.
for v in "${!V_BIN_NAME[@]}"; do
    [ "${V_BIN_NAME[$v]}" = "$BIN" ] || continue
    for name in ${V_TOKEN_ENV[$v]}; do
        echo "$out" | grep -q "TOKENENV:$name=qoder_pat_for_test" \
            && ok "token exported as $name" || bad "token missing as $name: $out"
    done
    case "${V_TOKEN_ENV[$v]}" in
        *QODERCN_DEVICE_TOKEN*) [ "$v" = qoder ] \
            && bad "the international build is given the CN variable name" \
            || ok "$v declares its own token variable" ;;
        *) [ "$v" = qoderclicn ] && bad "CN variant does not declare QODERCN_DEVICE_TOKEN" \
            || ok "$v declares only its own names" ;;
    esac
done

orig_token_env=$(sed -n "s/^[[:space:]]*option token_env '\(.*\)'/\1/p" "$CFG")
sed -i "s/option token_env '.*'/option token_env 'MY_GATEWAY_TOKEN'/" "$CFG"
out=$(run "$FAKE/usr/libexec/$BIN/run-daemon.sh" 2>&1)
echo "$out" | grep -q "TOKENENV:MY_GATEWAY_TOKEN=qoder_pat_for_test" \
    && ok "uci token_env overrides the variable list" \
    || bad "token_env override ignored: $out"
echo "$out" | grep -q "TOKENENV:QODER" \
    && bad "the built-in list still leaks after an override" \
    || ok "an override replaces the list instead of adding to it"
sed -i "s|option token_env '.*'|option token_env '$orig_token_env'|" "$CFG"

printf '\n' > "$FAKE/etc/$BIN-rc/token"
out=$(run "$FAKE/usr/libexec/$BIN/run-daemon.sh" 2>&1); code=$?
[ "$code" = 1 ] && echo "$out" | grep -q "no token on its first line" \
    && ok "an empty token file is refused instead of registering anonymously" \
    || bad "empty token file mishandled (code=$code): $out"
printf 'qoder_pat_for_test\n' > "$FAKE/etc/$BIN-rc/token"

# ---------------------------------------------------------------------------
note "7. ELF gate refuses a glibc binary when musl is required"
if python3 "$ROOT/lib/elfcheck.py" /bin/ls x86_64 musl >/dev/null 2>&1; then
    bad "elfcheck accepted a glibc binary"
else
    ok "elfcheck rejected /bin/ls (glibc) for a musl rootfs"
fi
if python3 "$ROOT/lib/elfcheck.py" "$DATA/$BIN" x86_64 musl >/dev/null 2>&1; then
    ok "elfcheck accepted the official musl payload"
else
    bad "elfcheck rejected the official musl payload"
fi

# ---------------------------------------------------------------------------
note "8. storage gate: RAM-backed mounts are refused, never suggested"
TS=$$
VOL=$(awk '$3 == "tmpfs" && $2 != "/dev" { print $2 }' /proc/mounts | while read -r m; do
    mkdir -p "$m/qsim.$TS" 2>/dev/null && { echo "$m"; rmdir "$m/qsim.$TS"; }
done | head -1)
if [ -z "$VOL" ]; then
    echo "  ..   skipped: no writable tmpfs on this host"
else
    out=$(run "$FAKE/usr/libexec/$BIN/fetch-payload.sh" --dir "$VOL/qsim.$TS/data" 2>&1); code=$?
    [ "$code" = 1 ] && echo "$out" | grep -q "RAM-backed or read-only" \
        && ok "$VOL is tmpfs: install refused" || bad "tmpfs target accepted: $out (code=$code)"
    suggested=$(printf '%s\n' "$out" | awk '$1 ~ /^\// { print $1 }')
    leak=""
    for m in $(awk '$3 == "tmpfs" { print $2 }' /proc/mounts); do
        printf '%s\n' "$suggested" | grep -qx "$m" && leak=$m
    done
    [ -z "$leak" ] && ok "no RAM-backed mount suggested" \
        || bad "suggested $leak, which is tmpfs: it cannot hold the payload"
    # With --allow-volatile the gate must let it through, failing later instead.
    out=$(run "$FAKE/usr/libexec/$BIN/fetch-payload.sh" --dir "$VOL/qsim.$TS/data" \
        --allow-volatile --from /nonexistent.tar.gz 2>&1)
    echo "$out" | grep -q "cannot read" \
        && ok "--allow-volatile overrides the gate" || bad "--allow-volatile did not pass the gate: $out"
    # Empty suggestion tables must say so instead of printing a bare header:
    # on a small-flash router every real mount can be too tight.
    env_file=$FAKE/usr/libexec/$BIN/payload.env
    orig_bytes=$(sed -n 's/^BINARY_BYTES=//p' "$env_file")
    sed -i 's/^BINARY_BYTES=.*/BINARY_BYTES=999999999999/' "$env_file"
    out=$(run "$FAKE/usr/libexec/$BIN/fetch-payload.sh" --dir "$VOL/qsim.$TS/data" 2>&1)
    echo "$out" | grep -q "(none:" \
        && ok "no-fit case degrades to an explicit none + offline hint" \
        || bad "empty storage list printed nothing: $out"
    sed -i "s/^BINARY_BYTES=.*/BINARY_BYTES=$orig_bytes/" "$env_file"
    rm -rf "$VOL/qsim.$TS"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
