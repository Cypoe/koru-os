/* vendored wayland-1.26.0 build config — linux/musl feature set.
 * Only what src/ actually probes: accept4 exists on linux; sys/ucred
 * is BSD/Solaris; MSG_CMSG_CLOEXEC is not broken on linux; gettid
 * falls back to SYS_gettid inside connection.c when undefined. */
#define HAVE_ACCEPT4 1
