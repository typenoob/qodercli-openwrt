#!/usr/bin/env bash
# Test for the closed compat layer: the tiny stub library that lets a payload
# built against a newer libstdc++ start on an old OpenWrt rootfs.
#
# Three levels, strongest first where the toolchain allows it:
#   1. what the package ships must be exactly what compat/shim.cpp declares
#   2. a real dynamic linker must refuse a binary without the stub and accept
#      it with the stub preloaded, and the stub must abort when called
#   3. the on-device scripts must read that verdict from the loader, switch the
#      stub on only when needed, and name any symbol the stub cannot cover
#
# usage: bin/test-compat.sh [IPK]     # default: newest qodercli x86_64 stub ipk
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source "$ROOT/etc/compat.conf"

PASS=0
FAIL=0
ok() { echo "  ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
note() { echo "== $*"; }
skip() { echo "  ..   $*"; }

# The scratch trees live under work/ (never /tmp, which is tiny on the device
# this package targets), so each one is registered for removal on exit.
TMP_ROOTS=""
clean_tmp() { [ -n "$TMP_ROOTS" ] && rm -rf $TMP_ROOTS; return 0; }
trap clean_tmp EXIT

ASHER="busybox sh"
command -v busybox >/dev/null 2>&1 || ASHER="dash"
run() { $ASHER "$@"; }

PAYLOAD=$(ls -1 "$ROOT"/work/payload/*-x86_64-musl/qodercli 2>/dev/null | head -1)
[ -n "$PAYLOAD" ] || { echo "test-compat: no cached x86_64 payload; run bin/build.sh first" >&2; exit 1; }
SYM=_ZSt21__glibcxx_assert_failPKciS0_S0_

# ---------------------------------------------------------------------------
note "1. what ships matches what compat/shim.cpp declares"
for arch in arm64 x86_64; do
    sha_var=SHA256_$arch
    if ! python3 "$ROOT/lib/compatgate.py" "compat/$arch/libqoder-compat.so" \
            "$PAYLOAD" "$arch" "${!sha_var}" "$SYM" "$MAX_SHIM_BYTES" >/dev/null; then
        bad "compatgate refused the shipped $arch shim"
    else
        bytes=$(stat -c %s "compat/$arch/libqoder-compat.so")
        ok "$arch shim passes the gate at $bytes bytes (cap $MAX_SHIM_BYTES)"
    fi
done
out=$(python3 "$ROOT/lib/depcheck.py" --lib compat/x86_64/libqoder-compat.so \
        --assert-symbols "$COMPAT_SYMBOLS" --max-bytes "$MAX_SHIM_BYTES" 2>&1)
echo "$out" | grep -q "dt_needed: \[\]" \
    && ok "shim needs no libraries of its own (DT_NEEDED empty)" \
    || bad "shim is not self-contained: $out"

# the gate has to actually gate
if python3 "$ROOT/lib/compatgate.py" compat/x86_64/libqoder-compat.so "$PAYLOAD" arm64 \
        deadbeef "$SYM,not_a_real_symbol" 32 >/dev/null 2>&1; then
    bad "compatgate accepted a wrong arch, wrong hash, an unexported symbol and an oversize cap"
else
    ok "compatgate refuses arch/hash/symbol/size violations"
fi
cp compat/x86_64/libqoder-compat.so "$ROOT/work/shim-bad.so"
printf 'garbage' >> "$ROOT/work/shim-bad.so"
python3 "$ROOT/lib/compatgate.py" "$ROOT/work/shim-bad.so" "$PAYLOAD" x86_64 \
    "$SHA256_x86_64" "$COMPAT_SYMBOLS" "$MAX_SHIM_BYTES" >/dev/null 2>&1 \
    && bad "compatgate accepted a modified ELF" \
    || ok "compatgate rejects a shim whose bytes do not match etc/compat.conf"
rm -f "$ROOT/work/shim-bad.so"

# ---------------------------------------------------------------------------
note "2. a real dynamic linker: refused without the stub, accepted with it"
CXX=$(command -v clang++-19 || command -v clang++ || command -v g++ || true)
T=$(mktemp -d "$ROOT/work/compat-link.XXXXXX")
TMP_ROOTS="$TMP_ROOTS $T"
if [ -z "$CXX" ]; then
    skip "no C++ compiler on this host"
else
    # An executable with an undefined reference to the compat symbol and no
    # libstdc++ to supply it - the device's exact situation - bound eagerly so
    # glibc reports it at exec time the way musl always does.
    # The payload's own shape: a binary whose DT_NEEDED library references a
    # symbol this system does not export. libbroken.so stands in for a
    # libstdc++ linked against GCC >= 12; with eager binding the loader has to
    # answer that reference before main runs, exactly like musl always does.
    cat > "$T/broken.cpp" <<EOF
extern "C" void missing(const char *, int, const char *, const char *)
    asm("$SYM");
extern "C" void take_assert_path(void) { missing("f.cpp", 1, "fn", "msg"); }
EOF
    cat > "$T/consumer.cpp" <<EOF
#include <cstdio>
extern "C" void take_assert_path(void);
int main(int argc, char **argv) {
    if (argc > 1) { take_assert_path(); return 7; }
    std::puts("bound and ran");
    return 0;
}
EOF
    if ! "$CXX" -O0 -shared -fPIC -nostdlib++ -Wl,-z,now "$T/broken.cpp" \
            -o "$T/libbroken.so" 2>"$T/cc.err" \
       || ! "$CXX" -O0 -nostdlib++ "$T/consumer.cpp" -L"$T" -l:libbroken.so \
            -Wl,--allow-shlib-undefined -Wl,-rpath,"$T" -o "$T/consumer" 2>>"$T/cc.err"; then
        skip "host toolchain cannot build the fixture ($(head -2 "$T/cc.err"))"
    else
        out=$(cd "$T" && LD_BIND_NOW=1 LD_PRELOAD= ./consumer 2>&1); code=$?
        if [ "$code" != 0 ] && echo "$out" | grep -q "undefined symbol.*$SYM"; then
            ok "loader refuses the payload without the stub (exit $code)"
        else
            bad "expected an undefined-symbol failure, got code=$code: $out"
        fi

        SHIM=$ROOT/compat/x86_64/libqoder-compat.so
        out=$(cd "$T" && LD_BIND_NOW=1 LD_PRELOAD="$SHIM" ./consumer 2>&1); code=$?
        if [ "$code" = 0 ] && echo "$out" | grep -q "bound and ran"; then
            ok "loader accepts the same binary with the stub preloaded"
        else
            bad "preload did not resolve the symbol (code=$code): $out"
        fi

        # The stub must not return: continuing past an assertion the payload
        # considers unreachable is worse than dying there.
        out=$(cd "$T" && LD_BIND_NOW=1 LD_PRELOAD="$SHIM" ./consumer boom 2>&1); code=$?
        if [ "$code" = 132 ] || echo "$out" | grep -qi "illegal instruction"; then
            ok "the stub traps instead of returning (exit $code)"
        else
            bad "stub returned instead of aborting (code=$code): $out"
        fi
    fi
fi

# ---------------------------------------------------------------------------
note "3. the on-device scripts read the loader's verdict"
IPK=${1:-}
[ -n "$IPK" ] || IPK=$(ls -1t "$ROOT"/dist/qodercli_*_x86_64.ipk 2>/dev/null | head -1)
if [ -z "$IPK" ] || [ ! -f "$IPK" ]; then
    skip "no stub ipk; run bin/build.sh --variant qoder --arch x86_64"
else
    FAKE=$(mktemp -d "$ROOT/work/compat-sim.XXXXXX")
    TMP_ROOTS="$TMP_ROOTS $FAKE"
    LIBEXEC=$FAKE/usr/libexec/qodercli
    BIN=qodercli
    ENV=$LIBEXEC/payload.env
    tar xzf "$IPK" -C "$FAKE"
    tar xzf "$FAKE/data.tar.gz" -C "$FAKE"
    rm -f "$FAKE"/debian-binary "$FAKE"/data.tar.gz "$FAKE"/control.tar.gz
    find "$FAKE" -type f -exec sed -i \
        -e "s|/usr/libexec/$BIN|$LIBEXEC|g" \
        -e "s|/usr/bin/$BIN|$FAKE/usr/bin/$BIN|g" \
        -e "s|/etc/$BIN-rc|$FAKE/etc/$BIN-rc|g" {} +
    chmod -R u+rwX "$FAKE"

    # pretend to be a musl rootfs: the interpreter gate only looks for the file
    mkdir -p "$FAKE/lib" "$FAKE/data"
    touch "$FAKE/lib/ld-musl-x86_64.so.1"
    sed -i -e "s|^EXPECTED_INTERP=.*|EXPECTED_INTERP=$FAKE/lib/ld-musl-x86_64.so.1|" \
           -e "s|^DATA_DIR=.*|DATA_DIR=$FAKE/data|" \
           -e "s|^BINARY_BYTES=.*|BINARY_BYTES=4096|" "$ENV"
    CFG=$FAKE/etc/config/$BIN-rc
    sed -i "s|option data_dir '[^']*'|option data_dir '$FAKE/data'|" "$CFG"
    MARKER=$FAKE/etc/$BIN-rc/compat.on
    SHIM=$LIBEXEC/compat/libqoder-compat.so
    [ -f "$SHIM" ] || bad "ipk does not ship the compat shim"

    mkdir -p "$FAKE/bin"
    cat > "$FAKE/bin/uci" <<'UCISHIM'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    *.config.*) key=${last##*.} ;;
    *) exit 1 ;;
esac
[ -f "$FAKE_UCI_CONFIG" ] || exit 1
# last wins, the way uci_parse_option overwrites a duplicate key
v=$(sed -n "s/^[[:space:]]*option[[:space:]]\{1,\}$key[[:space:]]\{1,\}//p" \
    "$FAKE_UCI_CONFIG" | tail -1 | tr -d "'\"")
[ -n "$v" ] || exit 1
printf '%s\n' "$v"
UCISHIM
    chmod 0755 "$FAKE/bin/uci"
    export FAKE_UCI_CONFIG=$CFG
    PATH=$FAKE/bin:$PATH
    export PATH

    # a payload fixture that behaves the way the loader does
    fixture() {
        cat > "$FAKE/data/$BIN" <<EOF
#!/bin/sh
# fixture: reports the symbols this simulated rootfs cannot resolve, unless the
# compat stub is already preloaded - then it binds and runs.
[ "\$1" = "--version" ] || exit 0
case " \${LD_PRELOAD:-} " in
    *libqoder-compat*) echo "9.9.9-fixture"; exit 0 ;;
esac
EOF
        for s in "$@"; do
            echo "echo \"Error relocating \$0: $s: symbol not found\" >&2" >> "$FAKE/data/$BIN"
        done
        if [ "$#" -gt 0 ]; then
            printf 'exit 127\n' >> "$FAKE/data/$BIN"
        else
            printf 'echo "9.9.9-fixture"\n' >> "$FAKE/data/$BIN"
        fi
        chmod 0755 "$FAKE/data/$BIN"
        sed -i "s|^BINARY_SHA256=.*|BINARY_SHA256=$(sha256sum "$FAKE/data/$BIN" | cut -d' ' -f1)|" "$ENV"
    }

    fixture
    rm -f "$MARKER"
    out=$(run "$LIBEXEC/fetch-payload.sh" --verify 2>&1); code=$?
    if [ "$code" = 0 ] && [ ! -e "$MARKER" ] && echo "$out" | grep -q "compat shim not needed"; then
        ok "rootfs that needs nothing gets no marker"
    else
        bad "clean rootfs mishandled (code=$code): $out"
    fi

    fixture "$SYM"
    out=$(run "$LIBEXEC/fetch-payload.sh" --verify 2>&1); code=$?
    if [ "$code" = 0 ] && grep -q "$SYM" "$MARKER" 2>/dev/null; then
        ok "covered gap: shim switched on and $(basename "$MARKER") records $SYM"
    else
        bad "covered gap not handled (code=$code): $out"
    fi
    out=$(run "$FAKE/usr/bin/$BIN" --version 2>&1); code=$?
    [ "$code" = 0 ] && ok "wrapper runs the payload once the shim is on" \
        || bad "wrapper failed after the shim was enabled (code=$code): $out"

    got=$($ASHER -c ". $LIBEXEC/compat-env.sh
        LD_PRELOAD='user.so'
        apply_compat_env
        printf '%s' \"\$LD_PRELOAD\"")
    [ "$got" = "user.so $SHIM" ] \
        && ok "existing LD_PRELOAD is kept and ordered before the shim" \
        || bad "existing LD_PRELOAD clobbered: '$got'"
    got=$($ASHER -c ". $LIBEXEC/compat-env.sh
        apply_compat_env; apply_compat_env
        printf '%s' \"\$LD_PRELOAD\"")
    [ "$(printf '%s' "$got" | tr ' ' '\n' | grep -c "libqoder-compat")" = 1 ] \
        && ok "applying it twice does not preload the shim twice" \
        || bad "shim preloaded more than once: '$got'"

    printf "\toption compat 'off'\n" >> "$CFG"
    got=$($ASHER -c ". $LIBEXEC/compat-env.sh
        apply_compat_env
        printf '[%s]' \"\${LD_PRELOAD-unset}\"")
    [ "$got" = "[unset]" ] && ok "uci compat=off overrides the marker" \
        || bad "off policy ignored: '$got'"
    sed -i "/option compat/d" "$CFG"

    fixture "$SYM" not_a_real_symbol
    rm -f "$MARKER"
    out=$(run "$LIBEXEC/fetch-payload.sh" --verify 2>&1); code=$?
    if [ "$code" = 1 ] && echo "$out" | grep -q "not_a_real_symbol" \
       && echo "$out" | grep -q "only covers"; then
        ok "uncovered gap: install refused and the unfixable symbol named"
    else
        bad "uncovered gap mishandled (code=$code): $out"
    fi
    [ -e "$MARKER" ] && bad "marker left behind on a refused install" \
        || ok "no marker written when the shim cannot help"

    # install mode must reach the same verdict, not just --verify
    rm -f "$MARKER"
    fixture "$SYM"
    tgz=$FAKE/fixture.tar.gz
    ( cd "$FAKE/data" && tar czf "$tgz" "$BIN" )
    sed -i "s|^PAYLOAD_SHA256=.*|PAYLOAD_SHA256=$(sha256sum "$tgz" | cut -d' ' -f1)|" "$ENV"
    out=$(run "$LIBEXEC/fetch-payload.sh" --force --from "$tgz" --dir "$FAKE/data" 2>&1); code=$?
    if [ "$code" = 0 ] && grep -q "$SYM" "$MARKER" 2>/dev/null; then
        ok "install mode enables the shim from the same loader verdict"
    else
        bad "install mode mishandled the gap (code=$code): $out"
    fi

    # The bug this catches: a probe that produces no relocation line because it
    # never ran the payload (coreutils timeout on this image rejects "-t", so
    # the wrapper's usage error looked like a clean load and the shim stayed off
    # on a device that needed it).
    printf '#!/bin/sh\necho "timeout: invalid option" >&2\nexit 125\n' > "$FAKE/data/$BIN"
    chmod 0755 "$FAKE/data/$BIN"
    sed -i "s|^BINARY_SHA256=.*|BINARY_SHA256=$(sha256sum "$FAKE/data/$BIN" | cut -d' ' -f1)|" "$ENV"
    rm -f "$MARKER"
    out=$(run "$LIBEXEC/fetch-payload.sh" --verify 2>&1); code=$?
    if [ "$code" = 1 ] && echo "$out" | grep -q "cannot be judged"; then
        ok "a probe that proves nothing is refused instead of called clean"
    else
        bad "inconclusive probe reported as success (code=$code): $out"
    fi

    fixture
    rm -f "$FAKE/lib/ld-musl-x86_64.so.1" "$MARKER"
    out=$(run "$LIBEXEC/fetch-payload.sh" --verify 2>&1); code=$?
    [ "$code" = 4 ] && ok "a rootfs with no musl loader is reported as exit 4, not guessed at" \
        || bad "absent interpreter mishandled (code=$code): $out"
fi

echo
printf 'passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
