// mac-rdp-connect RDP server core: a thin layer over FreeRDP's server library.
//
// Each client connection runs on its own thread, and every FreeRDP call for a
// session happens on that thread. Other threads hand work to it through the
// thread-safe mrc_session_* functions, which copy their inputs and queue them.

#ifndef MRC_SERVER_H
#define MRC_SERVER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mrc_server mrc_server;
typedef struct mrc_session mrc_session;

enum { MRC_MAX_MONITORS = 16 };

/// One client monitor in the client's virtual desktop (primary at 0,0).
typedef struct {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
    uint32_t is_primary;
    /// Windows display scale in percent (100 = unscaled).
    uint32_t scale_percent;
} mrc_monitor;

/// Callbacks run on the session thread unless noted. They must return quickly.
typedef struct {
    void *user;
    /// The client authenticated and announced its monitors. Return 0 to accept.
    int (*session_started)(void *user, mrc_session *session, const char *client_host,
                           const mrc_monitor *monitors, uint32_t count);
    /// One H.264 surface per monitor now exists; frames may be sent.
    void (*graphics_ready)(void *user, mrc_session *session);
    /// The client wants a different layout (window resized, monitors changed).
    /// Answer with mrc_session_reset_layout. Runs on a channel thread.
    void (*layout_requested)(void *user, mrc_session *session, const mrc_monitor *monitors,
                             uint32_t count);
    /// The client acknowledged frames, so more may be in flight.
    void (*frames_acked)(void *user, mrc_session *session);
    /// The client lost its picture (e.g. restored from minimized) and needs keyframes.
    void (*refresh_requested)(void *user, mrc_session *session);
    /// Input, with RDP flag semantics (KBD_FLAGS_*, PTR_FLAGS_*, PTR_XFLAGS_*).
    void (*keyboard)(void *user, mrc_session *session, uint16_t flags, uint8_t scancode);
    void (*unicode)(void *user, mrc_session *session, uint16_t flags, uint16_t code);
    void (*mouse)(void *user, mrc_session *session, uint16_t flags, uint16_t x, uint16_t y);
    void (*extended_mouse)(void *user, mrc_session *session, uint16_t flags, uint16_t x,
                           uint16_t y);
    /// The session is gone. `session` is invalid once this returns.
    void (*session_ended)(void *user, mrc_session *session);
} mrc_callbacks;

typedef struct {
    uint16_t port;
    /// Address to listen on; NULL listens on every interface.
    const char *bind_address;
    /// Holds server.crt, server.key and users.sam.
    const char *config_dir;
} mrc_server_config;

/// Starts listening. On failure returns NULL and describes why in `error`.
mrc_server *mrc_server_start(const mrc_server_config *config, const mrc_callbacks *callbacks,
                           char *error, size_t error_len);
void mrc_server_stop(mrc_server *server);

/// Queues one Annex B access unit for monitor `index`. Frames whose
/// `generation` predates the latest mrc_session_reset_layout are dropped.
int mrc_session_send_h264(mrc_session *session, uint32_t generation, uint32_t index,
                         const uint8_t *data, size_t length);
/// Frames queued or sent but not yet acknowledged by the client.
uint32_t mrc_session_frames_in_flight(mrc_session *session);
/// Replaces the client's cursor. `bgra` is top-down with straight alpha, at most
/// 96x96. NULL hides the cursor.
int mrc_session_set_pointer(mrc_session *session, const uint8_t *bgra, uint32_t width,
                           uint32_t height, uint32_t hot_x, uint32_t hot_y);
/// Recreates the surfaces for a new layout; later frames must carry `generation`.
int mrc_session_reset_layout(mrc_session *session, uint32_t generation,
                            const mrc_monitor *monitors, uint32_t count);
/// Disconnects the client.
void mrc_session_close(mrc_session *session);

/// Creates a self-signed TLS certificate in `config_dir` unless one exists.
int mrc_ensure_certificate(const char *config_dir, char *error, size_t error_len);
/// Writes users.sam so `user` can sign in with `password` (stored as an NT hash).
int mrc_write_credentials(const char *config_dir, const char *user, const char *password,
                         char *error, size_t error_len);

#ifdef __cplusplus
}
#endif

#endif
