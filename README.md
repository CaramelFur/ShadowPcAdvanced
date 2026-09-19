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
| `App/Console/Native/` | Native console: `NativeSpiceEngine`, the WebSocket splice, display view, key map |
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
library and pumps the other to/from a `URLSessionWebSocketTask` — the
"websocket splice". The library decodes into its own framebuffer; dirty
rectangles are copied into an IOSurface that a CALayer displays.

GStreamer is patched out, so there is no audio and no VP8/H264 streaming; the
built-in MJPEG decoder still handles video streams.

`FunkyShadow.app/Contents/MacOS/FunkyShadow --selftest-native` smoke-tests the
GLib thread, open-fd plumbing and splice without needing a VM.
