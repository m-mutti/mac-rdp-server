// mac-rdp-server RDP server core: a thin layer over FreeRDP's server library.
//
// Each client connection runs on its own thread, and every FreeRDP call for a
// session happens on that thread. Other threads hand work to it through the
// thread-safe mrs_session_* functions, which copy their inputs and queue them.

#ifndef MRS_SERVER_H
#define MRS_SERVER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mrs_server mrs_server;
typedef struct mrs_session mrs_session;

enum { MRS_MAX_MONITORS = 16 };

/// One client monitor in the client's virtual desktop (primary at 0,0).
typedef struct {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
    uint32_t is_primary;
    /// Windows display scale in percent (100 = unscaled).
    uint32_t scale_percent;
} mrs_monitor;

/// One clipboard format (MS-RDPECLIP): a standard Windows ID such as 13 (Unicode
/// text) or 8 (bitmap), or a registered format such as "HTML Format" whose ID
/// its sender picks.
typedef struct {
    uint32_t id;
    /// NULL for standard formats.
    const char *name;
} mrs_clip_format;

/// Callbacks run on the session thread unless noted. They must return quickly.
typedef struct {
    void *user;
    /// The client authenticated and announced its monitors. Return 0 to accept.
    int (*session_started)(void *user, mrs_session *session, const char *client_host,
                           const mrs_monitor *monitors, uint32_t count);
    /// One H.264 surface per monitor now exists; frames may be sent.
    void (*graphics_ready)(void *user, mrs_session *session);
    /// The client wants a different layout (window resized, monitors changed).
    /// Answer with mrs_session_reset_layout. Runs on a channel thread.
    void (*layout_requested)(void *user, mrs_session *session, const mrs_monitor *monitors,
                             uint32_t count);
    /// The client acknowledged frames, so more may be in flight.
    void (*frames_acked)(void *user, mrs_session *session);
    /// The client lost its picture (e.g. restored from minimized) and needs keyframes.
    void (*refresh_requested)(void *user, mrs_session *session);
    /// Input, with RDP flag semantics (KBD_FLAGS_*, PTR_FLAGS_*, PTR_XFLAGS_*).
    void (*keyboard)(void *user, mrs_session *session, uint16_t flags, uint8_t scancode);
    void (*unicode)(void *user, mrs_session *session, uint16_t flags, uint16_t code);
    void (*mouse)(void *user, mrs_session *session, uint16_t flags, uint16_t x, uint16_t y);
    void (*extended_mouse)(void *user, mrs_session *session, uint16_t flags, uint16_t x,
                           uint16_t y);
    /// Whether the client accepted WebAuthn redirection (MS-RDPEWA), i.e. whether its
    /// security keys and Windows Hello can answer requests from the Mac.
    void (*webauthn_available)(void *user, mrs_session *session, int available);
    /// One WebAuthn response message from the client: a 4-byte little-endian
    /// HRESULT followed by a command-specific payload (MS-RDPEWA 2.2.2).
    void (*webauthn_response)(void *user, mrs_session *session, const uint8_t *data,
                              size_t length);
    /// The client shares its clipboard. Clipboard callbacks run on the clipboard thread.
    void (*clipboard_ready)(void *user, mrs_session *session);
    /// The client copied something it can provide in `formats`.
    void (*clipboard_offer)(void *user, mrs_session *session, const mrs_clip_format *formats,
                            uint32_t count);
    /// The client is pasting from the Mac: answer with mrs_session_clipboard_send.
    void (*clipboard_request)(void *user, mrs_session *session, uint32_t format_id);
    /// The client's answer to mrs_session_clipboard_fetch; NULL data means it failed.
    void (*clipboard_data)(void *user, mrs_session *session, const uint8_t *data, size_t length);
    /// The session is gone. `session` is invalid once this returns.
    void (*session_ended)(void *user, mrs_session *session);
} mrs_callbacks;

typedef struct {
    uint16_t port;
    /// Address to listen on; NULL listens on every interface.
    const char *bind_address;
    /// Holds server.crt, server.key and users.sam.
    const char *config_dir;
} mrs_server_config;

/// Starts listening. On failure returns NULL and describes why in `error`.
mrs_server *mrs_server_start(const mrs_server_config *config, const mrs_callbacks *callbacks,
                           char *error, size_t error_len);
void mrs_server_stop(mrs_server *server);

/// Queues one Annex B access unit for monitor `index`. Frames whose
/// `generation` predates the latest mrs_session_reset_layout are dropped.
int mrs_session_send_h264(mrs_session *session, uint32_t generation, uint32_t index,
                         const uint8_t *data, size_t length);
/// Frames queued or sent but not yet acknowledged by the client.
uint32_t mrs_session_frames_in_flight(mrs_session *session);
/// Milliseconds the client takes to acknowledge a frame, smoothed. `alone`
/// is the minimum observed over the recent 10–20 seconds; `all` includes any
/// queue building up. The baseline updates during continuous motion too.
/// Both are 0 until the first acknowledgement.
void mrs_session_ack_delay(mrs_session *session, double *alone, double *all);
/// Encoded payload bytes queued or not yet cumulatively acknowledged.
uint64_t mrs_session_video_bytes(mrs_session *session);
typedef struct {
    uint32_t frames;
    uint64_t bytes;
    uint64_t acknowledgements;
    double baseline_ms, delay_ms;
} mrs_video_state;
/// One consistent snapshot; acknowledgements is monotonic for the session.
void mrs_session_get_video_state(mrs_session *session, mrs_video_state *state);
/// Replaces the client's cursor. `bgra` is top-down with straight alpha, at most
/// 96x96. NULL hides the cursor.
int mrs_session_set_pointer(mrs_session *session, const uint8_t *bgra, uint32_t width,
                           uint32_t height, uint32_t hot_x, uint32_t hot_y);
/// Recreates the surfaces for a new layout; later frames must carry `generation`.
int mrs_session_reset_layout(mrs_session *session, uint32_t generation,
                            const mrs_monitor *monitors, uint32_t count);
/// Queues one WebAuthn request message (a CBOR map, MS-RDPEWA 2.2.1) for the client.
int mrs_session_webauthn_send(mrs_session *session, const uint8_t *data, size_t length);
/// Tells the client what the Mac clipboard now holds.
int mrs_session_clipboard_offer(mrs_session *session, const mrs_clip_format *formats,
                                uint32_t count);
/// Asks the client for its clipboard in `format_id`; the answer arrives as clipboard_data.
int mrs_session_clipboard_fetch(mrs_session *session, uint32_t format_id);
/// Answers a clipboard_request; NULL data reports failure.
int mrs_session_clipboard_send(mrs_session *session, const uint8_t *data, size_t length);
/// Disconnects the client.
void mrs_session_close(mrs_session *session);

/// Creates a self-signed TLS certificate in `config_dir` unless one exists.
int mrs_ensure_certificate(const char *config_dir, char *error, size_t error_len);
/// Writes users.sam so `user` can sign in with `password` (stored as an NT hash).
int mrs_write_credentials(const char *config_dir, const char *user, const char *password,
                         char *error, size_t error_len);

#ifdef __cplusplus
}
#endif

#endif
