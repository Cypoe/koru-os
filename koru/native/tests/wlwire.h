// wlwire.h — minimal real Wayland wire marshalling, no libwayland.
// Message format IS libwayland's: u32 object id | u16 opcode | u16 size
// (size covers header+args). u32/i32 args are 4-byte slots; string is
// u32 len(inc NUL) + bytes + pad4; a typed new_id is one u32 slot —
// wl_registry.bind's anonymous new_id is the famous exception, wire-
// shaped (string iface, u32 version, u32 id). fd args take ZERO body
// bytes: they ride the message's own SCM_RIGHTS control channel — the
// wire cannot be spoken without ancillary data.
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void wl_le32(unsigned char *p, uint32_t v) { memcpy(p, &v, 4); }
static void wl_le16(unsigned char *p, uint16_t v) { memcpy(p, &v, 2); }
static uint32_t wl_u32(const unsigned char *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint16_t wl_u16(const unsigned char *p) { uint16_t v; memcpy(&v, p, 2); return v; }

// --- build side ------------------------------------------------------------
struct wlw { unsigned char *b; int pos; };
static void wlw_init(struct wlw *w, unsigned char *b, uint32_t oid, uint16_t op) {
    w->b = b; w->pos = 8;
    wl_le32(b + 0, oid); wl_le16(b + 4, op);
}
static void wlw_u32(struct wlw *w, uint32_t v) { wl_le32(w->b + w->pos, v); w->pos += 4; }
static void wlw_i32(struct wlw *w, int32_t v) { wlw_u32(w, (uint32_t)v); }
static void wlw_str(struct wlw *w, const char *s) {
    uint32_t n = (uint32_t)strlen(s) + 1;
    wlw_u32(w, n);
    memcpy(w->b + w->pos, s, n); w->pos += (int)n;
    while (w->pos & 3) w->b[w->pos++] = 0;
}
static int wlw_len(struct wlw *w) { wl_le16(w->b + 6, (uint16_t)w->pos); return w->pos; }

// --- connection side ---------------------------------------------------------
// A recv batch may coalesce several messages; fds arrive attached to the
// recvmsg and pop in message order — the queue is per-connection, not
// per-message, which is exactly libwayland's correlation rule.
struct wlconn {
    int fd;
    unsigned char buf[16384];
    int len;
    int fdbox[8];
    int nfd;
};

static int wl_send(int fd, const void *b, int n) {
    const char *p = b;
    while (n > 0) {
        long r = write(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= (int)r;
    }
    return 0;
}

static int wl_sendfd(int fd, const void *b, int n, int pass) {
    struct msghdr mh; memset(&mh, 0, sizeof mh);
    struct iovec iov = { .iov_base = (void *)b, .iov_len = (size_t)n };
    char ctl[CMSG_SPACE(sizeof(int))]; memset(ctl, 0, sizeof ctl);
    mh.msg_iov = &iov; mh.msg_iovlen = 1;
    mh.msg_control = ctl; mh.msg_controllen = sizeof ctl;
    struct cmsghdr *c = CMSG_FIRSTHDR(&mh);
    c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &pass, sizeof(int));
    return (int)sendmsg(fd, &mh, 0);
}

// Append stream bytes (plus any ancillary fds) to the connection.
// Returns bytes read, 0 on EOS, <0 on error.
static int wl_fill(struct wlconn *cn) {
    struct msghdr mh; memset(&mh, 0, sizeof mh);
    struct iovec iov = { .iov_base = cn->buf + cn->len,
                         .iov_len = sizeof(cn->buf) - (size_t)cn->len };
    char ctl[256];
    mh.msg_iov = &iov; mh.msg_iovlen = 1;
    mh.msg_control = ctl; mh.msg_controllen = sizeof ctl;
    long n = recvmsg(cn->fd, &mh, 0);
    if (n <= 0) return (int)n;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c; c = CMSG_NXTHDR(&mh, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            int want = (int)(c->cmsg_len - CMSG_LEN(0)) / (int)sizeof(int);
            const int *fds = (const int *)CMSG_DATA(c);
            for (int i = 0; i < want && cn->nfd < 8; i++)
                cn->fdbox[cn->nfd++] = fds[i];
        }
    }
    cn->len += (int)n;
    return (int)n;
}

// Pop the next fd this connection's batches carried (message order).
static int wl_popfd(struct wlconn *cn) {
    if (cn->nfd == 0) return -1;
    int f = cn->fdbox[0];
    for (int i = 1; i < cn->nfd; i++) cn->fdbox[i - 1] = cn->fdbox[i];
    cn->nfd--;
    return f;
}

// Peel one complete message WITHOUT filling — the poll-driven shape:
// the caller already know bytes are waiting (POLLIN -> wl_fill once),
// then drains whole messages until this returns 0 = incomplete
// buffered, NOT end-of-stream (EOS is wl_fill's verdict, never this
// one's). -1 malformed/oversize.
static int wl_peel(struct wlconn *cn, unsigned char *msg, int cap) {
    if (cn->len >= 8) {
        int sz = wl_u16(cn->buf + 6);
        if (sz < 8 || sz > cap) return -1;
        if (cn->len >= sz) {
            memcpy(msg, cn->buf, (size_t)sz);
            memmove(cn->buf, cn->buf + sz, (size_t)(cn->len - sz));
            cn->len -= sz;
            return sz;
        }
    }
    return 0;
}

// Peel one complete message into msg[] (cap bytes max).
// Returns message size, 0 EOS, -1 error/oversize.
static int wl_next(struct wlconn *cn, unsigned char *msg, int cap) {
    for (;;) {
        if (cn->len >= 8) {
            int sz = wl_u16(cn->buf + 6);
            if (sz < 8 || sz > cap) return -1;
            if (cn->len >= sz) {
                memcpy(msg, cn->buf, (size_t)sz);
                memmove(cn->buf, cn->buf + sz, (size_t)(cn->len - sz));
                cn->len -= sz;
                return sz;
            }
        }
        long r = wl_fill(cn);
        if (r <= 0) return (int)r;
    }
}

// arg helpers over a received message
static uint32_t wl_arg(const unsigned char *m, int i) { return wl_u32(m + 8 + i * 4); }
// string arg at byte offset off: returns content ptr, *next = offset past pad4
static const char *wl_sarg(const unsigned char *m, int off, int *next) {
    uint32_t n = wl_u32(m + off);
    *next = off + 4 + (int)((n + 3) & ~3u);
    return (const char *)(m + off + 4);
}
