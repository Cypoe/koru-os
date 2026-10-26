// grantbag oracle — parent side. fstat("/hello.txt") yields (st_dev,
// st_ino) = the pin keyspace's object key, marshaled into the spawn
// blob's GRANT section as {cap:open, obj:key, verbs:R}. The grandchild
// spawns with the open CLASS BIT REMOVED from its mask — the only way
// its openat can succeed is the object grant. A mask could never say
// "this file, read-only"; the grant record can.
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <fcntl.h>

#define KORU_SPAWN 512
#define SECT_MAGIC 0x4252474BUL
#define TAG_ARGV 1
#define TAG_GRANT 2

int main(void) {
    write(1, "G0\n", 3);
    struct stat st;
    int fd = open("/hello.txt", O_RDONLY);
    write(1, "G1\n", 3);
    if (fd < 0) { printf("GTEST no hello\n"); return 1; }
    if (fstat(fd, &st) < 0) { printf("GTEST no stat\n"); return 2; }
    close(fd);
    write(1, "G2\n", 3);
    unsigned long long key = ((unsigned long long)st.st_dev << 32) | (unsigned long long)st.st_ino;

    unsigned char blob[96];
    unsigned char *p = blob;
    // byte-wise LE marshal — a u64 store at blob+21 is misaligned and
    // UBSan aborts on it (the hlt in serial WAS musl's a_crash).
    for (int i = 0; i < 4; i++) *p++ = (SECT_MAGIC >> (8 * i)) & 0xff;
    for (int i = 0; i < 2; i++) *p++ = 2 >> (8 * i); // nsec
    for (int i = 0; i < 2; i++) *p++ = TAG_ARGV >> (8 * i);
    const char av[] = "grantc.elf";
    for (int i = 0; i < 2; i++) *p++ = sizeof(av) >> (8 * i);
    for (unsigned i = 0; i < sizeof(av); i++) *p++ = av[i];
    for (int i = 0; i < 2; i++) *p++ = TAG_GRANT >> (8 * i);
    for (int i = 0; i < 2; i++) *p++ = 16 >> (8 * i); // one grant record
    for (int i = 0; i < 8; i++) *p++ = (key >> (8 * i)) & 0xff;
    *p++ = 1;                                      // verbs: R
    *p++ = 2;                                      // cap: open/openat
    for (int i = 0; i < 6; i++) *p++ = 0;

    long mask = ~0L & ~(1L << 2);                  // class open REMOVED
    long rst = syscall(KORU_SPAWN, "grantc.elf", mask, blob, (long)(p - blob));
    printf("GTEST st=%ld key=%llx\n", rst, key);
    return 0;
}
