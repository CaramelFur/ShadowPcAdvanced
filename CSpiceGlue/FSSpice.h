// Thin C facade over spice-client-glib so Swift never has to import GLib.
//
// Threading: spice-glib lives on one dedicated GLib main-loop thread. Every
// fs_spice_* call may be made from any thread (it is marshalled onto the GLib
// thread); every callback is delivered ON the GLib thread.
#ifndef FS_SPICE_H
#define FS_SPICE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FSSpice FSSpice;

// SPICE channel types (spice/enums.h).
enum { FS_CHANNEL_MAIN = 1, FS_CHANNEL_DISPLAY = 2, FS_CHANNEL_INPUTS = 3, FS_CHANNEL_CURSOR = 4 };

// SpiceChannelEvent values that matter to the UI.
enum {
    FS_EVENT_OPENED = 10,
    FS_EVENT_SWITCHING = 11,
    FS_EVENT_CLOSED = 12,
    FS_EVENT_ERROR_CONNECT = 20,
    FS_EVENT_ERROR_TLS = 21,
    FS_EVENT_ERROR_LINK = 22,
    FS_EVENT_ERROR_AUTH = 23,
    FS_EVENT_ERROR_IO = 24,
};

// SPICE_SURFACE_FMT_* of the primary surface.
enum { FS_FORMAT_16_555 = 16, FS_FORMAT_32_xRGB = 32, FS_FORMAT_16_565 = 80, FS_FORMAT_32_ARGB = 96 };

typedef struct {
    void *ctx;
    // A channel needs its transport: return one end of a connected stream
    // socket (the library takes ownership), or -1 to fail the channel.
    int (*open_fd)(void *ctx, int channel_type, int channel_id);
    void (*channel_event)(void *ctx, int channel_type, int channel_id, int event);
    // `data` stays valid until display_destroy; it is only safe to read
    // inside display_invalidate (i.e. on the GLib thread).
    void (*display_create)(void *ctx, int format, int width, int height, int stride, const uint8_t *data);
    void (*display_destroy)(void *ctx);
    void (*display_invalidate)(void *ctx, int x, int y, int width, int height);
    // Straight (non-premultiplied) RGBA, width*height*4 bytes; NULL hides it.
    void (*cursor_set)(void *ctx, int width, int height, int hot_x, int hot_y, const uint8_t *rgba);
    void (*cursor_move)(void *ctx, int x, int y);
    // true = server mode (relative motion), false = client mode (absolute).
    void (*mouse_mode)(void *ctx, bool server_mode);
    void (*log)(void *ctx, const char *message);
} FSSpiceCallbacks;

FSSpice *fs_spice_new(const FSSpiceCallbacks *callbacks);
// Connect every channel through callbacks->open_fd, authenticating with `ticket`.
void fs_spice_connect(FSSpice *s, const char *ticket);
void fs_spice_disconnect(FSSpice *s);
// Disconnects, then frees once the GLib thread has let go. No callback fires
// after this returns control to the GLib thread's next iteration; `ctx` must
// stay valid until `on_freed` (may be NULL) runs.
void fs_spice_free(FSSpice *s, void (*on_freed)(void *ctx));

// PC XT set-1 scancode; 0xE0-prefixed keys are passed as (0x100 | code).
void fs_spice_key(FSSpice *s, uint32_t scancode, bool down);
// Press and release as one message, so no network delay can separate them.
void fs_spice_key_tap(FSSpice *s, uint32_t scancode);
// button_mask: bit0 left, bit1 middle, bit2 right.
void fs_spice_mouse_position(FSSpice *s, int x, int y, int button_mask);
void fs_spice_mouse_motion(FSSpice *s, int dx, int dy, int button_mask);
// button: 1 left, 2 middle, 3 right, 4 wheel up, 5 wheel down.
void fs_spice_mouse_button(FSSpice *s, int button, bool down, int button_mask);

const char *fs_spice_library_version(void);

#ifdef __cplusplus
}
#endif

#endif
