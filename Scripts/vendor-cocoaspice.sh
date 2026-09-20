#!/bin/bash
# Vendor UTM's CocoaSpice (Apache-2.0) into ThirdParty/CocoaSpice and apply
# ThirdParty/patches/cocoaspice-funkyshadow.patch.
#   Scripts/vendor-cocoaspice.sh            # pinned commit, fetched from upstream
#   Scripts/vendor-cocoaspice.sh <sha>      # another commit (the patch may need a refresh)
# Left out: USB (libusb), gst_ios_init (GStreamer) and ExternalHeaders (iOS
# builds of glib/spice; ours come from ThirdParty/prefix).
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="https://github.com/utmapp/CocoaSpice.git"
PIN="127033fa3e59cd49678f49ed54f8adfc060afb56"
DEST="ThirdParty/CocoaSpice"
PATCH="ThirdParty/patches/cocoaspice-funkyshadow.patch"

SHA="${1:-$PIN}"
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
git -C "$SRC" init -q
git -C "$SRC" remote add origin "$REPO"
git -C "$SRC" fetch -q --depth 1 origin "$SHA"
git -C "$SRC" checkout -q FETCH_HEAD

rm -rf "$DEST"
mkdir -p "$DEST/CocoaSpice" "$DEST/CocoaSpiceRenderer"
cp "$SRC/LICENSE" "$DEST/"
cp "$SRC"/Sources/CocoaSpice/*.m "$SRC"/Sources/CocoaSpice/*.h "$DEST/CocoaSpice/"
cp -R "$SRC/Sources/CocoaSpice/include" "$DEST/CocoaSpice/"
cp "$SRC"/Sources/CocoaSpiceRenderer/*.m "$SRC"/Sources/CocoaSpiceRenderer/*.h "$SRC"/Sources/CocoaSpiceRenderer/*.metal "$DEST/CocoaSpiceRenderer/"
cp -R "$SRC/Sources/CocoaSpiceRenderer/include" "$DEST/CocoaSpiceRenderer/"
# USB headers stay (CocoaSpice.h includes them); the implementations do not.
rm "$DEST"/CocoaSpice/gst_ios_init.* "$DEST"/CocoaSpice/CSUSB*.m "$DEST"/CocoaSpice/CSUSB*+Protected.h
# Same file as CocoaSpiceRenderer/CSRenderer.h.
rm "$DEST/CocoaSpice/include/CSRenderer.h"

patch -d "$DEST" -p1 -f < "$PATCH"

cat > "$DEST/VENDORED.md" <<EOT
CocoaSpice from $REPO
commit $SHA
License: Apache-2.0 (see LICENSE)
Modified by $PATCH:
- CSConnection: per-channel file descriptors (SPICE over the WebSocket splice)
- CSMain: iterates GLib's default context and owns it for the thread's life
  (stock spice-gtk has no spice_util_set_main_context); no GStreamer init
- renderer: shaders from the app's default.metallib, redraw after a resize
- plain #import instead of the SwiftPM module import
EOT
echo "vendored CocoaSpice @ $SHA into $DEST"
