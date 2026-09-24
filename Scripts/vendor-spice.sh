#!/bin/bash
# Vendor an UNMODIFIED spice-html5 tree into the app's web resources.
#   Scripts/vendor-spice.sh                 # pinned commit, fetched from upstream
#   Scripts/vendor-spice.sh <sha>           # another commit
#   Scripts/vendor-spice.sh --from <dir>    # copy an existing checkout (offline)
# All ShadowPcAdvanced customisation lives in console.js / WKUserScripts, never here.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="https://gitlab.freedesktop.org/spice/spice-html5.git"
PIN="f3d6692f2e827bde7b41812b83a7012ff472e7b6"
DEST="App/Resources/web/spice-html5"

SRC=""
if [ "${1:-}" = "--from" ]; then
    SRC="${2:?usage: vendor-spice.sh --from <checkout dir>}"
    SHA="$(git -C "$SRC" rev-parse HEAD)"
    if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
        echo "error: $SRC has local modifications; refusing to vendor" >&2
        exit 1
    fi
else
    SHA="${1:-$PIN}"
    SRC="$(mktemp -d)"
    trap 'rm -rf "$SRC"' EXIT
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin "$REPO"
    git -C "$SRC" fetch -q --depth 1 origin "$SHA"
    git -C "$SRC" checkout -q FETCH_HEAD
fi

rm -rf "$DEST"
mkdir -p "$DEST"
# git archive exports tracked files only (no .DS_Store or other strays).
git -C "$SRC" archive HEAD src COPYING COPYING.LESSER README | tar -x -C "$DEST"

cat > "$DEST/VENDORED.md" <<EOF
spice-html5, unmodified, from $REPO
commit $SHA
License: LGPL-3.0-or-later (see COPYING, COPYING.LESSER)
Refresh with Scripts/vendor-spice.sh. Do not edit files in this directory.
EOF

# Integrity manifest checked by VendoredSpiceIntegrityTests.
( cd "$DEST" && find src -type f | LC_ALL=C sort | xargs shasum -a 256 ) > "$DEST/spice-html5.sha256"

echo "vendored spice-html5 @ $SHA into $DEST"
