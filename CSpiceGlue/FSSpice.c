#include "FSSpice.h"

#include <pthread.h>
#include <string.h>

#include <glib.h>
#include <spice-client.h>

struct FSSpice {
    FSSpiceCallbacks cb;
    SpiceSession *session;
    SpiceMainChannel *main;
    SpiceInputsChannel *inputs;
    GPtrArray *channels; // every channel we hooked, each with a ref
    gboolean dead;
};

// ---- the GLib thread --------------------------------------------------------

static pthread_once_t loop_once = PTHREAD_ONCE_INIT;

// Implemented in FSLoop.m: the process has ONE GLib thread, shared with the
// CocoaSpice engine. Two threads iterating the default context would run SPICE
// coroutines (thread-local state) on both.
extern void fs_spice_start_shared_loop(void);

static void start_loop(void) {
    fs_spice_start_shared_loop();
}

// Always queue, never run inline: g_main_context_invoke() would execute on the
// caller's thread whenever it manages to acquire the default context.
static void run_on_glib(GSourceFunc fn, gpointer data) {
    pthread_once(&loop_once, start_loop);
    GSource *source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_callback(source, fn, data, NULL);
    g_source_attach(source, NULL);
    g_source_unref(source);
}

// ---- signal handlers (GLib thread) ------------------------------------------

static void channel_ids(SpiceChannel *channel, int *type, int *id) {
    g_object_get(channel, "channel-type", type, "channel-id", id, NULL);
}

static void on_open_fd(SpiceChannel *channel, gint with_tls, gpointer user) {
    FSSpice *s = user;
    int type, id;
    channel_ids(channel, &type, &id);
    int fd = s->dead ? -1 : s->cb.open_fd(s->cb.ctx, type, id);
    if (fd < 0) {
        spice_channel_disconnect(channel, SPICE_CHANNEL_ERROR_CONNECT);
        return;
    }
    spice_channel_open_fd(channel, fd);
}

static void on_channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer user) {
    FSSpice *s = user;
    int type, id;
    if (s->dead) return;
    channel_ids(channel, &type, &id);
    s->cb.channel_event(s->cb.ctx, type, id, (int)event);
}

static void on_mouse_update(SpiceMainChannel *main, gpointer user) {
    FSSpice *s = user;
    gint mode = 0;
    if (s->dead) return;
    g_object_get(main, "mouse-mode", &mode, NULL);
    s->cb.mouse_mode(s->cb.ctx, mode == SPICE_MOUSE_MODE_SERVER);
}

static void on_primary_create(SpiceChannel *channel, gint format, gint width, gint height, gint stride,
                              gint shmid, gpointer imgdata, gpointer user) {
    FSSpice *s = user;
    if (!s->dead) s->cb.display_create(s->cb.ctx, format, width, height, stride, imgdata);
}

static void on_primary_destroy(SpiceChannel *channel, gpointer user) {
    FSSpice *s = user;
    if (!s->dead) s->cb.display_destroy(s->cb.ctx);
}

static void on_invalidate(SpiceChannel *channel, gint x, gint y, gint w, gint h, gpointer user) {
    FSSpice *s = user;
    if (!s->dead) s->cb.display_invalidate(s->cb.ctx, x, y, w, h);
}

static void on_cursor_set(SpiceCursorChannel *channel, gint width, gint height, gint hot_x, gint hot_y,
                          gpointer rgba, gpointer user) {
    FSSpice *s = user;
    if (!s->dead) s->cb.cursor_set(s->cb.ctx, width, height, hot_x, hot_y, rgba);
}

static void on_cursor_move(SpiceCursorChannel *channel, gint x, gint y, gpointer user) {
    FSSpice *s = user;
    if (!s->dead) s->cb.cursor_move(s->cb.ctx, x, y);
}

static void on_cursor_hide(SpiceCursorChannel *channel, gpointer user) {
    FSSpice *s = user;
    if (!s->dead) s->cb.cursor_set(s->cb.ctx, 0, 0, 0, 0, NULL);
}

static void on_channel_new(SpiceSession *session, SpiceChannel *channel, gpointer user) {
    FSSpice *s = user;
    int type, id;
    channel_ids(channel, &type, &id);
    // Only what a KVM console needs; audio, usbredir, webdav… are never connected.
    if (type != FS_CHANNEL_MAIN && type != FS_CHANNEL_DISPLAY && type != FS_CHANNEL_INPUTS && type != FS_CHANNEL_CURSOR) return;
    if (type != FS_CHANNEL_MAIN && id != 0) return;

    g_ptr_array_add(s->channels, g_object_ref(channel));
    g_signal_connect(channel, "open-fd", G_CALLBACK(on_open_fd), s);
    g_signal_connect(channel, "channel-event", G_CALLBACK(on_channel_event), s);

    switch (type) {
    case FS_CHANNEL_MAIN:
        s->main = SPICE_MAIN_CHANNEL(channel);
        g_signal_connect(channel, "main-mouse-update", G_CALLBACK(on_mouse_update), s);
        return; // the session connects the main channel itself
    case FS_CHANNEL_DISPLAY:
        g_signal_connect(channel, "display-primary-create", G_CALLBACK(on_primary_create), s);
        g_signal_connect(channel, "display-primary-destroy", G_CALLBACK(on_primary_destroy), s);
        g_signal_connect(channel, "display-invalidate", G_CALLBACK(on_invalidate), s);
        break;
    case FS_CHANNEL_INPUTS:
        s->inputs = SPICE_INPUTS_CHANNEL(channel);
        break;
    case FS_CHANNEL_CURSOR:
        g_signal_connect(channel, "cursor-set", G_CALLBACK(on_cursor_set), s);
        g_signal_connect(channel, "cursor-move", G_CALLBACK(on_cursor_move), s);
        g_signal_connect(channel, "cursor-hide", G_CALLBACK(on_cursor_hide), s);
        g_signal_connect(channel, "cursor-reset", G_CALLBACK(on_cursor_hide), s);
        break;
    }
    spice_channel_connect(channel);
}

// ---- lifecycle --------------------------------------------------------------

static void teardown(FSSpice *s) {
    if (!s->session) return;
    for (guint i = 0; i < s->channels->len; i++) {
        gpointer channel = g_ptr_array_index(s->channels, i);
        g_signal_handlers_disconnect_by_data(channel, s);
        g_object_unref(channel);
    }
    g_ptr_array_set_size(s->channels, 0);
    s->main = NULL;
    s->inputs = NULL;
    g_signal_handlers_disconnect_by_data(s->session, s);
    spice_session_disconnect(s->session);
    g_clear_object(&s->session);
}

FSSpice *fs_spice_new(const FSSpiceCallbacks *callbacks) {
    FSSpice *s = g_new0(FSSpice, 1);
    s->cb = *callbacks;
    s->channels = g_ptr_array_new();
    return s;
}

typedef struct { FSSpice *s; char *ticket; } ConnectJob;

static gboolean do_connect(gpointer data) {
    ConnectJob *job = data;
    FSSpice *s = job->s;
    if (!s->dead) {
        teardown(s);
        s->session = spice_session_new();
        g_object_set(s->session, "password", job->ticket, "enable-audio", FALSE, "enable-usbredir", FALSE,
                     "enable-smartcard", FALSE, NULL);
        g_signal_connect(s->session, "channel-new", G_CALLBACK(on_channel_new), s);
        // fd = -1: every channel asks for its transport through "open-fd".
        if (!spice_session_open_fd(s->session, -1)) s->cb.log(s->cb.ctx, "spice_session_open_fd failed");
    }
    memset(job->ticket, 0, strlen(job->ticket));
    g_free(job->ticket);
    g_free(job);
    return G_SOURCE_REMOVE;
}

void fs_spice_connect(FSSpice *s, const char *ticket) {
    ConnectJob *job = g_new0(ConnectJob, 1);
    job->s = s;
    job->ticket = g_strdup(ticket ? ticket : "");
    run_on_glib(do_connect, job);
}

static gboolean do_disconnect(gpointer data) {
    teardown(data);
    return G_SOURCE_REMOVE;
}

void fs_spice_disconnect(FSSpice *s) { run_on_glib(do_disconnect, s); }

typedef struct { FSSpice *s; void (*on_freed)(void *); } FreeJob;

static gboolean do_free(gpointer data) {
    FreeJob *job = data;
    FSSpice *s = job->s;
    teardown(s);
    if (job->on_freed) job->on_freed(s->cb.ctx);
    g_ptr_array_free(s->channels, TRUE);
    g_free(s);
    g_free(job);
    return G_SOURCE_REMOVE;
}

void fs_spice_free(FSSpice *s, void (*on_freed)(void *ctx)) {
    s->dead = TRUE;
    FreeJob *job = g_new0(FreeJob, 1);
    job->s = s;
    job->on_freed = on_freed;
    run_on_glib(do_free, job);
}

// ---- input ------------------------------------------------------------------

typedef struct { FSSpice *s; int kind, a, b, mask; } InputJob;
enum { IN_KEY_DOWN, IN_KEY_UP, IN_POSITION, IN_MOTION, IN_BUTTON_DOWN, IN_BUTTON_UP };

static gboolean do_input(gpointer data) {
    InputJob *job = data;
    SpiceInputsChannel *inputs = job->s->dead ? NULL : job->s->inputs;
    if (inputs) {
        switch (job->kind) {
        case IN_KEY_DOWN: spice_inputs_channel_key_press(inputs, (guint)job->a); break;
        case IN_KEY_UP: spice_inputs_channel_key_release(inputs, (guint)job->a); break;
        case IN_POSITION: spice_inputs_channel_position(inputs, job->a, job->b, 0, job->mask); break;
        case IN_MOTION: spice_inputs_channel_motion(inputs, job->a, job->b, job->mask); break;
        case IN_BUTTON_DOWN: spice_inputs_channel_button_press(inputs, job->a, job->mask); break;
        case IN_BUTTON_UP: spice_inputs_channel_button_release(inputs, job->a, job->mask); break;
        }
    }
    g_free(job);
    return G_SOURCE_REMOVE;
}

static void queue_input(FSSpice *s, int kind, int a, int b, int mask) {
    InputJob *job = g_new0(InputJob, 1);
    job->s = s; job->kind = kind; job->a = a; job->b = b; job->mask = mask;
    run_on_glib(do_input, job);
}

void fs_spice_key(FSSpice *s, uint32_t scancode, bool down) {
    queue_input(s, down ? IN_KEY_DOWN : IN_KEY_UP, (int)scancode, 0, 0);
}

void fs_spice_mouse_position(FSSpice *s, int x, int y, int button_mask) { queue_input(s, IN_POSITION, x, y, button_mask); }

void fs_spice_mouse_motion(FSSpice *s, int dx, int dy, int button_mask) { queue_input(s, IN_MOTION, dx, dy, button_mask); }

void fs_spice_mouse_button(FSSpice *s, int button, bool down, int button_mask) {
    queue_input(s, down ? IN_BUTTON_DOWN : IN_BUTTON_UP, button, 0, button_mask);
}

const char *fs_spice_library_version(void) { return spice_util_get_version_string(); }
