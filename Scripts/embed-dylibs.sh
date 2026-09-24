#!/bin/bash
# Xcode build phase: copy every non-system dylib the app links (spice-glib,
# glib, pixman, json-glib, openssl, jpeg — recursively) into
# Contents/Frameworks and point all references at @rpath, so the .app runs
# without ThirdParty/prefix or Homebrew. Runs before Xcode's code-sign step.
set -euo pipefail

BIN="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
FW="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$FW"

is_external() {
    case "$1" in
        /usr/lib/*|/System/*|@rpath/*|@executable_path/*|@loader_path/*) return 1 ;;
        *) return 0 ;;
    esac
}

deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

queue=("$BIN")
while [ ${#queue[@]} -gt 0 ]; do
    file="${queue[0]}"
    queue=("${queue[@]:1}")
    for dep in $(deps_of "$file"); do
        is_external "$dep" || continue
        name="$(basename "$dep")"
        # The libraries carry the absolute install names of the prefix they were
        # built in; after the checkout moves, find them by name instead.
        src="$dep"
        [ -f "$src" ] || src="$SPICE_PREFIX/lib/$name"
        if [ ! -f "$src" ]; then
            echo "error: cannot find $name (referenced as $dep)" >&2
            exit 1
        fi
        if [ ! -f "$FW/$name" ]; then
            cp -L "$src" "$FW/$name"
            chmod u+w "$FW/$name"
            install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
            queue+=("$FW/$name")
        fi
        install_name_tool -change "$dep" "@rpath/$name" "$file" 2>/dev/null
    done
done

# install_name_tool invalidated the dylibs' signatures.
for lib in "$FW"/*.dylib; do
    [ -f "$lib" ] && codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$lib" 2>/dev/null
done
echo "embedded $(ls "$FW" | wc -l | tr -d ' ') libraries"
