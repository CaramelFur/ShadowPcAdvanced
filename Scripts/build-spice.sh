#!/bin/bash
# Build spice-client-glib (the Linux reference SPICE client library, from
# spice-gtk) and its dependencies into a private prefix: ThirdParty/prefix.
# Nothing is installed system-wide. Pinned, checksummed source tarballs.
#
#   Scripts/build-spice.sh            # build whatever is missing
#   Scripts/build-spice.sh --clean    # wipe build dirs + prefix first
#
# GStreamer is patched out (ThirdParty/patches): no audio and no VP8/H264
# streams; display (incl. built-in MJPEG), inputs and cursor are unaffected.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD/ThirdParty"
DL="$ROOT/dl"; BUILD="$ROOT/build"; PREFIX="$ROOT/prefix"; LOGS="$ROOT/logs"
export MACOSX_DEPLOYMENT_TARGET=13.0

if [ "${1:-}" = "--clean" ]; then rm -rf "$BUILD" "$PREFIX"; fi
mkdir -p "$DL" "$BUILD" "$PREFIX" "$LOGS"

# Only our prefix plus two libraries Homebrew already provides here. Keeping
# /usr/local/lib/pkgconfig out stops glib from picking up stray brew deps.
BREW="$(brew --prefix 2>/dev/null || echo /usr/local)"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$BREW/opt/openssl@3/lib/pkgconfig:$BREW/opt/jpeg-turbo/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"
# meson's python has no CA bundle of its own here; wrap downloads (pcre2,
# libffi, libintl — all hash-pinned by their .wrap files) need one.
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"

fetch() { # url sha256
    local f="$DL/$(basename "$1")"
    [ -f "$f" ] || curl -fsSL -o "$f" "$1"
    echo "$2  $f" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $f" >&2; exit 1; }
}

unpack() { # tarball dir
    rm -rf "$BUILD/$2"
    tar xf "$DL/$1" -C "$BUILD"
}

meson_build() { # name srcdir [meson options…]
    local name="$1" src="$BUILD/$2"; shift 2
    echo "==> $name"
    ( cd "$src"
      meson setup _build --prefix "$PREFIX" --libdir lib --buildtype release --default-library shared "$@"
      meson compile -C _build
      meson install -C _build ) > "$LOGS/$name.log" 2>&1 || { tail -40 "$LOGS/$name.log" >&2; echo "FAILED: $name (full log: $LOGS/$name.log)" >&2; exit 1; }
}

have() { [ -f "$PREFIX/lib/pkgconfig/$1.pc" ] || [ -f "$PREFIX/share/pkgconfig/$1.pc" ]; }

# spice-common generates its (de)marshallers with python + pyparsing/six.
VENV="$BUILD/venv"
if [ ! -x "$VENV/bin/python3" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q pyparsing six
fi

if ! have glib-2.0; then
    fetch https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz 05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f
    unpack glib-2.82.5.tar.xz glib-2.82.5
    # pcre2 / libffi / libintl come from glib's own meson wraps, linked statically.
    meson_build glib glib-2.82.5 \
        -Dtests=false -Dintrospection=disabled -Dnls=disabled -Dman-pages=disabled -Ddocumentation=false \
        -Dlibmount=disabled -Dselinux=disabled -Dxattr=false -Dglib_debug=disabled \
        --force-fallback-for=pcre2,libffi,proxy-libintl \
        -Dpcre2:default_library=static -Dlibffi:default_library=static -Dproxy-libintl:default_library=static
fi

if ! have pixman-1; then
    fetch https://cairographics.org/releases/pixman-0.46.4.tar.gz d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
    unpack pixman-0.46.4.tar.gz pixman-0.46.4
    meson_build pixman pixman-0.46.4 -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled
fi

if ! have json-glib-1.0; then
    fetch https://download.gnome.org/sources/json-glib/1.10/json-glib-1.10.6.tar.xz 77f4bcbf9339528f166b8073458693f0a20b77b7059dbc2db61746a1928b0293
    unpack json-glib-1.10.6.tar.xz json-glib-1.10.6
    meson_build json-glib json-glib-1.10.6 -Dintrospection=disabled -Ddocumentation=disabled -Dman=false -Dtests=false -Dconformance=false -Dnls=disabled
fi

if ! have spice-protocol; then
    fetch https://www.spice-space.org/download/releases/spice-protocol-0.14.5.tar.xz baf58449f6e89d19f475899ad5fb9196fdc46c03cc53233f4e39cf2978f9cff7
    unpack spice-protocol-0.14.5.tar.xz spice-protocol-0.14.5
    meson_build spice-protocol spice-protocol-0.14.5
fi

if ! have spice-client-glib-2.0; then
    fetch https://www.spice-space.org/download/gtk/spice-gtk-0.42.tar.xz 9380117f1811ad1faa1812cb6602479b6290d4a0d8cc442d44427f7f6c0e7a58
    unpack spice-gtk-0.42.tar.xz spice-gtk-0.42
    patch -f -d "$BUILD/spice-gtk-0.42" -p2 < "$ROOT/patches/spice-gtk-0.42-macos-no-gstreamer.patch" > "$LOGS/spice-gtk-patch.log"
    # coroutine=ucontext (upstream's default on macOS): in-thread context switches. The gthread
    # backend hands every draw op and socket wait between two threads and is far too slow.
    # The venv python (with pyparsing/six) must be the one meson finds.
    PATH="$VENV/bin:$PATH" meson_build spice-gtk spice-gtk-0.42 \
        -Dgtk=disabled -Dwayland-protocols=disabled -Dwebdav=disabled -Dbuiltin-mjpeg=true \
        -Dusbredir=disabled -Dlibcap-ng=disabled -Dpolkit=disabled -Dcoroutine=ucontext \
        -Dintrospection=disabled -Dvapi=disabled -Dlz4=disabled -Dsasl=disabled -Dopus=disabled \
        -Dsmartcard=disabled -Degl=disabled -Dgtk_doc=disabled
fi

echo "spice-client-glib $(pkg-config --modversion spice-client-glib-2.0) installed in $PREFIX"
