// fscat — the fs-in-child oracle: a real musl binary that opens a file
// in the ext2 it was spawned from (openat/read/close through the seam's
// scoped fs view) and writes the bytes to stdout. Evidence that file
// contents — not just the image — reach ring-3.
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
int main(void) {
    int fd = open("/hello.txt", O_RDONLY);
    if (fd < 0) { puts("FSCAT open refused"); return 41; }
    char buf[64];
    ssize_t n = read(fd, buf, 63);
    if (n <= 0) { puts("FSCAT read failed"); return 40; }
    buf[n] = 0;
    printf("FSCAT %s", buf);
    close(fd);
    return 44;
}
