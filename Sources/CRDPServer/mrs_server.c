#include "mrs_server.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include <winpr/crt.h>
#include <winpr/ntlm.h>
#include <winpr/path.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/thread.h>
#include <winpr/tools/makecert.h>
#include <winpr/winsock.h>
#include <winpr/wtsapi.h>

#include <freerdp/channels/channels.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/channels/wtsvc.h>
#include <freerdp/codec/color.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <freerdp/freerdp.h>
#include <freerdp/listener.h>
#include <freerdp/peer.h>
#include <freerdp/pointer.h>
#include <freerdp/server/disp.h>
#include <freerdp/server/rdpgfx.h>
#include <freerdp/channels/rdpewa.h>
#include <freerdp/server/cliprdr.h>
#include <freerdp/settings.h>

#define MRS_CERT_NAME "server"
#define MRS_SAM_NAME "users.sam"
#define MRS_MAX_POINTER 96
// Frames remembered for timing their acknowledgements: more than can be in
// flight, which is at most 15 per monitor (see FrameWindow.swift).
#define MRS_SENT_HISTORY 256

static void mrs_log(const char *fmt, ...) {
    char stamp[16];
    const time_t now = time(NULL);
    struct tm tm;
    strftime(stamp, sizeof(stamp), "%H:%M:%S", localtime_r(&now, &tm));
    fprintf(stderr, "%s [rdp] ", stamp);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void mrs_set_error(char *error, size_t len, const char *fmt, ...) {
    if (!error || len == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(error, len, fmt, ap);
    va_end(ap);
}

static char *mrs_path(const char *dir, const char *name) {
    const size_t len = strlen(dir) + strlen(name) + 2;
    char *path = malloc(len);
    if (path)
        snprintf(path, len, "%s/%s", dir, name);
    return path;
}

// MARK: - Types

typedef enum {
    MRS_JOB_FRAME,
    MRS_JOB_POINTER,
    MRS_JOB_RESET,
    MRS_JOB_WEBAUTHN,
    MRS_JOB_CLIP_OFFER,
    MRS_JOB_CLIP_FETCH,
    MRS_JOB_CLIP_SEND,
    MRS_JOB_CLOSE
} mrs_job_kind;

typedef struct mrs_job {
    struct mrs_job *next;
    mrs_job_kind kind;
    uint32_t generation;
    uint32_t index;
    uint32_t width, height, hot_x, hot_y;
    uint32_t count;
    mrs_monitor monitors[MRS_MAX_MONITORS];
    size_t length;
    uint8_t data[];
} mrs_job;

typedef struct {
    uint32_t frame_id;
    uint64_t sent_at; // GetTickCount64; 0 once acknowledged
    BOOL alone;       // nothing else was in flight
} mrs_sent_frame;

struct mrs_server {
    freerdp_listener *listener;
    rdpSettings *settings;
    mrs_callbacks callbacks;
    HANDLE stop_event;
    HANDLE thread;
};

/// Per-connection state; FreeRDP allocates it as the peer's rdpContext.
typedef struct {
    rdpContext base; // must be first
    mrs_server *server;
    HANDLE vcm;
    RdpgfxServerContext *gfx;
    DispServerContext *disp;
    UINT32 disp_channel_id;
    // WebAuthn redirection (MS-RDPEWA): opened once, then answered by the client.
    HANDLE ewa_channel;
    HANDLE ewa_event;
    UINT32 ewa_channel_id;
    BOOL ewa_requested;
    // Clipboard (MS-RDPECLIP), when the client shares its clipboard.
    CliprdrServerContext *clip;
    BOOL clip_started;
    BOOL clip_ready;
    BOOL activated, started, gfx_opened, gfx_ready, disp_opened, closing;

    // Owned by the session thread.
    mrs_monitor monitors[MRS_MAX_MONITORS];
    uint32_t monitor_count;
    uint16_t surface_ids[MRS_MAX_MONITORS];
    uint32_t surface_count;
    uint16_t next_surface_id;
    uint32_t generation;
    // Video statistics, logged periodically so a stalled client is visible.
    uint32_t stat_frames, stat_acks;
    uint64_t stat_bytes, stat_since;
    mrs_sent_frame sent[MRS_SENT_HISTORY];

    // Shared with other threads, guarded by `lock`.
    BOOL lock_ready;
    pthread_mutex_t lock;
    mrs_job *head, *tail;
    uint32_t queued_frames;
    uint32_t last_frame_id;
    uint32_t last_acked_frame_id;
    BOOL acks_suspended;
    // Milliseconds from sending a frame to its acknowledgement, smoothed.
    double ack_delay, ack_delay_alone;
    HANDLE job_event;
} mrs_peer;

static mrs_session *as_session(mrs_peer *p) { return (mrs_session *)p; }
static mrs_peer *as_peer(mrs_session *s) { return (mrs_peer *)s; }

// MARK: - Monitors

static uint32_t mrs_scale(uint32_t value, uint32_t fallback) {
    if (value >= 100 && value <= 500)
        return value;
    if (fallback >= 100 && fallback <= 500)
        return fallback;
    return 100;
}

static uint32_t mrs_read_monitors(const rdpSettings *settings, mrs_monitor *out) {
    const uint32_t global = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);
    const BOOL attributes = freerdp_settings_get_bool(settings, FreeRDP_HasMonitorAttributes);
    uint32_t count = freerdp_settings_get_uint32(settings, FreeRDP_MonitorCount);
    if (count == 0) {
        out[0] = (mrs_monitor){
            .x = 0,
            .y = 0,
            .width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
            .height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight),
            .is_primary = 1,
            .scale_percent = mrs_scale(0, global),
        };
        return 1;
    }
    if (count > MRS_MAX_MONITORS)
        count = MRS_MAX_MONITORS;
    for (uint32_t i = 0; i < count; i++) {
        const rdpMonitor *m = freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, i);
        out[i] = (mrs_monitor){
            .x = m->x,
            .y = m->y,
            .width = (uint32_t)m->width,
            .height = (uint32_t)m->height,
            .is_primary = m->is_primary ? 1 : 0,
            .scale_percent = mrs_scale(attributes ? m->attributes.desktopScaleFactor : 0, global),
        };
    }
    return count;
}

// MARK: - Graphics pipeline

static UINT32 mrs_timestamp(void) {
    SYSTEMTIME t;
    GetSystemTime(&t);
    return (UINT32)(t.wHour << 22U | t.wMinute << 16U | t.wSecond << 10U | t.wMilliseconds);
}

/// Replaces all surfaces with one per monitor, mapped where the client shows that monitor.
static BOOL mrs_create_surfaces(mrs_peer *p) {
    RdpgfxServerContext *gfx = p->gfx;
    for (uint32_t i = 0; i < p->surface_count; i++) {
        const RDPGFX_DELETE_SURFACE_PDU del = {.surfaceId = p->surface_ids[i]};
        (void)gfx->DeleteSurface(gfx, &del);
    }
    p->surface_count = 0;

    int32_t min_x = INT32_MAX, min_y = INT32_MAX, max_x = INT32_MIN, max_y = INT32_MIN;
    MONITOR_DEF defs[MRS_MAX_MONITORS];
    for (uint32_t i = 0; i < p->monitor_count; i++) {
        const mrs_monitor *m = &p->monitors[i];
        defs[i] = (MONITOR_DEF){
            .left = m->x,
            .top = m->y,
            .right = m->x + (int32_t)m->width - 1,
            .bottom = m->y + (int32_t)m->height - 1,
            .flags = m->is_primary ? MONITOR_PRIMARY : 0,
        };
        if (m->x < min_x) min_x = m->x;
        if (m->y < min_y) min_y = m->y;
        if (m->x + (int32_t)m->width > max_x) max_x = m->x + (int32_t)m->width;
        if (m->y + (int32_t)m->height > max_y) max_y = m->y + (int32_t)m->height;
    }

    const RDPGFX_RESET_GRAPHICS_PDU reset = {
        .width = (UINT32)(max_x - min_x),
        .height = (UINT32)(max_y - min_y),
        .monitorCount = p->monitor_count,
        .monitorDefArray = defs,
    };
    if (gfx->ResetGraphics(gfx, &reset) != CHANNEL_RC_OK) {
        mrs_log("ResetGraphics failed");
        return FALSE;
    }

    for (uint32_t i = 0; i < p->monitor_count; i++) {
        const mrs_monitor *m = &p->monitors[i];
        if (p->next_surface_id == 0)
            p->next_surface_id = 1;
        const uint16_t id = p->next_surface_id++;
        const RDPGFX_CREATE_SURFACE_PDU create = {
            .surfaceId = id,
            .width = (UINT16)m->width,
            .height = (UINT16)m->height,
            .pixelFormat = GFX_PIXEL_FORMAT_XRGB_8888,
        };
        // Output coordinates are relative to the top-left of the whole desktop.
        const RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU map = {
            .surfaceId = id,
            .outputOriginX = (UINT32)(m->x - min_x),
            .outputOriginY = (UINT32)(m->y - min_y),
        };
        if (gfx->CreateSurface(gfx, &create) != CHANNEL_RC_OK ||
            gfx->MapSurfaceToOutput(gfx, &map) != CHANNEL_RC_OK) {
            mrs_log("creating surface for monitor %u failed", i + 1);
            return FALSE;
        }
        p->surface_ids[i] = id;
        p->surface_count++;
    }
    mrs_log("desktop %ux%u across %u monitor(s)", reset.width, reset.height, p->monitor_count);
    return TRUE;
}

static BOOL mrs_caps_allow_avc420(const RDPGFX_CAPSET *caps) {
    switch (caps->version) {
    case RDPGFX_CAPVERSION_8:
        return FALSE;
    case RDPGFX_CAPVERSION_81:
        return (caps->flags & RDPGFX_CAPS_FLAG_AVC420_ENABLED) != 0;
    default:
        return (caps->flags & RDPGFX_CAPS_FLAG_AVC_DISABLED) == 0;
    }
}

static UINT mrs_gfx_caps_advertise(RdpgfxServerContext *gfx, const RDPGFX_CAPS_ADVERTISE_PDU *pdu) {
    mrs_peer *p = gfx->custom;
    static const UINT32 preferred[] = {
        RDPGFX_CAPVERSION_107, RDPGFX_CAPVERSION_106, RDPGFX_CAPVERSION_106_ERR,
        RDPGFX_CAPVERSION_105, RDPGFX_CAPVERSION_104, RDPGFX_CAPVERSION_103,
        RDPGFX_CAPVERSION_102, RDPGFX_CAPVERSION_101, RDPGFX_CAPVERSION_10,
        RDPGFX_CAPVERSION_81,
    };
    for (size_t v = 0; v < ARRAYSIZE(preferred); v++) {
        for (UINT16 i = 0; i < pdu->capsSetCount; i++) {
            const RDPGFX_CAPSET *offered = &pdu->capsSets[i];
            if (offered->version != preferred[v] || !mrs_caps_allow_avc420(offered))
                continue;

            RDPGFX_CAPSET caps = *offered;
            const RDPGFX_CAPS_CONFIRM_PDU confirm = {.capsSet = &caps};
            const UINT rc = gfx->CapsConfirm(gfx, &confirm);
            if (rc != CHANNEL_RC_OK)
                return rc;
            mrs_log("graphics pipeline 0x%08x with H.264", caps.version);
            p->gfx_ready = TRUE;
            if (!mrs_create_surfaces(p))
                return ERROR_INTERNAL_ERROR;
            p->server->callbacks.graphics_ready(p->server->callbacks.user, as_session(p));
            return CHANNEL_RC_OK;
        }
    }
    mrs_log("client cannot decode H.264 (AVC420); disconnecting");
    p->closing = TRUE;
    return CHANNEL_RC_OK;
}

/// Running average that follows changes within about eight samples, like
/// TCP's round-trip estimate. Zero means no samples yet.
static void mrs_smooth(double *average, double sample) {
    *average = *average == 0 ? sample : *average + (sample - *average) / 8;
}

static UINT mrs_gfx_frame_ack(RdpgfxServerContext *gfx, const RDPGFX_FRAME_ACKNOWLEDGE_PDU *ack) {
    mrs_peer *p = gfx->custom;
    // The channel is serviced on the session thread, which also sends.
    mrs_sent_frame *sent = &p->sent[ack->frameId % MRS_SENT_HISTORY];
    double delay = -1;
    if (sent->frame_id == ack->frameId && sent->sent_at != 0) {
        delay = (double)(GetTickCount64() - sent->sent_at);
        sent->sent_at = 0;
    }
    pthread_mutex_lock(&p->lock);
    p->last_acked_frame_id = ack->frameId;
    p->acks_suspended = ack->queueDepth == SUSPEND_FRAME_ACKNOWLEDGEMENT;
    if (delay >= 0) {
        mrs_smooth(&p->ack_delay, delay);
        if (sent->alone)
            mrs_smooth(&p->ack_delay_alone, delay);
    }
    pthread_mutex_unlock(&p->lock);
    p->stat_acks++;
    p->server->callbacks.frames_acked(p->server->callbacks.user, as_session(p));
    return CHANNEL_RC_OK;
}

static void mrs_send_frame(mrs_peer *p, const mrs_job *job) {
    if (!p->gfx_ready || job->generation != p->generation || job->index >= p->surface_count)
        return;
    const mrs_monitor *m = &p->monitors[job->index];

    RECTANGLE_16 rect = {.left = 0, .top = 0, .right = (UINT16)m->width, .bottom = (UINT16)m->height};
    RDPGFX_H264_QUANT_QUALITY quality = {.qp = 22, .r = 0, .p = 0, .qualityVal = 100};
    RDPGFX_AVC420_BITMAP_STREAM avc = {
        .meta = {.numRegionRects = 1, .regionRects = &rect, .quantQualityVals = &quality},
        .length = (UINT32)job->length,
        .data = (BYTE *)job->data,
    };
    RDPGFX_SURFACE_COMMAND cmd = {
        .surfaceId = p->surface_ids[job->index],
        .codecId = RDPGFX_CODECID_AVC420,
        .format = PIXEL_FORMAT_BGRX32,
        .right = m->width,
        .bottom = m->height,
        .width = m->width,
        .height = m->height,
        .extra = &avc,
    };

    pthread_mutex_lock(&p->lock);
    const BOOL alone = !p->acks_suspended && p->last_frame_id == p->last_acked_frame_id;
    const UINT32 frame_id = ++p->last_frame_id;
    pthread_mutex_unlock(&p->lock);
    p->sent[frame_id % MRS_SENT_HISTORY] =
        (mrs_sent_frame){.frame_id = frame_id, .sent_at = GetTickCount64(), .alone = alone};

    const RDPGFX_START_FRAME_PDU start = {.timestamp = mrs_timestamp(), .frameId = frame_id};
    const RDPGFX_END_FRAME_PDU end = {.frameId = frame_id};
    if (p->gfx->SurfaceFrameCommand(p->gfx, &cmd, &start, &end) != CHANNEL_RC_OK) {
        mrs_log("sending frame failed; disconnecting");
        p->closing = TRUE;
        return;
    }
    p->stat_frames++;
    p->stat_bytes += job->length;
}

static void mrs_report_stats(mrs_peer *p) {
    const uint64_t now = GetTickCount64();
    if (p->stat_since == 0)
        p->stat_since = now;
    const uint64_t elapsed = now - p->stat_since;
    if (elapsed < 5000 || (p->stat_frames == 0 && p->stat_acks == 0))
        return;
    // Frames sent but never acknowledged mean the client cannot decode them.
    double delay = 0, alone = 0;
    mrs_session_ack_delay(as_session(p), &alone, &delay);
    mrs_log("video: %.1f fps sent, %.1f fps acknowledged, %.1f Mbit/s, %u in flight, "
            "acknowledged in %.0f ms (%.0f ms alone)",
           p->stat_frames * 1000.0 / elapsed, p->stat_acks * 1000.0 / elapsed,
           p->stat_bytes * 8.0 / 1000.0 / elapsed, mrs_session_frames_in_flight(as_session(p)),
           delay, alone);
    p->stat_frames = p->stat_acks = 0;
    p->stat_bytes = 0;
    p->stat_since = now;
}

// MARK: - Pointer

static void mrs_send_pointer(mrs_peer *p, const mrs_job *job) {
    rdpPointerUpdate *pointer = p->base.update->pointer;
    if (!p->activated)
        return;
    if (job->length == 0) {
        const POINTER_SYSTEM_UPDATE hidden = {.type = SYSPTR_NULL};
        (void)pointer->PointerSystem(&p->base, &hidden);
        return;
    }

    // RDP pointers are stored bottom-up, with a 1bpp AND mask padded to 16 bits per row.
    const uint32_t w = job->width, h = job->height;
    const uint32_t xor_stride = w * 4;
    const uint32_t and_stride = ((w + 15) / 16) * 2;
    BYTE *xor_mask = calloc(h, xor_stride);
    BYTE *and_mask = calloc(h, and_stride);
    if (!xor_mask || !and_mask)
        goto out;
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *src = job->data + (size_t)y * xor_stride;
        BYTE *dst = xor_mask + (size_t)(h - 1 - y) * xor_stride;
        BYTE *and_row = and_mask + (size_t)(h - 1 - y) * and_stride;
        memcpy(dst, src, xor_stride);
        for (uint32_t x = 0; x < w; x++) {
            if (src[x * 4 + 3] == 0)
                and_row[x / 8] |= (BYTE)(0x80 >> (x % 8));
        }
    }

    const POINTER_NEW_UPDATE update = {
        .xorBpp = 32,
        .colorPtrAttr = {
            .cacheIndex = 0,
            .hotSpotX = (UINT16)job->hot_x,
            .hotSpotY = (UINT16)job->hot_y,
            .width = (UINT16)w,
            .height = (UINT16)h,
            .lengthAndMask = (UINT16)(h * and_stride),
            .lengthXorMask = (UINT16)(h * xor_stride),
            .xorMaskData = xor_mask,
            .andMaskData = and_mask,
        },
    };
    (void)pointer->PointerNew(&p->base, &update);
out:
    free(xor_mask);
    free(and_mask);
}

// MARK: - Job queue

static int mrs_enqueue(mrs_peer *p, mrs_job *job) {
    job->next = NULL;
    pthread_mutex_lock(&p->lock);
    if (p->tail)
        p->tail->next = job;
    else
        p->head = job;
    p->tail = job;
    if (job->kind == MRS_JOB_FRAME)
        p->queued_frames++;
    pthread_mutex_unlock(&p->lock);
    SetEvent(p->job_event);
    return 0;
}

static void mrs_send_webauthn(mrs_peer *p, const mrs_job *job) {
    ULONG written = 0;
    if (!p->ewa_channel ||
        !WTSVirtualChannelWrite(p->ewa_channel, (PCHAR)job->data, (ULONG)job->length, &written))
        mrs_log("could not send a WebAuthn request");
}

// MARK: - Clipboard

// Offered formats travel through the job queue packed as
// [uint32 id][uint16 name length][name bytes], repeated.

static void mrs_run_clipboard_job(mrs_peer *p, const mrs_job *job) {
    CliprdrServerContext *clip = p->clip;
    if (!p->clip_started)
        return;
    UINT rc = CHANNEL_RC_OK;
    switch (job->kind) {
    case MRS_JOB_CLIP_OFFER: {
        CLIPRDR_FORMAT formats[64];
        char *names[64] = {0};
        uint32_t count = 0;
        size_t at = 0;
        while (count < 64 && at + 6 <= job->length) {
            uint32_t id;
            uint16_t name_length;
            memcpy(&id, job->data + at, 4);
            memcpy(&name_length, job->data + at + 4, 2);
            at += 6;
            if (at + name_length > job->length)
                break;
            names[count] = name_length ? strndup((const char *)job->data + at, name_length) : NULL;
            formats[count] = (CLIPRDR_FORMAT){.formatId = id, .formatName = names[count]};
            at += name_length;
            count++;
        }
        const CLIPRDR_FORMAT_LIST list = {
            .common = {.msgType = CB_FORMAT_LIST}, .numFormats = count, .formats = formats};
        rc = clip->ServerFormatList(clip, &list);
        for (uint32_t i = 0; i < count; i++)
            free(names[i]);
        break;
    }
    case MRS_JOB_CLIP_FETCH: {
        const CLIPRDR_FORMAT_DATA_REQUEST request = {
            .common = {.msgType = CB_FORMAT_DATA_REQUEST}, .requestedFormatId = job->index};
        rc = clip->ServerFormatDataRequest(clip, &request);
        break;
    }
    case MRS_JOB_CLIP_SEND: {
        const BOOL ok = job->generation != 0;
        const CLIPRDR_FORMAT_DATA_RESPONSE response = {
            .common = {.msgType = CB_FORMAT_DATA_RESPONSE,
                       .msgFlags = ok ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
                       .dataLen = ok ? (UINT32)job->length : 0},
            .requestedFormatData = ok ? job->data : NULL,
        };
        rc = clip->ServerFormatDataResponse(clip, &response);
        break;
    }
    default:
        break;
    }
    if (rc != CHANNEL_RC_OK)
        mrs_log("clipboard message failed (%u)", rc);
}

/// Clients announce capabilities, then what they copied; some skip the
/// capabilities, so either one means sharing is ready.
static void mrs_clip_mark_ready(mrs_peer *p) {
    if (p->clip_ready)
        return;
    p->clip_ready = TRUE;
    p->server->callbacks.clipboard_ready(p->server->callbacks.user, as_session(p));
}

static UINT mrs_clip_client_capabilities(CliprdrServerContext *clip,
                                         const CLIPRDR_CAPABILITIES *caps) {
    WINPR_UNUSED(caps);
    mrs_clip_mark_ready(clip->custom);
    return CHANNEL_RC_OK;
}

static UINT mrs_clip_client_format_list(CliprdrServerContext *clip,
                                        const CLIPRDR_FORMAT_LIST *list) {
    mrs_peer *p = clip->custom;
    mrs_clip_mark_ready(p);
    const CLIPRDR_FORMAT_LIST_RESPONSE ack = {
        .common = {.msgType = CB_FORMAT_LIST_RESPONSE, .msgFlags = CB_RESPONSE_OK}};
    const UINT rc = clip->ServerFormatListResponse(clip, &ack);
    mrs_clip_format formats[64];
    const uint32_t count = list->numFormats < 64 ? list->numFormats : 64;
    for (uint32_t i = 0; i < count; i++)
        formats[i] = (mrs_clip_format){.id = list->formats[i].formatId,
                                       .name = list->formats[i].formatName};
    p->server->callbacks.clipboard_offer(p->server->callbacks.user, as_session(p), formats, count);
    return rc;
}

static UINT mrs_clip_client_data_request(CliprdrServerContext *clip,
                                         const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    mrs_peer *p = clip->custom;
    p->server->callbacks.clipboard_request(p->server->callbacks.user, as_session(p),
                                           request->requestedFormatId);
    return CHANNEL_RC_OK;
}

static UINT mrs_clip_client_data_response(CliprdrServerContext *clip,
                                          const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    mrs_peer *p = clip->custom;
    const BOOL ok = (response->common.msgFlags & CB_RESPONSE_OK) != 0;
    p->server->callbacks.clipboard_data(p->server->callbacks.user, as_session(p),
                                        ok ? response->requestedFormatData : NULL,
                                        ok ? response->common.dataLen : 0);
    return CHANNEL_RC_OK;
}

static UINT mrs_clip_ignore_format_list_response(CliprdrServerContext *clip,
                                                 const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    WINPR_UNUSED(clip);
    WINPR_UNUSED(response);
    return CHANNEL_RC_OK;
}

static UINT mrs_clip_ignore_temp_directory(CliprdrServerContext *clip,
                                           const CLIPRDR_TEMP_DIRECTORY *dir) {
    WINPR_UNUSED(clip);
    WINPR_UNUSED(dir);
    return CHANNEL_RC_OK;
}

/// Starts clipboard sharing if the client joined the clipboard channel.
static void mrs_start_clipboard(mrs_peer *p) {
    if (!WTSVirtualChannelManagerIsChannelJoined(p->vcm, CLIPRDR_SVC_CHANNEL_NAME))
        return;
    CliprdrServerContext *clip = cliprdr_server_context_new(p->vcm);
    if (!clip)
        return;
    clip->custom = p;
    clip->rdpcontext = &p->base;
    clip->useLongFormatNames = TRUE;
    clip->streamFileClipEnabled = FALSE;
    clip->fileClipNoFilePaths = TRUE;
    clip->canLockClipData = FALSE;
    clip->ClientCapabilities = mrs_clip_client_capabilities;
    clip->ClientFormatList = mrs_clip_client_format_list;
    clip->ClientFormatListResponse = mrs_clip_ignore_format_list_response;
    clip->ClientFormatDataRequest = mrs_clip_client_data_request;
    clip->ClientFormatDataResponse = mrs_clip_client_data_response;
    clip->TempDirectory = mrs_clip_ignore_temp_directory;
    p->clip = clip;
    p->clip_started = clip->Start(clip) == CHANNEL_RC_OK;
    if (!p->clip_started)
        mrs_log("could not start clipboard sharing");
}

static void mrs_run_jobs(mrs_peer *p) {
    pthread_mutex_lock(&p->lock);
    mrs_job *job = p->head;
    p->head = p->tail = NULL;
    ResetEvent(p->job_event);
    pthread_mutex_unlock(&p->lock);

    while (job) {
        mrs_job *next = job->next;
        switch (job->kind) {
        case MRS_JOB_FRAME:
            if (!p->closing)
                mrs_send_frame(p, job);
            pthread_mutex_lock(&p->lock);
            p->queued_frames--;
            pthread_mutex_unlock(&p->lock);
            break;
        case MRS_JOB_POINTER:
            mrs_send_pointer(p, job);
            break;
        case MRS_JOB_RESET:
            memcpy(p->monitors, job->monitors, sizeof(mrs_monitor) * job->count);
            p->monitor_count = job->count;
            p->generation = job->generation;
            if (p->gfx_ready && !mrs_create_surfaces(p))
                p->closing = TRUE;
            break;
        case MRS_JOB_WEBAUTHN:
            mrs_send_webauthn(p, job);
            break;
        case MRS_JOB_CLIP_OFFER:
        case MRS_JOB_CLIP_FETCH:
        case MRS_JOB_CLIP_SEND:
            mrs_run_clipboard_job(p, job);
            break;
        case MRS_JOB_CLOSE:
            p->closing = TRUE;
            break;
        }
        free(job);
        job = next;
    }
}

static mrs_job *mrs_job_new(mrs_job_kind kind, size_t length) {
    mrs_job *job = calloc(1, sizeof(mrs_job) + length);
    if (job) {
        job->kind = kind;
        job->length = length;
    }
    return job;
}

int mrs_session_send_h264(mrs_session *session, uint32_t generation, uint32_t index,
                         const uint8_t *data, size_t length) {
    mrs_job *job = mrs_job_new(MRS_JOB_FRAME, length);
    if (!job)
        return -1;
    job->generation = generation;
    job->index = index;
    memcpy(job->data, data, length);
    return mrs_enqueue(as_peer(session), job);
}

uint32_t mrs_session_frames_in_flight(mrs_session *session) {
    mrs_peer *p = as_peer(session);
    pthread_mutex_lock(&p->lock);
    uint32_t n = p->queued_frames;
    if (!p->acks_suspended)
        n += p->last_frame_id - p->last_acked_frame_id;
    pthread_mutex_unlock(&p->lock);
    return n;
}

void mrs_session_ack_delay(mrs_session *session, double *alone, double *all) {
    mrs_peer *p = as_peer(session);
    pthread_mutex_lock(&p->lock);
    *alone = p->ack_delay_alone;
    *all = p->ack_delay;
    pthread_mutex_unlock(&p->lock);
}

int mrs_session_set_pointer(mrs_session *session, const uint8_t *bgra, uint32_t width,
                           uint32_t height, uint32_t hot_x, uint32_t hot_y) {
    if (bgra && (width == 0 || height == 0 || width > MRS_MAX_POINTER || height > MRS_MAX_POINTER))
        return -1;
    const size_t length = bgra ? (size_t)width * height * 4 : 0;
    mrs_job *job = mrs_job_new(MRS_JOB_POINTER, length);
    if (!job)
        return -1;
    job->width = width;
    job->height = height;
    job->hot_x = hot_x < width ? hot_x : 0;
    job->hot_y = hot_y < height ? hot_y : 0;
    if (bgra)
        memcpy(job->data, bgra, length);
    return mrs_enqueue(as_peer(session), job);
}

int mrs_session_reset_layout(mrs_session *session, uint32_t generation, const mrs_monitor *monitors,
                            uint32_t count) {
    if (count == 0 || count > MRS_MAX_MONITORS)
        return -1;
    mrs_job *job = mrs_job_new(MRS_JOB_RESET, 0);
    if (!job)
        return -1;
    job->generation = generation;
    job->count = count;
    memcpy(job->monitors, monitors, sizeof(mrs_monitor) * count);
    return mrs_enqueue(as_peer(session), job);
}

int mrs_session_webauthn_send(mrs_session *session, const uint8_t *data, size_t length) {
    mrs_job *job = mrs_job_new(MRS_JOB_WEBAUTHN, length);
    if (!job)
        return -1;
    memcpy(job->data, data, length);
    return mrs_enqueue(as_peer(session), job);
}

int mrs_session_clipboard_offer(mrs_session *session, const mrs_clip_format *formats,
                                uint32_t count) {
    size_t length = 0;
    for (uint32_t i = 0; i < count; i++)
        length += 6 + (formats[i].name ? strlen(formats[i].name) : 0);
    mrs_job *job = mrs_job_new(MRS_JOB_CLIP_OFFER, length);
    if (!job)
        return -1;
    size_t at = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint16_t name_length = formats[i].name ? (uint16_t)strlen(formats[i].name) : 0;
        memcpy(job->data + at, &formats[i].id, 4);
        memcpy(job->data + at + 4, &name_length, 2);
        if (name_length)
            memcpy(job->data + at + 6, formats[i].name, name_length);
        at += 6 + name_length;
    }
    return mrs_enqueue(as_peer(session), job);
}

int mrs_session_clipboard_fetch(mrs_session *session, uint32_t format_id) {
    mrs_job *job = mrs_job_new(MRS_JOB_CLIP_FETCH, 0);
    if (!job)
        return -1;
    job->index = format_id;
    return mrs_enqueue(as_peer(session), job);
}

int mrs_session_clipboard_send(mrs_session *session, const uint8_t *data, size_t length) {
    mrs_job *job = mrs_job_new(MRS_JOB_CLIP_SEND, data ? length : 0);
    if (!job)
        return -1;
    job->generation = data != NULL; // success flag
    if (data)
        memcpy(job->data, data, length);
    return mrs_enqueue(as_peer(session), job);
}

void mrs_session_close(mrs_session *session) {
    mrs_job *job = mrs_job_new(MRS_JOB_CLOSE, 0);
    if (job)
        mrs_enqueue(as_peer(session), job);
}

// MARK: - Display control (live re-layout)

static BOOL mrs_disp_channel_assigned(DispServerContext *disp, UINT32 channel_id) {
    ((mrs_peer *)disp->custom)->disp_channel_id = channel_id;
    return TRUE;
}

static BOOL mrs_dvc_created(void *userdata, UINT32 channel_id, INT32 status) {
    mrs_peer *p = userdata;
    // Capabilities can only go out once the client has accepted the channel.
    if (p->disp && channel_id == p->disp_channel_id && status >= 0)
        (void)p->disp->DisplayControlCaps(p->disp);
    if (p->ewa_channel && channel_id == p->ewa_channel_id) {
        // Clients refuse the channel when WebAuthn redirection is off or unsupported.
        mrs_log("WebAuthn redirection %s by the client", status >= 0 ? "accepted" : "refused");
        p->server->callbacks.webauthn_available(p->server->callbacks.user, as_session(p),
                                                status >= 0);
    }
    return TRUE;
}

// MARK: - WebAuthn redirection

static void mrs_open_webauthn(mrs_peer *p) {
    DWORD session_id = WTS_CURRENT_SESSION;
    PULONG queried = NULL;
    DWORD bytes = 0;
    if (WTSQuerySessionInformationA(p->vcm, WTS_CURRENT_SESSION, WTSSessionId, (LPSTR *)&queried,
                                    &bytes) &&
        queried) {
        session_id = *queried;
        WTSFreeMemory(queried);
    }
    p->ewa_channel = WTSVirtualChannelOpenEx(session_id, RDPEWA_DVC_CHANNEL_NAME,
                                             WTS_CHANNEL_OPTION_DYNAMIC);
    if (!p->ewa_channel) {
        p->server->callbacks.webauthn_available(p->server->callbacks.user, as_session(p), 0);
        return;
    }
    p->ewa_channel_id = WTSChannelGetIdByHandle(p->ewa_channel);
    void *buffer = NULL;
    if (WTSVirtualChannelQuery(p->ewa_channel, WTSVirtualEventHandle, &buffer, &bytes) &&
        bytes == sizeof(HANDLE))
        p->ewa_event = *(HANDLE *)buffer;
    WTSFreeMemory(buffer);
}

/// Hands every complete WebAuthn message the client sent to the host.
static void mrs_read_webauthn(mrs_peer *p) {
    ULONG size = 0;
    while (WTSVirtualChannelRead(p->ewa_channel, 0, NULL, 0, &size) && size > 0) {
        BYTE *message = malloc(size);
        ULONG read = 0;
        if (!message)
            return;
        if (WTSVirtualChannelRead(p->ewa_channel, 0, (PCHAR)message, size, &read) && read > 0)
            p->server->callbacks.webauthn_response(p->server->callbacks.user, as_session(p),
                                                   message, read);
        free(message);
    }
}

static UINT mrs_disp_layout(DispServerContext *disp, const DISPLAY_CONTROL_MONITOR_LAYOUT_PDU *pdu) {
    mrs_peer *p = disp->custom;
    mrs_monitor monitors[MRS_MAX_MONITORS];
    const uint32_t count = pdu->NumMonitors < MRS_MAX_MONITORS ? pdu->NumMonitors : MRS_MAX_MONITORS;
    if (count == 0)
        return CHANNEL_RC_OK;
    for (uint32_t i = 0; i < count; i++) {
        const DISPLAY_CONTROL_MONITOR_LAYOUT *m = &pdu->Monitors[i];
        monitors[i] = (mrs_monitor){
            .x = m->Left,
            .y = m->Top,
            .width = m->Width,
            .height = m->Height,
            .is_primary = (m->Flags & DISPLAY_CONTROL_MONITOR_PRIMARY) ? 1 : 0,
            .scale_percent = mrs_scale(m->DesktopScaleFactor, 100),
        };
    }
    p->server->callbacks.layout_requested(p->server->callbacks.user, as_session(p), monitors, count);
    return CHANNEL_RC_OK;
}

// MARK: - Input

static BOOL mrs_on_keyboard(rdpInput *input, UINT16 flags, UINT8 code) {
    mrs_peer *p = (mrs_peer *)input->context;
    p->server->callbacks.keyboard(p->server->callbacks.user, as_session(p), flags, code);
    return TRUE;
}

static BOOL mrs_on_unicode(rdpInput *input, UINT16 flags, UINT16 code) {
    mrs_peer *p = (mrs_peer *)input->context;
    p->server->callbacks.unicode(p->server->callbacks.user, as_session(p), flags, code);
    return TRUE;
}

static BOOL mrs_on_mouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
    mrs_peer *p = (mrs_peer *)input->context;
    p->server->callbacks.mouse(p->server->callbacks.user, as_session(p), flags, x, y);
    return TRUE;
}

static BOOL mrs_on_extended_mouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
    mrs_peer *p = (mrs_peer *)input->context;
    p->server->callbacks.extended_mouse(p->server->callbacks.user, as_session(p), flags, x, y);
    return TRUE;
}

static BOOL mrs_on_synchronize(rdpInput *input, UINT32 flags) {
    WINPR_UNUSED(input);
    WINPR_UNUSED(flags);
    return TRUE;
}

static BOOL mrs_on_focus_in(rdpInput *input, UINT16 toggle_states) {
    WINPR_UNUSED(input);
    WINPR_UNUSED(toggle_states);
    return TRUE;
}

static BOOL mrs_on_pause(rdpInput *input) {
    WINPR_UNUSED(input);
    return TRUE;
}

static BOOL mrs_on_rel_mouse(rdpInput *input, UINT16 flags, INT16 dx, INT16 dy) {
    WINPR_UNUSED(input);
    WINPR_UNUSED(flags);
    WINPR_UNUSED(dx);
    WINPR_UNUSED(dy);
    return TRUE;
}

static BOOL mrs_refresh_rect(rdpContext *context, BYTE count, const RECTANGLE_16 *areas) {
    WINPR_UNUSED(count);
    WINPR_UNUSED(areas);
    mrs_peer *p = (mrs_peer *)context;
    if (p->started)
        p->server->callbacks.refresh_requested(p->server->callbacks.user, as_session(p));
    return TRUE;
}

static BOOL mrs_suppress_output(rdpContext *context, BYTE allow, const RECTANGLE_16 *area) {
    WINPR_UNUSED(area);
    mrs_peer *p = (mrs_peer *)context;
    // Coming back from minimized: the client discarded its picture.
    if (allow && p->started)
        p->server->callbacks.refresh_requested(p->server->callbacks.user, as_session(p));
    return TRUE;
}

// MARK: - Session lifecycle

static BOOL mrs_peer_context_new(freerdp_peer *client, rdpContext *context) {
    mrs_peer *p = (mrs_peer *)context;
    p->server = client->ContextExtra;
    p->next_surface_id = 1;
    p->vcm = WTSOpenServerA((LPSTR)context);
    if (!p->vcm || p->vcm == INVALID_HANDLE_VALUE)
        return FALSE;
    if (pthread_mutex_init(&p->lock, NULL) != 0)
        return FALSE;
    p->lock_ready = TRUE;
    p->job_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    return p->job_event != NULL;
}

static void mrs_peer_context_free(freerdp_peer *client, rdpContext *context) {
    WINPR_UNUSED(client);
    mrs_peer *p = (mrs_peer *)context;
    if (!p)
        return;
    if (p->gfx)
        rdpgfx_server_context_free(p->gfx);
    if (p->disp)
        disp_server_context_free(p->disp);
    if (p->clip)
        cliprdr_server_context_free(p->clip);
    for (mrs_job *job = p->head; job;) {
        mrs_job *next = job->next;
        free(job);
        job = next;
    }
    if (p->job_event)
        (void)CloseHandle(p->job_event);
    if (p->lock_ready)
        pthread_mutex_destroy(&p->lock);
    if (p->vcm && p->vcm != INVALID_HANDLE_VALUE)
        WTSCloseServer(p->vcm);
}

static BOOL mrs_post_connect(freerdp_peer *client) {
    mrs_peer *p = (mrs_peer *)client->context;
    rdpSettings *settings = client->context->settings;

    if (!freerdp_settings_get_bool(settings, FreeRDP_SupportGraphicsPipeline)) {
        mrs_log("%s: client does not support the graphics pipeline", client->hostname);
        return FALSE;
    }

    p->monitor_count = mrs_read_monitors(settings, p->monitors);
    mrs_log("%s signed in as %s, %u monitor(s)", client->hostname,
           freerdp_settings_get_string(settings, FreeRDP_Username), p->monitor_count);

    const mrs_callbacks *cb = &p->server->callbacks;
    if (cb->session_started(cb->user, as_session(p), client->hostname, p->monitors,
                            p->monitor_count) != 0) {
        mrs_log("%s: session refused", client->hostname);
        return FALSE;
    }
    p->started = TRUE;

    p->gfx = rdpgfx_server_context_new(p->vcm);
    if (!p->gfx)
        return FALSE;
    p->gfx->rdpcontext = client->context;
    p->gfx->custom = p;
    p->gfx->CapsAdvertise = mrs_gfx_caps_advertise;
    p->gfx->FrameAcknowledge = mrs_gfx_frame_ack;
    if (!p->gfx->Initialize(p->gfx, TRUE))
        return FALSE;

    p->disp = disp_server_context_new(p->vcm);
    if (p->disp) {
        p->disp->rdpcontext = client->context;
        p->disp->custom = p;
        p->disp->MaxNumMonitors = MRS_MAX_MONITORS;
        p->disp->MaxMonitorAreaFactorA = 8192;
        p->disp->MaxMonitorAreaFactorB = 8192;
        p->disp->DispMonitorLayout = mrs_disp_layout;
        p->disp->ChannelIdAssigned = mrs_disp_channel_assigned;
    }
    WTSVirtualChannelManagerSetDVCCreationCallback(p->vcm, mrs_dvc_created, p);
    mrs_start_clipboard(p);
    return TRUE;
}

static BOOL mrs_activate(freerdp_peer *client) {
    ((mrs_peer *)client->context)->activated = TRUE;
    return TRUE;
}

/// Dynamic channels (graphics, display control) can only open once the client
/// finished activation and its drdynvc channel is up.
static BOOL mrs_open_dynamic_channels(mrs_peer *p) {
    if (!p->activated || !WTSVirtualChannelManagerIsChannelJoined(p->vcm, DRDYNVC_SVC_CHANNEL_NAME))
        return TRUE;
    switch (WTSVirtualChannelManagerGetDrdynvcState(p->vcm)) {
    case DRDYNVC_STATE_NONE:
        return WTSVirtualChannelManagerCheckFileDescriptor(p->vcm);
    case DRDYNVC_STATE_READY:
        if (p->gfx && !p->gfx_opened) {
            if (!p->gfx->Open(p->gfx)) {
                mrs_log("could not open the graphics channel");
                return FALSE;
            }
            p->gfx_opened = TRUE;
        }
        if (p->disp && !p->disp_opened) {
            p->disp_opened = p->disp->Open(p->disp) == CHANNEL_RC_OK;
            if (!p->disp_opened)
                mrs_log("display control unavailable; window resizing will not adapt");
        }
        if (!p->ewa_requested) {
            p->ewa_requested = TRUE;
            mrs_open_webauthn(p);
        }
        return TRUE;
    default:
        return TRUE;
    }
}

static DWORD WINAPI mrs_session_thread(LPVOID arg) {
    freerdp_peer *client = arg;
    mrs_peer *p = (mrs_peer *)client->context;
    mrs_server *server = p->server;

    client->PostConnect = mrs_post_connect;
    client->Activate = mrs_activate;
    rdpInput *input = client->context->input;
    input->KeyboardEvent = mrs_on_keyboard;
    input->UnicodeKeyboardEvent = mrs_on_unicode;
    input->MouseEvent = mrs_on_mouse;
    input->ExtendedMouseEvent = mrs_on_extended_mouse;
    input->SynchronizeEvent = mrs_on_synchronize;
    input->FocusInEvent = mrs_on_focus_in;
    input->KeyboardPauseEvent = mrs_on_pause;
    input->RelMouseEvent = mrs_on_rel_mouse;

    if (!client->Initialize(client))
        goto out;
    client->context->update->RefreshRect = mrs_refresh_rect;
    client->context->update->SuppressOutput = mrs_suppress_output;

    const HANDLE channel_event = WTSVirtualChannelManagerGetEventHandle(p->vcm);
    while (!p->closing) {
        HANDLE events[MAXIMUM_WAIT_OBJECTS];
        DWORD count = client->GetEventHandles(client, events, MAXIMUM_WAIT_OBJECTS - 5);
        if (count == 0)
            break;
        events[count++] = channel_event;
        events[count++] = p->job_event;
        events[count++] = server->stop_event;
        const HANDLE gfx_event = p->gfx_opened ? rdpgfx_server_get_event_handle(p->gfx) : NULL;
        if (gfx_event)
            events[count++] = gfx_event;
        if (p->ewa_event)
            events[count++] = p->ewa_event;

        if (WaitForMultipleObjects(count, events, FALSE, INFINITE) == WAIT_FAILED)
            break;
        if (WaitForSingleObject(server->stop_event, 0) == WAIT_OBJECT_0)
            break;
        if (!client->CheckFileDescriptor(client))
            break;
        if (!mrs_open_dynamic_channels(p))
            break;
        if (WaitForSingleObject(channel_event, 0) == WAIT_OBJECT_0 &&
            !WTSVirtualChannelManagerCheckFileDescriptor(p->vcm))
            break;
        if (gfx_event && WaitForSingleObject(gfx_event, 0) == WAIT_OBJECT_0 &&
            rdpgfx_server_handle_messages(p->gfx) != CHANNEL_RC_OK)
            break;
        if (p->ewa_event && WaitForSingleObject(p->ewa_event, 0) == WAIT_OBJECT_0)
            mrs_read_webauthn(p);
        mrs_run_jobs(p);
        mrs_report_stats(p);
    }
    mrs_log("%s disconnected", client->hostname);

    // Stop channel threads before telling the host, so no callback outlives the session.
    if (p->disp_opened)
        (void)p->disp->Close(p->disp);
    if (p->gfx_opened)
        (void)p->gfx->Close(p->gfx);
    if (p->ewa_channel)
        (void)WTSVirtualChannelClose(p->ewa_channel);
    if (p->clip_started)
        (void)p->clip->Stop(p->clip);
    if (p->started)
        server->callbacks.session_ended(server->callbacks.user, as_session(p));

out:
    client->Disconnect(client);
    freerdp_peer_context_free(client);
    freerdp_peer_free(client);
    return 0;
}

static BOOL mrs_peer_accepted(freerdp_listener *listener, freerdp_peer *client) {
    mrs_server *server = listener->info;
    client->ContextExtra = server;
    client->ContextSize = sizeof(mrs_peer);
    client->ContextNew = mrs_peer_context_new;
    client->ContextFree = mrs_peer_context_free;
    if (!freerdp_peer_context_new_ex(client, server->settings)) {
        freerdp_peer_free(client);
        return FALSE;
    }
    mrs_log("connection from %s", client->hostname);
    HANDLE thread = CreateThread(NULL, 0, mrs_session_thread, client, 0, NULL);
    if (!thread) {
        freerdp_peer_context_free(client);
        freerdp_peer_free(client);
        return FALSE;
    }
    (void)CloseHandle(thread);
    return TRUE;
}

// MARK: - Server

static BOOL mrs_configure(rdpSettings *s, const char *dir, char *error, size_t error_len) {
    char *cert_path = mrs_path(dir, MRS_CERT_NAME ".crt");
    char *key_path = mrs_path(dir, MRS_CERT_NAME ".key");
    char *sam_path = mrs_path(dir, MRS_SAM_NAME);
    BOOL ok = FALSE;
    if (!cert_path || !key_path || !sam_path)
        goto out;

    if (!winpr_PathFileExists(sam_path)) {
        mrs_set_error(error, error_len, "no sign-in password set (run: mac-rdp-server set-password)");
        goto out;
    }
    rdpCertificate *cert = freerdp_certificate_new_from_file(cert_path);
    rdpPrivateKey *key = freerdp_key_new_from_file_enc(key_path, NULL);
    if (!cert || !key) {
        freerdp_certificate_free(cert);
        freerdp_key_free(key);
        mrs_set_error(error, error_len, "cannot load TLS certificate from %s", dir);
        goto out;
    }

    // NLA only: the client must prove the password before a session exists.
    ok = freerdp_settings_set_pointer_len(s, FreeRDP_RdpServerCertificate, cert, 1) &&
         freerdp_settings_set_pointer_len(s, FreeRDP_RdpServerRsaKey, key, 1) &&
         freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE) &&
         freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, FALSE) &&
         freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_ExtSecurity, FALSE) &&
         freerdp_settings_set_string(s, FreeRDP_NtlmSamFile, sam_path) &&
         freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32) &&
         freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, FALSE) &&
         freerdp_settings_set_bool(s, FreeRDP_NSCodec, FALSE) &&
         freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_SupportMonitorLayoutPdu, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_HasExtendedMouseEvent, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_HasHorizontalWheel, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_UnicodeInput, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_FrameMarkerCommandEnabled, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_SurfaceFrameMarkerEnabled, TRUE);
    if (!ok)
        mrs_set_error(error, error_len, "invalid server settings");
out:
    free(cert_path);
    free(key_path);
    free(sam_path);
    return ok;
}

static DWORD WINAPI mrs_listener_thread(LPVOID arg) {
    mrs_server *server = arg;
    freerdp_listener *listener = server->listener;
    for (;;) {
        HANDLE events[MAXIMUM_WAIT_OBJECTS];
        DWORD count = listener->GetEventHandles(listener, events, MAXIMUM_WAIT_OBJECTS - 1);
        if (count == 0)
            break;
        events[count++] = server->stop_event;
        if (WaitForMultipleObjects(count, events, FALSE, INFINITE) == WAIT_FAILED)
            break;
        if (WaitForSingleObject(server->stop_event, 0) == WAIT_OBJECT_0)
            break;
        if (!listener->CheckFileDescriptor(listener)) {
            mrs_log("listener failed");
            break;
        }
    }
    listener->Close(listener);
    return 0;
}

static void mrs_global_init(void) {
    winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT);
    WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi());
    WSADATA wsa;
    (void)WSAStartup(MAKEWORD(2, 2), &wsa);
}

mrs_server *mrs_server_start(const mrs_server_config *config, const mrs_callbacks *callbacks,
                           char *error, size_t error_len) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, mrs_global_init);

    mrs_server *server = calloc(1, sizeof(mrs_server));
    if (!server)
        return NULL;
    server->callbacks = *callbacks;
    server->settings = freerdp_settings_new(FREERDP_SETTINGS_SERVER_MODE);
    server->stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    server->listener = freerdp_listener_new();
    if (!server->settings || !server->stop_event || !server->listener) {
        mrs_set_error(error, error_len, "out of memory");
        goto fail;
    }
    if (!mrs_configure(server->settings, config->config_dir, error, error_len))
        goto fail;

    server->listener->info = server;
    server->listener->PeerAccepted = mrs_peer_accepted;
    if (!server->listener->Open(server->listener, config->bind_address, config->port)) {
        mrs_set_error(error, error_len, "cannot listen on port %u (already in use?)", config->port);
        goto fail;
    }
    server->thread = CreateThread(NULL, 0, mrs_listener_thread, server, 0, NULL);
    if (!server->thread) {
        mrs_set_error(error, error_len, "cannot start listener thread");
        goto fail;
    }
    mrs_log("listening on port %u", config->port);
    return server;

fail:
    if (server->listener)
        freerdp_listener_free(server->listener);
    if (server->stop_event)
        (void)CloseHandle(server->stop_event);
    freerdp_settings_free(server->settings);
    free(server);
    return NULL;
}

void mrs_server_stop(mrs_server *server) {
    if (!server)
        return;
    SetEvent(server->stop_event);
    (void)WaitForSingleObject(server->thread, INFINITE);
    (void)CloseHandle(server->thread);
    freerdp_listener_free(server->listener);
    // Session threads still running see stop_event and exit on their own;
    // keep the event and settings alive for them.
}

// MARK: - Setup helpers

int mrs_ensure_certificate(const char *config_dir, char *error, size_t error_len) {
    char *cert_path = mrs_path(config_dir, MRS_CERT_NAME ".crt");
    char *key_path = mrs_path(config_dir, MRS_CERT_NAME ".key");
    int rc = -1;
    if (!cert_path || !key_path)
        goto out;
    if (winpr_PathFileExists(cert_path) && winpr_PathFileExists(key_path)) {
        rc = 0;
        goto out;
    }

    char *argv[] = {"makecert", "-rdp", "-live", "-silent", "-y", "5"};
    MAKECERT_CONTEXT *ctx = makecert_context_new();
    if (ctx && makecert_context_process(ctx, ARRAYSIZE(argv), argv) >= 0 &&
        makecert_context_set_output_file_name(ctx, MRS_CERT_NAME) == 1 &&
        makecert_context_output_certificate_file(ctx, config_dir) == 1 &&
        makecert_context_output_private_key_file(ctx, config_dir) == 1) {
        chmod(key_path, 0600);
        rc = 0;
    } else {
        mrs_set_error(error, error_len, "cannot create a TLS certificate in %s", config_dir);
    }
    makecert_context_free(ctx);
out:
    free(cert_path);
    free(key_path);
    return rc;
}

int mrs_write_credentials(const char *config_dir, const char *user, const char *password,
                         char *error, size_t error_len) {
    if (!user || !*user || strchr(user, ':') || strchr(user, '\n')) {
        mrs_set_error(error, error_len, "invalid user name");
        return -1;
    }
    BYTE hash[16];
    if (!NTOWFv1A((LPSTR)password, (UINT32)strlen(password), hash)) {
        mrs_set_error(error, error_len, "cannot hash password");
        return -1;
    }
    char *path = mrs_path(config_dir, MRS_SAM_NAME);
    if (!path)
        return -1;

    // SAM line: User:Domain:LMHash:NTHash::: (empty domain matches any).
    FILE *f = fopen(path, "w");
    if (!f) {
        mrs_set_error(error, error_len, "cannot write %s", path);
        free(path);
        return -1;
    }
    chmod(path, 0600);
    fprintf(f, "%s:::", user);
    for (size_t i = 0; i < sizeof(hash); i++)
        fprintf(f, "%02x", hash[i]);
    fprintf(f, ":::\n");
    fclose(f);
    free(path);
    memset(hash, 0, sizeof(hash));
    return 0;
}
