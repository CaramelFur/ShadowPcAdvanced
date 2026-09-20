// C facade over spice-client-glib; keeps GLib out of Swift.
#import "../CSpiceGlue/FSSpice.h"

// UTM's Objective-C SPICE client (ThirdParty/CocoaSpice, Apache-2.0): channel
// wrappers plus the Metal renderer.
#import "CocoaSpice.h"

// Private CoreGraphics call UTM uses to grab the keyboard: while disabled, the
// system's own hot keys (⌘Tab, ⌘Space, Mission Control…) are not intercepted
// and reach the key window as ordinary key events. No permission needed; the
// mode belongs to this process's window-server connection and ends with it.
#import <CoreGraphics/CoreGraphics.h>
typedef int CGSConnectionID;
typedef CF_ENUM(uint32_t, CGSGlobalHotKeyOperatingMode) {
    kCGSGlobalHotKeyOperatingModeEnable = 0,
    kCGSGlobalHotKeyOperatingModeDisable = 1,
};
extern CGSConnectionID CGSMainConnectionID(void);
extern CGError CGSSetGlobalHotKeyOperatingMode(CGSConnectionID connection, CGSGlobalHotKeyOperatingMode mode);
