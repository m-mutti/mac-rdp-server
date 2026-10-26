#!/bin/bash
# Builds the third-party toolchain into third_party/ without Homebrew or admin rights:
#   CMake (prebuilt), OpenSSL (static), FreeRDP 3 (static server + client libs).
# Re-running is cheap: finished steps are skipped via stamp files.
set -euo pipefail

CMAKE_VERSION=4.4.4
OPENSSL_VERSION=3.5.9
FREERDP_VERSION=3.32.2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/third_party"
DL="$TP/downloads"
SRC="$TP/src"
BUILD="$TP/build"
PREFIX="$TP/prefix"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$DL" "$SRC" "$BUILD" "$PREFIX" "$TP/tools"

log() { printf '\n==> %s\n' "$*"; }

# fetch <url> <expected-sha256>
fetch() {
    local url="$1" sha="$2" out="$DL/$(basename "$1")"
    if [[ ! -f "$out" ]]; then
        curl -fL --retry 3 -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    local got
    got="$(shasum -a 256 "$out" | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
        echo "checksum mismatch for $out: expected $sha, got $got" >&2
        rm -f "$out"
        exit 1
    fi
}

# published_sha <url-of-checksum-file> [filename-to-match]
published_sha() {
    local body
    body="$(curl -fsL --retry 3 "$1")"
    if [[ $# -gt 1 ]]; then
        body="$(grep -F "$2" <<<"$body")"
    fi
    grep -Eo '[0-9a-f]{64}' <<<"$body" | head -1
}

# --- CMake -------------------------------------------------------------------
CMAKE_BIN="$TP/tools/cmake/CMake.app/Contents/bin/cmake"
if [[ ! -x "$CMAKE_BIN" ]]; then
    log "CMake $CMAKE_VERSION"
    base="https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION"
    tarball="cmake-$CMAKE_VERSION-macos-universal.tar.gz"
    fetch "$base/$tarball" "$(published_sha "$base/cmake-$CMAKE_VERSION-SHA-256.txt" "$tarball")"
    rm -rf "$TP/tools/cmake" && mkdir -p "$TP/tools/cmake"
    tar -xzf "$DL/$tarball" -C "$TP/tools/cmake" --strip-components 1
fi

# --- OpenSSL -----------------------------------------------------------------
if [[ ! -f "$PREFIX/.openssl-$OPENSSL_VERSION" ]]; then
    log "OpenSSL $OPENSSL_VERSION"
    base="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION"
    tarball="openssl-$OPENSSL_VERSION.tar.gz"
    fetch "$base/$tarball" "$(published_sha "$base/$tarball.sha256")"
    rm -rf "$SRC/openssl-$OPENSSL_VERSION"
    tar -xzf "$DL/$tarball" -C "$SRC"
    (
        cd "$SRC/openssl-$OPENSSL_VERSION"
        ./Configure darwin64-arm64-cc no-shared no-tests no-docs \
            --prefix="$PREFIX" --libdir=lib -mmacosx-version-min=14.0
        make -j"$JOBS" >/dev/null
        make install_sw >/dev/null
    )
    touch "$PREFIX/.openssl-$OPENSSL_VERSION"
fi

# --- FreeRDP -----------------------------------------------------------------
if [[ ! -f "$PREFIX/.freerdp-$FREERDP_VERSION" ]]; then
    log "FreeRDP $FREERDP_VERSION"
    base="https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION"
    tarball="freerdp-$FREERDP_VERSION.tar.gz"
    fetch "$base/$tarball" "$(published_sha "$base/$tarball.sha256")"
    rm -rf "$SRC/freerdp-$FREERDP_VERSION" "$BUILD/freerdp"
    tar -xzf "$DL/$tarball" -C "$SRC"
    "$CMAKE_BIN" -S "$SRC/freerdp-$FREERDP_VERSION" -B "$BUILD/freerdp" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DOPENSSL_ROOT_DIR="$PREFIX" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DUSE_VERSION_FROM_GIT_TAG=OFF \
        -DWITH_SERVER=ON \
        -DWITH_SERVER_CHANNELS=ON \
        -DWITH_CLIENT=ON \
        -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_SAMPLE=ON \
        -DWITH_CLIENT_SDL=OFF \
        -DWITH_CLIENT_MAC=OFF \
        -DWITH_X11=OFF \
        -DWITH_WAYLAND=OFF \
        -DWITH_SHADOW=OFF \
        -DWITH_PROXY=OFF \
        -DWITH_PLATFORM_SERVER=OFF \
        -DWITH_FFMPEG=OFF \
        -DWITH_SWSCALE=OFF \
        -DWITH_DSP_FFMPEG=OFF \
        -DWITH_OPENH264=OFF \
        -DWITH_CUPS=OFF \
        -DWITH_PCSC=OFF \
        -DWITH_FUSE=OFF \
        -DWITH_KRB5=OFF \
        -DWITH_JSON_DISABLED=ON \
        -DWITH_AAD=OFF \
        -DWITH_WEBVIEW=OFF \
        -DCHANNEL_URBDRC=OFF \
        -DWITH_MANPAGES=OFF \
        -DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_SOXR=OFF -DWITH_LAME=OFF -DWITH_GSM=OFF \
        -DWITH_INTERNAL_MD4=ON \
        -DWITH_INTERNAL_RC4=ON \
        -DWITH_WINPR_TOOLS=ON
    "$CMAKE_BIN" --build "$BUILD/freerdp" -j "$JOBS"
    "$CMAKE_BIN" --install "$BUILD/freerdp" >/dev/null
    touch "$PREFIX/.freerdp-$FREERDP_VERSION"
fi

log "done — toolchain in $TP"
