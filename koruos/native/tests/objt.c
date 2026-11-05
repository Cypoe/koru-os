// objt.elf — the object-axis oracle child (M2). granttest spawns it
// with mask minus the open CLASS bit plus {cap:2, obj:key, verbs:R|W}
// and hands the key as argv[1] (decimal). It never names a path:
// openobj(key) is the only verb that can mint an fs fd for it.
// Proves: read + write BY IDENTITY, and a wrong key's refusal names
// the object — the grant check is the syscall itself.
#include <sys/syscall.h>
#include <unistd.h>
#include <errno.h>

static void put(const char *s) {
    const char *p = s;
    while (*p) p++;
    __asm__ volatile("syscall" :: "a"(1l), "D"(1l), "S"(s), "d"((long)(p - s))
                     : "rcx", "r11", "memory");
}
static void putn(long v) {
    char b[24];
    int i = 24;
    unsigned long u = v < 0 ? (unsigned long)-v : (unsigned long)v;
    if (v < 0) put("-");
    do { b[--i] = (char)('0' + u % 10); u /= 10; } while (u);
    __asm__ volatile("syscall" :: "a"(1l), "D"(1l), "S"(b + i), "d"((long)(24 - i))
                     : "rcx", "r11", "memory");
}

int main(int argc, char **argv) {
    // argv[1] is the granted object's key, marshaled by the parent —
    // the same key the grant record names.
    unsigned long long key = 0;
    if (argc < 2) {
        put("OBJ-ARGV missing\n");
        return 1;
    }
    for (const char *p = argv[1]; *p; p++) key = key * 10 + (unsigned)(*p - '0');

    long fd = syscall(514, key, 2); // openobj(key, O_RDWR)
    put("OBJ-OPEN fd=");
    putn(fd);
    put("\n");
    if (fd < 0) return 2;

    char b[32];
    long n = syscall(0, fd, (long)b, 20);
    put("OBJ-READ n=");
    putn(n);
    put(" [");
    __asm__ volatile("syscall" :: "a"(1l), "D"(1l), "S"(b), "d"(n > 0 ? n : 0)
                     : "rcx", "r11", "memory");
    put("]\n");

    long w = syscall(1, fd, (long)"obj-wrote\n", 10);
    put("OBJ-WRITE w=");
    putn(w);
    put("\n");

    // A key the grant does not name — the seam must refuse BY OBJECT.
    errno = 0;
    long fd2 = syscall(514, 0x0000000000000009ULL, 2); // dev0 ino9
    int fe = errno;
    put("OBJ-DENY fd=");
    putn(fd2);
    put(" e=");
    putn(fd2 < 0 ? fe : 0);
    put("\n");

    return 0;
}
