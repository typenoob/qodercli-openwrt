#!/usr/bin/env bash
# Build OpenWrt ipk packages around the official Qoder CLI musl binaries.
#
# There is no compilation step: qodercli/qoderclicn ship as Bun single-file
# executables with no public source. What this script does is select the musl
# channel that can actually run on a musl rootfs, prove that by reading the ELF
# header, and repackage it together with a procd service definition.
#
#   bin/build.sh                              # both variants, both arches
#   bin/build.sh --variant qoderclicn --arch arm64 --mode embed
#   bin/build.sh --list-support
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source "$ROOT/etc/variants.conf"
source "$ROOT/etc/ipk-matrix.conf"
source "$ROOT/etc/compat.conf"

WORK=${QI_WORK:-$ROOT/work}
OUT=${QI_OUT:-$ROOT/dist}
REV=1
VERSION=""
VARIANT_FILTER=all
ARCH_FILTER=all
MODES=(stub)
COMPAT=1
LIBC=musl
OFFLINE=0
KEEP_STAGE=0

usage() {
    awk 'NR == 1 { next } /^set -e/ { exit } { sub(/^# ?/, "") ; print }' "$(readlink -f "$0")"
    cat >&2 <<'EOF'

options:
  --variant qoder|qoderclicn|all   which channel to package      (default all)
  --arch    x86_64|arm64|all       payload arch                  (default all)
  --version 1.1.87                 pin a release                 (default latest)
  --mode    stub|embed|both        packaging mode, comma list    (default stub)
  --libc    musl|glibc             which channel; glibc builds only run on
                                   images that ship a glibc loader (default musl)
  --rev     N                      package revision suffix       (default 1)
  --dist    DIR                    output feed directory; embed always lands in
                                   DIR/embed because it collides with the stub
                                   ipk of the same name         (default dist)
  --offline                        fail instead of downloading (uses work/cache)
  --no-compat                      omit compat/<arch>/libqoder-compat.so from the
                                   package; payload only loads where libstdc++
                                   already exports COMPAT_SYMBOLS
  --keep-stage                     keep staging dirs for inspection
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT_FILTER=$2; shift 2 ;;
        --arch) ARCH_FILTER=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --mode) IFS=, read -r -a MODES <<<"$2"; shift 2 ;;
        --libc) LIBC=$2; shift 2 ;;
        --rev) REV=$2; shift 2 ;;
        --dist) OUT=$(readlink -f -m "$2"); shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        --no-compat) COMPAT=0; shift ;;
        --keep-stage) KEEP_STAGE=1; shift ;;
        --list-support) list_support=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "build.sh: unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# --mode both is shorthand: stub and embed produce same-named ipks, so they are
# always written to separate feeds rather than overwriting each other.
_expanded=()
for _m in "${MODES[@]}"; do
    case "$_m" in
        both) _expanded+=(stub embed) ;;
        stub | embed) _expanded+=("$_m") ;;
        *) echo "build.sh: unknown mode: $_m (stub|embed|both)" >&2; exit 2 ;;
    esac
done
MODES=("${_expanded[@]}")

if [ "${list_support:-0}" = 1 ]; then
    printf '%-14s %-22s %s\n' "payload arch" "ipk Architecture" "official entry"
    for pa in x86_64 arm64; do
        for label in ${ARCH_IPK_LABELS[$pa]}; do
            printf '%-14s %-22s %s\n' "$pa" "$label" "linux/${V_MANIFEST_ARCH[$pa]}"
        done
    done
    printf '\nRelease lines targeted: %s\n' "$RELEASE_LINES"
    printf 'No official binary exists for mips/mipsel/mips64/armv7/riscv64/32-bit x86;\n'
    printf 'those targets cannot be packaged at all (%s).\n' "$UNSUPPORTED_ARCH_NOTE"
    exit 0
fi

if [ "$LIBC" = glibc ]; then
    echo "build.sh: WARNING --libc glibc packages the channel whose PT_INTERP is" >&2
    echo "          /lib/ld-linux-*, absent on a stock OpenWrt image. Only use it for" >&2
    echo "          distro-based images that really carry glibc." >&2
elif [ "$LIBC" != musl ]; then
    echo "build.sh: --libc must be musl or glibc" >&2
    exit 2
fi

mkdir -p "$WORK/cache" "$WORK/manifests" "$WORK/payload" "$WORK/stage" "$OUT"

VARIANTS=()
if [ "$VARIANT_FILTER" = all ]; then VARIANTS=("${!V_BASE_URL[@]}"); else VARIANTS=("$VARIANT_FILTER"); fi
for v in "${VARIANTS[@]}"; do
    [ -n "${V_BASE_URL[$v]:-}" ] || { echo "build.sh: unknown variant: $v (known: ${!V_BASE_URL[*]})" >&2; exit 2; }
done
PAYLOAD_ARCHES=()
if [ "$ARCH_FILTER" = all ]; then PAYLOAD_ARCHES=(x86_64 arm64); else PAYLOAD_ARCHES=("$ARCH_FILTER"); fi
for a in "${PAYLOAD_ARCHES[@]}"; do
    [ -n "${ARCH_IPK_LABELS[$a]:-}" ] || { echo "build.sh: unknown arch: $a (known: ${!ARCH_IPK_LABELS[*]})" >&2; exit 2; }
done

dl() { # dl URL DEST
    local url=$1 dest=$2
    [ -f "$dest" ] && return 0
    if [ "$OFFLINE" = 1 ]; then
        echo "   --offline but $dest is missing" >&2
        return 1
    fi
    echo "   downloading $(basename "$url")"
    curl -fsSL --connect-timeout 30 --max-time 1800 -o "$dest.part" "$url"
    mv -f "$dest.part" "$dest"
}

BUILT=()
FAILED=()
FEEDS=()

for variant in "${VARIANTS[@]}"; do
    base=${V_BASE_URL[$variant]}
    bin=${V_BIN_NAME[$variant]}
    display=${V_DISPLAY[$variant]}

    if [ -n "$VERSION" ]; then
        manifest_url=$base/channels/${VERSION#v}/manifest.json
        mkey=$variant-${VERSION#v}
    else
        manifest_url=$base/channels/manifest.json
        mkey=$variant-latest
    fi
    manifest=$WORK/manifests/$mkey.json
    if ! dl "$manifest_url" "$manifest"; then
        FAILED+=("$variant manifest")
        continue
    fi

    for payload_arch in "${PAYLOAD_ARCHES[@]}"; do
        if [ "$LIBC" = glibc ]; then
            token=${V_MANIFEST_ARCH[$payload_arch]%-musl}
            libc_required=glibc
            if [ "$payload_arch" = x86_64 ]; then
                interp=/lib/ld-linux-x86-64.so.2
            else
                interp=/lib/ld-linux-aarch64.so.1
            fi
        else
            token=${V_MANIFEST_ARCH[$payload_arch]}
            libc_required=musl
            interp=${EXPECTED_INTERP[$payload_arch]}
        fi

        if ! meta=$(python3 "$ROOT/lib/manifest.py" "$manifest" "$token" linux); then
            FAILED+=("$variant/$payload_arch not-officially-published")
            continue
        fi
        eval "$meta"
        version=$VERSION
        echo "== $display $version / $payload_arch (channel linux/$token)"

        tarball=$WORK/cache/$FILE
        if ! dl "$URL" "$tarball"; then
            FAILED+=("$variant/$payload_arch download")
            continue
        fi
        sha=$(sha256sum "$tarball" | awk '{print $1}')
        if [ "$sha" != "$SHA256" ]; then
            echo "   REFUSED checksum: got $sha, manifest says $SHA256" >&2
            rm -f "$tarball"
            FAILED+=("$variant/$payload_arch checksum")
            continue
        fi
        echo "   sha256 verified"

        pdir=$WORK/payload/$variant-$version-$payload_arch-$libc_required
        if [ ! -f "$pdir/.ok" ]; then
            rm -rf "$pdir"
            mkdir -p "$pdir"
            tar -xzf "$tarball" -C "$pdir"
            if [ ! -f "$pdir/$bin" ]; then
                echo "   REFUSED: archive does not contain $bin" >&2
                FAILED+=("$variant/$payload_arch archive-layout")
                continue
            fi
            sha256sum "$pdir/$bin" | awk '{print $1}' > "$pdir/.sha"
            stat -c %s "$pdir/$bin" > "$pdir/.bytes"
            if ! date -u -d "$PUBLISHED_AT" +%s > "$pdir/.epoch" 2>/dev/null; then
                date -u -d "$(date -u +%Y-%m-%d) 00:00:00" +%s > "$pdir/.epoch"
            fi
            touch "$pdir/.ok"
        fi
        bin_sha=$(cat "$pdir/.sha")
        bin_bytes=$(cat "$pdir/.bytes")
        epoch=$(cat "$pdir/.epoch")
        binary_mib=$(( (bin_bytes + 1048575) / 1048576 ))

        if ! python3 "$ROOT/lib/elfcheck.py" "$pdir/$bin" "$payload_arch" "$libc_required"; then
            echo "   REFUSED: $(basename "$tarball") is not a $libc_required $payload_arch payload" >&2
            FAILED+=("$variant/$payload_arch elf-gate")
            continue
        fi
        echo "   ELF gate passed: interp $interp, arch $payload_arch"

        # The ELF gate says which libc the payload wants; it cannot see whether
        # that libc and its C++ runtime actually export what the payload
        # imports. One missing strong symbol is a fatal relocation error on
        # musl, so the compat layer is checked here, before anything is packed.
        compat_src=$ROOT/compat/$payload_arch/libqoder-compat.so
        compat_sha_var=SHA256_$payload_arch
        if [ "$COMPAT" = 1 ]; then
            if [ ! -f "$compat_src" ] || [ -z "${!compat_sha_var:-}" ]; then
                echo "   REFUSED: no compat shim for $payload_arch (need compat/$payload_arch/libqoder-compat.so and SHA256_$payload_arch)" >&2
                FAILED+=("$variant/$payload_arch compat-shim-missing")
                continue
            fi
            if ! python3 "$ROOT/lib/compatgate.py" "$compat_src" "$pdir/$bin" \
                        "$payload_arch" "${!compat_sha_var}" "$COMPAT_SYMBOLS" "$MAX_SHIM_BYTES"; then
                FAILED+=("$variant/$payload_arch compat-gate")
                continue
            fi
        fi

        pkg_version=$version-r$REV

        for mode in "${MODES[@]}"; do
            case "$mode" in
                stub)
                    payload_mode=fetch
                    payload_path=
                    out_dir=$OUT
                    ;;
                embed)
                    payload_mode=embed
                    payload_path=/usr/libexec/$bin/payload/$bin
                    # same filename as the stub package and they conflict on
                    # install, so embed publishes as its own feed
                    out_dir=$OUT/embed
                    ;;
            esac
            data_dir=/root/.qoder-$bin

            for label in ${ARCH_IPK_LABELS[$payload_arch]}; do
                stage=$WORK/stage/$bin-$pkg_version-$label-$mode
                rm -rf "$stage"
                mkdir -p "$stage/ctl" "$stage/root" "$stage/outer" \
                    "$stage/root/usr/bin" "$stage/root/usr/libexec/$bin" "$stage/root/etc/init.d" \
                    "$stage/root/etc/config" "$stage/root/etc/$bin-rc"
                if [ "$COMPAT" = 1 ]; then
                    mkdir -p "$stage/root/usr/libexec/$bin/compat"
                    cp -p "$compat_src" "$stage/root/usr/libexec/$bin/compat/libqoder-compat.so"
                    chmod 0644 "$stage/root/usr/libexec/$bin/compat/libqoder-compat.so"
                fi
                chmod 0700 "$stage/root/etc/$bin-rc"

                if [ "$payload_mode" = embed ]; then
                    mkdir -p "$stage/root/usr/libexec/$bin/payload"
                    cp -p "$pdir/$bin" "$stage/root/usr/libexec/$bin/payload/$bin"
                    chmod 0755 "$stage/root/usr/libexec/$bin/payload/$bin"
                    installed_kib=$(( (bin_bytes + 4194304) / 1024 ))
                else
                    installed_kib=128
                fi

                vars=(
                    PKG=$bin SRV=$bin-rc BIN=$bin "DISPLAY=$display"
                    CLI_VERSION=$version PKG_VERSION=$pkg_version ARCH_IPK=$label
                    INSTALLED_KIB=$installed_kib
                    PAYLOAD_ARCH=$payload_arch PAYLOAD_MODE=$payload_mode
                    PAYLOAD_PATH=$payload_path DATA_DIR=$data_dir
                    PAYLOAD_URL=$URL PAYLOAD_SHA256=$SHA256
                    BINARY_SHA256=$bin_sha BINARY_BYTES=$bin_bytes BINARY_MIB=$binary_mib
                    EXPECTED_INTERP=$interp NEEDED_FREE_KIB=$SPACE_MARGIN_KIB
                    PAYLOAD_FILE=$FILE SOURCE=$base
                    DEFAULT_CAPACITY=$DEFAULT_CAPACITY DEFAULT_SPAWN=$DEFAULT_SPAWN
                    COMPAT_LIB=/usr/libexec/$bin/compat/libqoder-compat.so
                    COMPAT_MARKER=/etc/$bin-rc/$COMPAT_MARKER_NAME
                    COMPAT_SYMBOLS=$COMPAT_SYMBOLS
                    TOKEN_ENV="${V_TOKEN_ENV[$variant]}"
                )
                render() { python3 "$ROOT/lib/render.py" "$ROOT/templates/$1" "$2" "${vars[@]}"; }

                render control.in "$stage/ctl/control"
                render conffiles.in "$stage/ctl/conffiles"
                render postinst.in "$stage/ctl/postinst"
                render prerm.in "$stage/ctl/prerm"
                chmod 0755 "$stage/ctl/postinst" "$stage/ctl/prerm"

                render payload.env.in "$stage/root/usr/libexec/$bin/payload.env"
                render stub.sh.in "$stage/root/usr/bin/$bin"
                render fetch-payload.sh.in "$stage/root/usr/libexec/$bin/fetch-payload.sh"
                render run-daemon.sh.in "$stage/root/usr/libexec/$bin/run-daemon.sh"
                render compat-env.sh.in "$stage/root/usr/libexec/$bin/compat-env.sh"
                render initd.in "$stage/root/etc/init.d/$bin-rc"
                render config.in "$stage/root/etc/config/$bin-rc"
                chmod 0755 "$stage/root/usr/bin/$bin" \
                    "$stage/root/usr/libexec/$bin/fetch-payload.sh" \
                    "$stage/root/usr/libexec/$bin/run-daemon.sh" \
                    "$stage/root/usr/libexec/$bin/compat-env.sh" \
                    "$stage/root/etc/init.d/$bin-rc"
                chmod 0644 "$stage/root/etc/config/$bin-rc" "$stage/root/usr/libexec/$bin/payload.env"

                printf '2.0\n' > "$stage/outer/debian-binary"
                SOURCE_DATE_EPOCH=$epoch python3 "$ROOT/lib/mktar.py" "$stage/outer/control.tar.gz" "$stage/ctl" >/dev/null
                SOURCE_DATE_EPOCH=$epoch python3 "$ROOT/lib/mktar.py" "$stage/outer/data.tar.gz" "$stage/root" >/dev/null
                mkdir -p "$out_dir"
                ipk=$out_dir/${bin}_${pkg_version}_${label}.ipk
                SOURCE_DATE_EPOCH=$epoch python3 "$ROOT/lib/mktar.py" "$ipk" "$stage/outer" --no-dirs >/dev/null

                echo "   $(basename "$ipk")  $(stat -c %s "$ipk") bytes  mode=$mode"
                BUILT+=("$ipk")
                case " ${FEEDS[*]:-} " in *" $out_dir "*) ;; *) FEEDS+=("$out_dir") ;; esac
                [ "$KEEP_STAGE" = 1 ] || rm -rf "$stage"
            done
        done
    done
done

for feed in "${FEEDS[@]}"; do
    python3 "$ROOT/lib/index.py" "$feed"
    echo "feed index: $feed/Packages (+ Packages.gz)"
done

echo "built ${#BUILT[@]} ipk"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "failed: ${FAILED[*]}" >&2
    exit 1
fi
