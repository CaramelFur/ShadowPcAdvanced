CocoaSpice from https://github.com/utmapp/CocoaSpice.git
commit 127033fa3e59cd49678f49ed54f8adfc060afb56
License: Apache-2.0 (see LICENSE)
Modified by ThirdParty/patches/cocoaspice-shadowpcadvanced.patch:
- CSConnection: per-channel file descriptors (SPICE over the WebSocket splice)
- CSMain: iterates GLib's default context and owns it for the thread's life
  (stock spice-gtk has no spice_util_set_main_context); no GStreamer init
- renderer: shaders from the app's default.metallib, redraw after a resize
- plain #import instead of the SwiftPM module import
