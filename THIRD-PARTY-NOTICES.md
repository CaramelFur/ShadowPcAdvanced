# Third-party software

All libraries below are linked dynamically and shipped as separate, replaceable
`.dylib` files in `Contents/Frameworks` (or, for spice-html5, as plain files in
`Contents/Resources/web`), which keeps the LGPL relinking requirement satisfied.

| Component | Version | License | Notes |
|---|---|---|---|
| spice-gtk (spice-client-glib) | 0.42 | LGPL-2.1-or-later | Patched: `ThirdParty/patches/spice-gtk-0.42-macos-no-gstreamer.patch` |
| spice-protocol | 0.14.5 | BSD-3-Clause | headers only |
| GLib (glib, gobject, gio, gmodule) | 2.82.5 | LGPL-2.1-or-later | bundles PCRE2 (BSD), libffi (MIT), proxy-libintl (LGPL-2.0+) statically |
| json-glib | 1.10.6 | LGPL-2.1-or-later | |
| pixman | 0.46.4 | MIT | |
| OpenSSL | 3.x (Homebrew) | Apache-2.0 | |
| libjpeg-turbo | 3.x (Homebrew) | BSD-3-Clause / IJG / zlib | |
| CocoaSpice (UTM) | 127033f | Apache-2.0 | compiled into the app; modified, see `ThirdParty/CocoaSpice/VENDORED.md` and `ThirdParty/patches/cocoaspice-shadowpcadvanced.patch` |
| spice-html5 | f3d6692 | LGPL-3.0-or-later | unmodified; see `App/Resources/web/spice-html5/VENDORED.md` |

Sources and checksums: `Scripts/build-spice.sh`, `Scripts/vendor-spice.sh`, `Scripts/vendor-cocoaspice.sh`.

`App/Console/Cocoa/SpiceMetalView.swift` follows the input-capture design of UTM's
`VMMetalView.swift` (Apache-2.0, © osy), including its use of the private
`CGSSetGlobalHotKeyOperatingMode` call.
