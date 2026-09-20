# FunkyShadow

Native macOS client for Shadow PC: sign in, list VMs, start/stop, and a SPICE
KVM console (BIOS/boot access) — a Swift port of `../shadow-cli`.

## Build

```bash
make xcodegen  # once: builds XcodeGen 2.38.0 into ThirdParty/tools (~4 min)
make deps      # once: builds spice-client-glib + deps into ThirdParty/prefix (~15 min)
make project   # generates FunkyShadow.xcodeproj from project.yml (XcodeGen)
open FunkyShadow.xcodeproj   # then ⌘R — or: make run
make test      # ShadowAPI unit tests
```

XcodeGen has no Homebrew build for macOS 13 (it demands Xcode 15.3), so
`make xcodegen` builds the pinned 2.38.0 tag into `ThirdParty/tools`.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app: login, VM list, API log, console windows |
| `App/Console/Cocoa/` | Default console: `CocoaSpiceEngine` (UTM's CocoaSpice + Metal renderer) and `SpiceMetalView` (UTM-style keyboard/pointer capture) |
| `App/Console/Native/` | Classic native console (`NativeSpiceEngine`, CALayer) plus what both share: the WebSocket splice, `RawWebSocket`, key map |
| `ThirdParty/CocoaSpice/` | UTM's CocoaSpice, vendored + patched by `Scripts/vendor-cocoaspice.sh` |
| `App/Console/WebSpiceEngine.swift` | Fallback console: vendored spice-html5 in a WKWebView |
| `CSpiceGlue/` | C facade over spice-client-glib (keeps GLib out of Swift) |
| `Packages/ShadowAPI/` | Swift package: Shadow API wrapper + `shadowctl` CLI + tests |
| `Scripts/build-spice.sh` | Pinned, checksummed source builds into a private prefix |
| `ThirdParty/patches/` | spice-gtk 0.42 patch: no GStreamer, Apple-ld link fix |

## How the native console works

Shadow exposes SPICE only over WebSocket (`wss://`, one socket per channel).
spice-client-glib speaks plain SPICE over a stream socket, but lets the client
supply that socket per channel (`spice_session_open_fd(-1)` + the `open-fd`
signal). For every channel the app creates a `socketpair`, gives one end to the
library and pumps the other to/from a WebSocket (`RawWebSocket`, on
`NWConnection`) — the "websocket splice".

The library decodes on the CPU into its own framebuffer. The default engine
hands that to UTM's CocoaSpice: the framebuffer memory is wrapped in a no-copy
`MTLBuffer`, dirty regions are blitted to a texture on the GPU and
`CSMetalRenderer` draws it (and the guest cursor) in an `MTKView`. CocoaSpice is
patched to take per-channel file descriptors and to run on GLib's default main
context (stock spice-gtk has no `spice_util_set_main_context`); one GLib thread
serves the whole process. The classic engine copies dirty rectangles into an
IOSurface shown by a CALayer instead.

Input capture (⌃⌥, or the first click in relative mouse mode) works like UTM's:
the pointer is pinned, and `CGSSetGlobalHotKeyOperatingMode` switches the
system's hot keys off so ⌘Tab, ⌘Space etc. reach the guest — no Accessibility
permission involved. Losing focus always releases everything.

GStreamer is patched out, so there is no audio and no VP8/H264 streaming; the
built-in MJPEG decoder still handles video streams.

`FunkyShadow.app/Contents/MacOS/FunkyShadow --selftest-native` smoke-tests the
GLib thread, open-fd plumbing and splice of both native engines, plus Metal
device/shader/renderer setup, without needing a VM.
