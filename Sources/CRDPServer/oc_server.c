#include "oc_server.h"

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
#include <freerdp/settings.h>

#define OC_CERT_NAME "server"
#define OC_SAM_NAME "users.sam"
#define OC_MAX_POINTER 96

static void oc_log(const char *fmt, ...) {
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

static void oc_set_error(char *error, size_t len, const char *fmt, ...) {
    if (!error || len == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(error, len, fmt, ap);
    va_end(ap);
}

static char *oc_path(const char *dir, const char *name) {
    const size_t len = strlen(dir) + strlen(name) + 2;
    char *path = malloc(len);
    if (path)
        snprintf(path, len, "%s/%s", dir, name);
    return path;
}

// MARK: - Types

typedef enum { OC_JOB_FRAME, OC_JOB_POINTER, OC_JOB_RESET, OC_JOB_CLOSE } oc_job_kind;

typedef struct oc_job {
    struct oc_job *next;
    oc_job_kind kind;
    uint32_t generation;
    uint32_t index;
    uint32_t width, height, hot_x, hot_y;
    uint32_t count;
    oc_monitor monitors[OC_MAX_MONITORS];
    size_t length;
    uint8_t data[];
} oc_job;

struct oc_server {
    freerdp_listener *listener;
    rdpSettings *settings;
    oc_callbacks callbacks;
    HANDLE stop_event;
    HANDLE thread;
};

/// Per-connection state; FreeRDP allocates it as the peer's rdpContext.
typedef struct {
    rdpContext base; // must be first
    oc_server *server;
    HANDLE vcm;
    RdpgfxServerContext *gfx;
    DispServerContext *disp;
    UINT32 disp_channel_id;
    BOOL activated, started, gfx_opened, gfx_ready, disp_opened, closing;

    // Owned by the session thread.
    oc_monitor monitors[OC_MAX_MONITORS];
    uint32_t monitor_count;
    uint16_t surface_ids[OC_MAX_MONITORS];
    uint32_t surface_count;
    uint16_t next_surface_id;
    uint32_t generation;
    // Video statistics, logged periodically so a stalled client is visible.
    uint32_t stat_frames, stat_acks;
    uint64_t stat_bytes, stat_since;

    // Shared with other threads, guarded by `lock`.
    BOOL lock_ready;
    pthread_mutex_t lock;
    oc_job *head, *tail;
    uint32_t queued_frames;
    uint32_t last_frame_id;
    uint32_t last_acked_frame_id;
    BOOL acks_suspended;
    HANDLE job_event;
} oc_peer;

static oc_session *as_session(oc_peer *p) { return (oc_session *)p; }
static oc_peer *as_peer(oc_session *s) { return (oc_peer *)s; }

// MARK: - Monitors

static uint32_t oc_scale(uint32_t value, uint32_t fallback) {
    if (value >= 100 && value <= 500)
        return value;
    if (fallback >= 100 && fallback <= 500)
        return fallback;
    return 100;
}

static uint32_t oc_read_monitors(const rdpSettings *settings, oc_monitor *out) {
    const uint32_t global = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);
    const BOOL attributes = freerdp_settings_get_bool(settings, FreeRDP_HasMonitorAttributes);
    uint32_t count = freerdp_settings_get_uint32(settings, FreeRDP_MonitorCount);
    if (count == 0) {
        out[0] = (oc_monitor){
            .x = 0,
            .y = 0,
            .width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
            .height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight),
            .is_primary = 1,
            .scale_percent = oc_scale(0, global),
        };
        return 1;
    }
    if (count > OC_MAX_MONITORS)
        count = OC_MAX_MONITORS;
    for (uint32_t i = 0; i < count; i++) {
        const rdpMonitor *m = freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, i);
        out[i] = (oc_monitor){
            .x = m->x,
            .y = m->y,
            .width = (uint32_t)m->width,
            .height = (uint32_t)m->height,
            .is_primary = m->is_primary ? 1 : 0,
            .scale_percent = oc_scale(attributes ? m->attributes.desktopScaleFactor : 0, global),
        };
    }
    return count;
}

// MARK: - Graphics pipeline

static UINT32 oc_timestamp(void) {
    SYSTEMTIME t;
    GetSystemTime(&t);
    return (UINT32)(t.wHour << 22U | t.wMinute << 16U | t.wSecond << 10U | t.wMilliseconds);
}

/// Replaces all surfaces with one per monitor, mapped where the client shows that monitor.
static BOOL oc_create_surfaces(oc_peer *p) {
    RdpgfxServerContext *gfx = p->gfx;
    for (uint32_t i = 0; i < p->surface_count; i++) {
        const RDPGFX_DELETE_SURFACE_PDU del = {.surfaceId = p->surface_ids[i]};
        (void)gfx->DeleteSurface(gfx, &del);
    }
    p->surface_count = 0;

    int32_t min_x = INT32_MAX, min_y = INT32_MAX, max_x = INT32_MIN, max_y = INT32_MIN;
    MONITOR_DEF defs[OC_MAX_MONITORS];
    for (uint32_t i = 0; i < p->monitor_count; i++) {
        const oc_monitor *m = &p->monitors[i];
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
        oc_log("ResetGraphics failed");
        return FALSE;
    }

    for (uint32_t i = 0; i < p->monitor_count; i++) {
        const oc_monitor *m = &p->monitors[i];
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
            oc_log("creating surface for monitor %u failed", i + 1);
            return FALSE;
        }
        p->surface_ids[i] = id;
        p->surface_count++;
    }
    oc_log("desktop %ux%u across %u monitor(s)", reset.width, reset.height, p->monitor_count);
    return TRUE;
}

static BOOL oc_caps_allow_avc420(const RDPGFX_CAPSET *caps) {
    switch (caps->version) {
    case RDPGFX_CAPVERSION_8:
        return FALSE;
    case RDPGFX_CAPVERSION_81:
        return (caps->flags & RDPGFX_CAPS_FLAG_AVC420_ENABLED) != 0;
    default:
        return (caps->flags & RDPGFX_CAPS_FLAG_AVC_DISABLED) == 0;
    }
}

static UINT oc_gfx_caps_advertise(RdpgfxServerContext *gfx, const RDPGFX_CAPS_ADVERTISE_PDU *pdu) {
    oc_peer *p = gfx->custom;
    static const UINT32 preferred[] = {
        RDPGFX_CAPVERSION_107, RDPGFX_CAPVERSION_106, RDPGFX_CAPVERSION_106_ERR,
        RDPGFX_CAPVERSION_105, RDPGFX_CAPVERSION_104, RDPGFX_CAPVERSION_103,
        RDPGFX_CAPVERSION_102, RDPGFX_CAPVERSION_101, RDPGFX_CAPVERSION_10,
        RDPGFX_CAPVERSION_81,
    };
    for (size_t v = 0; v < ARRAYSIZE(preferred); v++) {
        for (UINT16 i = 0; i < pdu->capsSetCount; i++) {
            const RDPGFX_CAPSET *offered = &pdu->capsSets[i];
            if (offered->version != preferred[v] || !oc_caps_allow_avc420(offered))
                continue;

            RDPGFX_CAPSET caps = *offered;
            const RDPGFX_CAPS_CONFIRM_PDU confirm = {.capsSet = &caps};
            const UINT rc = gfx->CapsConfirm(gfx, &confirm);
            if (rc != CHANNEL_RC_OK)
                return rc;
            oc_log("graphics pipeline 0x%08x with H.264", caps.version);
            p->gfx_ready = TRUE;
            if (!oc_create_surfaces(p))
                return ERROR_INTERNAL_ERROR;
            p->server->callbacks.graphics_ready(p->server->callbacks.user, as_session(p));
            return CHANNEL_RC_OK;
        }
    }
    oc_log("client cannot decode H.264 (AVC420); disconnecting");
    p->closing = TRUE;
    return CHANNEL_RC_OK;
}

static UINT oc_gfx_frame_ack(RdpgfxServerContext *gfx, const RDPGFX_FRAME_ACKNOWLEDGE_PDU *ack) {
    oc_peer *p = gfx->custom;
    pthread_mutex_lock(&p->lock);
    p->last_acked_frame_id = ack->frameId;
    p->acks_suspended = ack->queueDepth == SUSPEND_FRAME_ACKNOWLEDGEMENT;
    pthread_mutex_unlock(&p->lock);
    p->stat_acks++;
    p->server->callbacks.frames_acked(p->server->callbacks.user, as_session(p));
    return CHANNEL_RC_OK;
}

static void oc_send_frame(oc_peer *p, const oc_job *job) {
    if (!p->gfx_ready || job->generation != p->generation || job->index >= p->surface_count)
        return;
    const oc_monitor *m = &p->monitors[job->index];

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
    const UINT32 frame_id = ++p->last_frame_id;
    pthread_mutex_unlock(&p->lock);

    const RDPGFX_START_FRAME_PDU start = {.timestamp = oc_timestamp(), .frameId = frame_id};
    const RDPGFX_END_FRAME_PDU end = {.frameId = frame_id};
    if (p->gfx->SurfaceFrameCommand(p->gfx, &cmd, &start, &end) != CHANNEL_RC_OK) {
        oc_log("sending frame failed; disconnecting");
        p->closing = TRUE;
        return;
    }
    p->stat_frames++;
    p->stat_bytes += job->length;
}

static void oc_report_stats(oc_peer *p) {
    const uint64_t now = GetTickCount64();
    if (p->stat_since == 0)
        p->stat_since = now;
    const uint64_t elapsed = now - p->stat_since;
    if (elapsed < 5000 || (p->stat_frames == 0 && p->stat_acks == 0))
        return;
    // Frames sent but never acknowledged mean the client cannot decode them.
    oc_log("video: %.1f fps sent, %.1f fps acknowledged, %.1f Mbit/s, %u in flight",
           p->stat_frames * 1000.0 / elapsed, p->stat_acks * 1000.0 / elapsed,
           p->stat_bytes * 8.0 / 1000.0 / elapsed, oc_session_frames_in_flight(as_session(p)));
    p->stat_frames = p->stat_acks = 0;
    p->stat_bytes = 0;
    p->stat_since = now;
}

// MARK: - Pointer

static void oc_send_pointer(oc_peer *p, const oc_job *job) {
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

static int oc_enqueue(oc_peer *p, oc_job *job) {
    job->next = NULL;
    pthread_mutex_lock(&p->lock);
    if (p->tail)
        p->tail->next = job;
    else
        p->head = job;
    p->tail = job;
    if (job->kind == OC_JOB_FRAME)
        p->queued_frames++;
    pthread_mutex_unlock(&p->lock);
    SetEvent(p->job_event);
    return 0;
}

static void oc_run_jobs(oc_peer *p) {
    pthread_mutex_lock(&p->lock);
    oc_job *job = p->head;
    p->head = p->tail = NULL;
    ResetEvent(p->job_event);
    pthread_mutex_unlock(&p->lock);

    while (job) {
        oc_job *next = job->next;
        switch (job->kind) {
        case OC_JOB_FRAME:
            if (!p->closing)
                oc_send_frame(p, job);
            pthread_mutex_lock(&p->lock);
            p->queued_frames--;
            pthread_mutex_unlock(&p->lock);
            break;
        case OC_JOB_POINTER:
            oc_send_pointer(p, job);
            break;
        case OC_JOB_RESET:
            memcpy(p->monitors, job->monitors, sizeof(oc_monitor) * job->count);
            p->monitor_count = job->count;
            p->generation = job->generation;
            if (p->gfx_ready && !oc_create_surfaces(p))
                p->closing = TRUE;
            break;
        case OC_JOB_CLOSE:
            p->closing = TRUE;
            break;
        }
        free(job);
        job = next;
    }
}

static oc_job *oc_job_new(oc_job_kind kind, size_t length) {
    oc_job *job = calloc(1, sizeof(oc_job) + length);
    if (job) {
        job->kind = kind;
        job->length = length;
    }
    return job;
}

int oc_session_send_h264(oc_session *session, uint32_t generation, uint32_t index,
                         const uint8_t *data, size_t length) {
    oc_job *job = oc_job_new(OC_JOB_FRAME, length);
    if (!job)
        return -1;
    job->generation = generation;
    job->index = index;
    memcpy(job->data, data, length);
    return oc_enqueue(as_peer(session), job);
}

uint32_t oc_session_frames_in_flight(oc_session *session) {
    oc_peer *p = as_peer(session);
    pthread_mutex_lock(&p->lock);
    uint32_t n = p->queued_frames;
    if (!p->acks_suspended)
        n += p->last_frame_id - p->last_acked_frame_id;
    pthread_mutex_unlock(&p->lock);
    return n;
}

int oc_session_set_pointer(oc_session *session, const uint8_t *bgra, uint32_t width,
                           uint32_t height, uint32_t hot_x, uint32_t hot_y) {
    if (bgra && (width == 0 || height == 0 || width > OC_MAX_POINTER || height > OC_MAX_POINTER))
        return -1;
    const size_t length = bgra ? (size_t)width * height * 4 : 0;
    oc_job *job = oc_job_new(OC_JOB_POINTER, length);
    if (!job)
        return -1;
    job->width = width;
    job->height = height;
    job->hot_x = hot_x < width ? hot_x : 0;
    job->hot_y = hot_y < height ? hot_y : 0;
    if (bgra)
        memcpy(job->data, bgra, length);
    return oc_enqueue(as_peer(session), job);
}

int oc_session_reset_layout(oc_session *session, uint32_t generation, const oc_monitor *monitors,
                            uint32_t count) {
    if (count == 0 || count > OC_MAX_MONITORS)
        return -1;
    oc_job *job = oc_job_new(OC_JOB_RESET, 0);
    if (!job)
        return -1;
    job->generation = generation;
    job->count = count;
    memcpy(job->monitors, monitors, sizeof(oc_monitor) * count);
    return oc_enqueue(as_peer(session), job);
}

void oc_session_close(oc_session *session) {
    oc_job *job = oc_job_new(OC_JOB_CLOSE, 0);
    if (job)
        oc_enqueue(as_peer(session), job);
}

// MARK: - Display control (live re-layout)

static BOOL oc_disp_channel_assigned(DispServerContext *disp, UINT32 channel_id) {
    ((oc_peer *)disp->custom)->disp_channel_id = channel_id;
    return TRUE;
}

static BOOL oc_dvc_created(void *userdata, UINT32 channel_id, INT32 status) {
    oc_peer *p = userdata;
    // Capabilities can only go out once the client has accepted the channel.
    if (p->disp && channel_id == p->disp_channel_id && status >= 0)
        (void)p->disp->DisplayControlCaps(p->disp);
    return TRUE;
}

static UINT oc_disp_layout(DispServerContext *disp, const DISPLAY_CONTROL_MONITOR_LAYOUT_PDU *pdu) {
    oc_peer *p = disp->custom;
    oc_monitor monitors[OC_MAX_MONITORS];
    const uint32_t count = pdu->NumMonitors < OC_MAX_MONITORS ? pdu->NumMonitors : OC_MAX_MONITORS;
    if (count == 0)
        return CHANNEL_RC_OK;
    for (uint32_t i = 0; i < count; i++) {
        const DISPLAY_CONTROL_MONITOR_LAYOUT *m = &pdu->Monitors[i];
        monitors[i] = (oc_monitor){
            .x = m->Left,
            .y = m->Top,
            .width = m->Width,
            .height = m->Height,
            .is_primary = (m->Flags & DISPLAY_CONTROL_MONITOR_PRIMARY) ? 1 : 0,
            .scale_percent = oc_scale(m->DesktopScaleFactor, 100),
        };
    }
    p->server->callbacks.layout_requested(p->server->callbacks.user, as_session(p), monitors, count);
    return CHANNEL_RC_OK;
}

// MARK: - Input

static BOOL oc_on_keyboard(rdpInput *input, UINT16 flags, UINT8 code) {
    oc_peer *p = (oc_peer *)input->context;
    p->server->callbacks.keyboard(p->server->callbacks.user, as_session(p), flags, code);
    return TRUE;
}

static BOOL oc_on_unicode(rdpInput *input, UINT16 flags, UINT16 code) {
    oc_peer *p = (oc_peer *)input->context;
    p->server->callbacks.unicode(p->server->callbacks.user, as_session(p), flags, code);
    return TRUE;
}

static BOOL oc_on_mouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
    oc_peer *p = (oc_peer *)input->context;
    p->server->callbacks.mouse(p->server->callbacks.user, as_session(p), flags, x, y);
    return TRUE;
}

static BOOL oc_on_extended_mouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
    oc_peer *p = (oc_peer *)input->context;
    p->server->callbacks.extended_mouse(p->server->callbacks.user, as_session(p), flags, x, y);
    return TRUE;
}

static BOOL oc_on_synchronize(rdpInput *input, UINT32 flags) {
    WINPR_UNUSED(input);
    WINPR_UNUSED(flags);
    return TRUE;
}

static BOOL oc_on_focus_in(rdpInput *input, UINT16 toggle_states) {
    WINPR_UNUSED(input);
    WINPR_UNUSED(toggle_states);
    return TRUE;
}

static BOOL oc_on_pause(rdpInput *input) {
    WINPR_UNUSED(input);
    return TRUE;
}

static BOOL oc_on_rel_mouse(rdpInput *input, UINT16 flags, INT16 dx, INT16 dy) {
    WINPR_UNUSED(input);
    WINPR_UNUSED(flags);
    WINPR_UNUSED(dx);
    WINPR_UNUSED(dy);
    return TRUE;
}

static BOOL oc_refresh_rect(rdpContext *context, BYTE count, const RECTANGLE_16 *areas) {
    WINPR_UNUSED(count);
    WINPR_UNUSED(areas);
    oc_peer *p = (oc_peer *)context;
    if (p->started)
        p->server->callbacks.refresh_requested(p->server->callbacks.user, as_session(p));
    return TRUE;
}

static BOOL oc_suppress_output(rdpContext *context, BYTE allow, const RECTANGLE_16 *area) {
    WINPR_UNUSED(area);
    oc_peer *p = (oc_peer *)context;
    // Coming back from minimized: the client discarded its picture.
    if (allow && p->started)
        p->server->callbacks.refresh_requested(p->server->callbacks.user, as_session(p));
    return TRUE;
}

// MARK: - Session lifecycle

static BOOL oc_peer_context_new(freerdp_peer *client, rdpContext *context) {
    oc_peer *p = (oc_peer *)context;
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

static void oc_peer_context_free(freerdp_peer *client, rdpContext *context) {
    WINPR_UNUSED(client);
    oc_peer *p = (oc_peer *)context;
    if (!p)
        return;
    if (p->gfx)
        rdpgfx_server_context_free(p->gfx);
    if (p->disp)
        disp_server_context_free(p->disp);
    for (oc_job *job = p->head; job;) {
        oc_job *next = job->next;
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

static BOOL oc_post_connect(freerdp_peer *client) {
    oc_peer *p = (oc_peer *)client->context;
    rdpSettings *settings = client->context->settings;

    if (!freerdp_settings_get_bool(settings, FreeRDP_SupportGraphicsPipeline)) {
        oc_log("%s: client does not support the graphics pipeline", client->hostname);
        return FALSE;
    }

    p->monitor_count = oc_read_monitors(settings, p->monitors);
    oc_log("%s signed in as %s, %u monitor(s)", client->hostname,
           freerdp_settings_get_string(settings, FreeRDP_Username), p->monitor_count);

    const oc_callbacks *cb = &p->server->callbacks;
    if (cb->session_started(cb->user, as_session(p), client->hostname, p->monitors,
                            p->monitor_count) != 0) {
        oc_log("%s: session refused", client->hostname);
        return FALSE;
    }
    p->started = TRUE;

    p->gfx = rdpgfx_server_context_new(p->vcm);
    if (!p->gfx)
        return FALSE;
    p->gfx->rdpcontext = client->context;
    p->gfx->custom = p;
    p->gfx->CapsAdvertise = oc_gfx_caps_advertise;
    p->gfx->FrameAcknowledge = oc_gfx_frame_ack;
    if (!p->gfx->Initialize(p->gfx, TRUE))
        return FALSE;

    p->disp = disp_server_context_new(p->vcm);
    if (p->disp) {
        p->disp->rdpcontext = client->context;
        p->disp->custom = p;
        p->disp->MaxNumMonitors = OC_MAX_MONITORS;
        p->disp->MaxMonitorAreaFactorA = 8192;
        p->disp->MaxMonitorAreaFactorB = 8192;
        p->disp->DispMonitorLayout = oc_disp_layout;
        p->disp->ChannelIdAssigned = oc_disp_channel_assigned;
        WTSVirtualChannelManagerSetDVCCreationCallback(p->vcm, oc_dvc_created, p);
    }
    return TRUE;
}

static BOOL oc_activate(freerdp_peer *client) {
    ((oc_peer *)client->context)->activated = TRUE;
    return TRUE;
}

/// Dynamic channels (graphics, display control) can only open once the client
/// finished activation and its drdynvc channel is up.
static BOOL oc_open_dynamic_channels(oc_peer *p) {
    if (!p->activated || !WTSVirtualChannelManagerIsChannelJoined(p->vcm, DRDYNVC_SVC_CHANNEL_NAME))
        return TRUE;
    switch (WTSVirtualChannelManagerGetDrdynvcState(p->vcm)) {
    case DRDYNVC_STATE_NONE:
        return WTSVirtualChannelManagerCheckFileDescriptor(p->vcm);
    case DRDYNVC_STATE_READY:
        if (p->gfx && !p->gfx_opened) {
            if (!p->gfx->Open(p->gfx)) {
                oc_log("could not open the graphics channel");
                return FALSE;
            }
            p->gfx_opened = TRUE;
        }
        if (p->disp && !p->disp_opened) {
            p->disp_opened = p->disp->Open(p->disp) == CHANNEL_RC_OK;
            if (!p->disp_opened)
                oc_log("display control unavailable; window resizing will not adapt");
        }
        return TRUE;
    default:
        return TRUE;
    }
}

static DWORD WINAPI oc_session_thread(LPVOID arg) {
    freerdp_peer *client = arg;
    oc_peer *p = (oc_peer *)client->context;
    oc_server *server = p->server;

    client->PostConnect = oc_post_connect;
    client->Activate = oc_activate;
    rdpInput *input = client->context->input;
    input->KeyboardEvent = oc_on_keyboard;
    input->UnicodeKeyboardEvent = oc_on_unicode;
    input->MouseEvent = oc_on_mouse;
    input->ExtendedMouseEvent = oc_on_extended_mouse;
    input->SynchronizeEvent = oc_on_synchronize;
    input->FocusInEvent = oc_on_focus_in;
    input->KeyboardPauseEvent = oc_on_pause;
    input->RelMouseEvent = oc_on_rel_mouse;

    if (!client->Initialize(client))
        goto out;
    client->context->update->RefreshRect = oc_refresh_rect;
    client->context->update->SuppressOutput = oc_suppress_output;

    const HANDLE channel_event = WTSVirtualChannelManagerGetEventHandle(p->vcm);
    while (!p->closing) {
        HANDLE events[MAXIMUM_WAIT_OBJECTS];
        DWORD count = client->GetEventHandles(client, events, MAXIMUM_WAIT_OBJECTS - 4);
        if (count == 0)
            break;
        events[count++] = channel_event;
        events[count++] = p->job_event;
        events[count++] = server->stop_event;
        const HANDLE gfx_event = p->gfx_opened ? rdpgfx_server_get_event_handle(p->gfx) : NULL;
        if (gfx_event)
            events[count++] = gfx_event;

        if (WaitForMultipleObjects(count, events, FALSE, INFINITE) == WAIT_FAILED)
            break;
        if (WaitForSingleObject(server->stop_event, 0) == WAIT_OBJECT_0)
            break;
        if (!client->CheckFileDescriptor(client))
            break;
        if (!oc_open_dynamic_channels(p))
            break;
        if (WaitForSingleObject(channel_event, 0) == WAIT_OBJECT_0 &&
            !WTSVirtualChannelManagerCheckFileDescriptor(p->vcm))
            break;
        if (gfx_event && WaitForSingleObject(gfx_event, 0) == WAIT_OBJECT_0 &&
            rdpgfx_server_handle_messages(p->gfx) != CHANNEL_RC_OK)
            break;
        oc_run_jobs(p);
        oc_report_stats(p);
    }
    oc_log("%s disconnected", client->hostname);

    // Stop channel threads before telling the host, so no callback outlives the session.
    if (p->disp_opened)
        (void)p->disp->Close(p->disp);
    if (p->gfx_opened)
        (void)p->gfx->Close(p->gfx);
    if (p->started)
        server->callbacks.session_ended(server->callbacks.user, as_session(p));

out:
    client->Disconnect(client);
    freerdp_peer_context_free(client);
    freerdp_peer_free(client);
    return 0;
}

static BOOL oc_peer_accepted(freerdp_listener *listener, freerdp_peer *client) {
    oc_server *server = listener->info;
    client->ContextExtra = server;
    client->ContextSize = sizeof(oc_peer);
    client->ContextNew = oc_peer_context_new;
    client->ContextFree = oc_peer_context_free;
    if (!freerdp_peer_context_new_ex(client, server->settings)) {
        freerdp_peer_free(client);
        return FALSE;
    }
    oc_log("connection from %s", client->hostname);
    HANDLE thread = CreateThread(NULL, 0, oc_session_thread, client, 0, NULL);
    if (!thread) {
        freerdp_peer_context_free(client);
        freerdp_peer_free(client);
        return FALSE;
    }
    (void)CloseHandle(thread);
    return TRUE;
}

// MARK: - Server

static BOOL oc_configure(rdpSettings *s, const char *dir, char *error, size_t error_len) {
    char *cert_path = oc_path(dir, OC_CERT_NAME ".crt");
    char *key_path = oc_path(dir, OC_CERT_NAME ".key");
    char *sam_path = oc_path(dir, OC_SAM_NAME);
    BOOL ok = FALSE;
    if (!cert_path || !key_path || !sam_path)
        goto out;

    if (!winpr_PathFileExists(sam_path)) {
        oc_set_error(error, error_len, "no sign-in password set (run: openconnect-host set-password)");
        goto out;
    }
    rdpCertificate *cert = freerdp_certificate_new_from_file(cert_path);
    rdpPrivateKey *key = freerdp_key_new_from_file_enc(key_path, NULL);
    if (!cert || !key) {
        freerdp_certificate_free(cert);
        freerdp_key_free(key);
        oc_set_error(error, error_len, "cannot load TLS certificate from %s", dir);
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
        oc_set_error(error, error_len, "invalid server settings");
out:
    free(cert_path);
    free(key_path);
    free(sam_path);
    return ok;
}

static DWORD WINAPI oc_listener_thread(LPVOID arg) {
    oc_server *server = arg;
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
            oc_log("listener failed");
            break;
        }
    }
    listener->Close(listener);
    return 0;
}

static void oc_global_init(void) {
    winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT);
    WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi());
    WSADATA wsa;
    (void)WSAStartup(MAKEWORD(2, 2), &wsa);
}

oc_server *oc_server_start(const oc_server_config *config, const oc_callbacks *callbacks,
                           char *error, size_t error_len) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, oc_global_init);

    oc_server *server = calloc(1, sizeof(oc_server));
    if (!server)
        return NULL;
    server->callbacks = *callbacks;
    server->settings = freerdp_settings_new(FREERDP_SETTINGS_SERVER_MODE);
    server->stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    server->listener = freerdp_listener_new();
    if (!server->settings || !server->stop_event || !server->listener) {
        oc_set_error(error, error_len, "out of memory");
        goto fail;
    }
    if (!oc_configure(server->settings, config->config_dir, error, error_len))
        goto fail;

    server->listener->info = server;
    server->listener->PeerAccepted = oc_peer_accepted;
    if (!server->listener->Open(server->listener, config->bind_address, config->port)) {
        oc_set_error(error, error_len, "cannot listen on port %u (already in use?)", config->port);
        goto fail;
    }
    server->thread = CreateThread(NULL, 0, oc_listener_thread, server, 0, NULL);
    if (!server->thread) {
        oc_set_error(error, error_len, "cannot start listener thread");
        goto fail;
    }
    oc_log("listening on port %u", config->port);
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

void oc_server_stop(oc_server *server) {
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

int oc_ensure_certificate(const char *config_dir, char *error, size_t error_len) {
    char *cert_path = oc_path(config_dir, OC_CERT_NAME ".crt");
    char *key_path = oc_path(config_dir, OC_CERT_NAME ".key");
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
        makecert_context_set_output_file_name(ctx, OC_CERT_NAME) == 1 &&
        makecert_context_output_certificate_file(ctx, config_dir) == 1 &&
        makecert_context_output_private_key_file(ctx, config_dir) == 1) {
        chmod(key_path, 0600);
        rc = 0;
    } else {
        oc_set_error(error, error_len, "cannot create a TLS certificate in %s", config_dir);
    }
    makecert_context_free(ctx);
out:
    free(cert_path);
    free(key_path);
    return rc;
}

int oc_write_credentials(const char *config_dir, const char *user, const char *password,
                         char *error, size_t error_len) {
    if (!user || !*user || strchr(user, ':') || strchr(user, '\n')) {
        oc_set_error(error, error_len, "invalid user name");
        return -1;
    }
    BYTE hash[16];
    if (!NTOWFv1A((LPSTR)password, (UINT32)strlen(password), hash)) {
        oc_set_error(error, error_len, "cannot hash password");
        return -1;
    }
    char *path = oc_path(config_dir, OC_SAM_NAME);
    if (!path)
        return -1;

    // SAM line: User:Domain:LMHash:NTHash::: (empty domain matches any).
    FILE *f = fopen(path, "w");
    if (!f) {
        oc_set_error(error, error_len, "cannot write %s", path);
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
