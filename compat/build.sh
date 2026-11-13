#!/usr/bin/env bash
# Regenerate compat/<arch>/libqoder-compat.so from compat/shim.cpp.
#
# These are the only build products this repository checks in, because a
# nightly ipk must not depend on a cross toolchain being present: the CI job
# verifies the checked-in bytes against compat/SHA256SUMS and runs the gate in
# lib/depcheck.py, and only a maintainer who edits shim.cpp re-runs this script.
#
#   ./compat/build.sh                 both architectures
#   ./compat/build.sh aarch64         one architecture
set -eu
cd "$(dirname "$0")/.."

CLANG="${CLANG:-$(command -v clang++-19 || command -v clang++ || true)}"
LLD="${LLD:-$(command -v ld.lld || ls /usr/lib/llvm-*/bin/ld.lld 2>/dev/null | head -1 || true)}"
[ -n "$CLANG" ] || { echo "compat/build.sh: no clang++ found" >&2; exit 1; }
[ -n "$LLD" ] || { echo "compat/build.sh: no ld.lld found (GNU ld cannot cross-link)" >&2; exit 1; }

CFLAGS=(-O2 -shared -nostdlib -fPIC -fno-exceptions -fno-rtti -fno-asynchronous-unwind-tables
        -fvisibility=hidden -Wall -Wextra)

want=("$@")
[ ${#want[@]} -gt 0 ] || want=(arm64 x86_64)

declare -A ARCH_TARGET=([arm64]=aarch64 [x86_64]=x86_64)

for arch in "${want[@]}"; do
    target=${ARCH_TARGET[$arch]:-}
    [ -n "$target" ] || { echo "compat/build.sh: unknown arch: $arch (arm64|x86_64)" >&2; exit 2; }
    mkdir -p "compat/$arch"
    # The loader looks the shim up by name, so the file name is part of the ABI
    # between the package and compat-env.sh.
    "$CLANG" --target="$target-linux-musl" --ld-path="$LLD" "${CFLAGS[@]}" \
        -o "compat/$arch/libqoder-compat.so" compat/shim.cpp
    chmod 644 "compat/$arch/libqoder-compat.so"
    readelf -hW "compat/$arch/libqoder-compat.so" | sed -n 's/^ *Machine: *//p'
done

( cd compat && rm -f SHA256SUMS && sha256sum */libqoder-compat.so > SHA256SUMS )
cat compat/SHA256SUMS
echo
echo "update etc/compat.conf SHA256_* values from the lines above, then run:"
echo "  python3 lib/depcheck.py --lib compat/arm64/libqoder-compat.so --assert-symbols \$(sed -n 's/^COMPAT_SYMBOLS=//p' etc/compat.conf) --max-bytes \$(sed -n 's/^MAX_SHIM_BYTES=//p' etc/compat.conf)"
