#import "CocoaSpice.h"

// One thread iterates GLib's default context for the whole process, whichever
// console engine asks first: CocoaSpice's, because it drains an autorelease
// pool per iteration (its SPICE callbacks create Metal objects).
void fs_spice_start_shared_loop(void) {
    [CSMain.sharedInstance spiceStart];
}
