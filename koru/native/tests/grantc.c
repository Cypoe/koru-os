// grantbag oracle — the restricted grandchild. Its bag has NO open class
// bit, only {cap:open, obj:key(hello.txt), verbs:R}. Three claims, all
// measured at the real musl syscall seam:
//   GRANT-OPEN   — openat("/hello.txt") succeeds via the object grant
//   GRANT-DENY   — openat("/sh.elf") is EACCES (real object, no grant)
//   GRANT-AMPLIFY — minting a grant for an uncovered object is refused
//                   at marshal time (§8.6: never amplify)
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <fcntl.h>

#define KORU_SPAWN 512
#define SECT_MAGIC 0x4252474BUL
#define TAG_GRANT 2

int main(void) {
    int fd = open("/hello.txt", O_RDONLY);
    if (fd >= 0) {
        char buf[8];
        int n = (int)read(fd, buf, sizeof(buf));
        printf("GRANT-OPEN n=%d\n", n);
        close(fd);
    } else {
        printf("GRANT-OPEN-FAIL e=%d\n", errno);
    }

    errno = 0;
    int fd2 = open("/sh.elf", O_RDONLY); // real object, no grant
    printf("GRANT-DENY fd=%ld e=%d\n", (long)fd2, errno);

    // over-grant attempt: a key this bag does not cover — parentCovers
    // must refuse the whole spawn before any image loads.
    unsigned char blob[64];
    unsigned char *p = blob;
    const unsigned long long badkey = 0xDEADBEEFULL;
    for (int i = 0; i < 4; i++) *p++ = (SECT_MAGIC >> (8 * i)) & 0xff;
    for (int i = 0; i < 2; i++) *p++ = 1 >> (8 * i);
    for (int i = 0; i < 2; i++) *p++ = TAG_GRANT >> (8 * i);
    for (int i = 0; i < 2; i++) *p++ = 16 >> (8 * i);
    for (int i = 0; i < 8; i++) *p++ = (badkey >> (8 * i)) & 0xff;
    *p++ = 1; *p++ = 2;
    for (int i = 0; i < 6; i++) *p++ = 0;
    errno = 0;
    long r = syscall(KORU_SPAWN, "grantc.elf", ~0L, blob, (long)(p - blob));
    printf("GRANT-AMPLIFY r=%ld e=%d\n", r, errno);
    return 9;
}
