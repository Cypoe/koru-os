// fsread.c — initramfs child: prove the scoped ChildFsOps view end to
// end. Opens four paths through real syscalls — a plain file, a
// symlink (resolve must follow), a hardlink alias (must share the
// canonical ino), and a file under a SYNTHESIZED parent dir (cpio
// carried no /etc entry) — then prints what it read. Exit 0 only if
// every open+read succeeded; the parent's exec status is the evidence.
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

int main(void) {
    static const char *paths[] = {
        "/hello.txt", "/link.txt", "/hello2.txt", "/etc/motd.txt",
        "/etc/alias.txt",
    };
    char buf[256];
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        int fd = open(paths[i], O_RDONLY);
        if (fd < 0) {
            printf("FSREAD FAIL open %s errno=%d\n", paths[i], errno);
            return 1;
        }
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n < 0) {
            printf("FSREAD FAIL read %s errno=%d\n", paths[i], errno);
            return 1;
        }
        buf[n] = 0;
        printf("FSREAD %s -> %s", paths[i], buf);
        if (n == 0 || buf[n - 1] != '\n') printf("\n");
        close(fd);
    }
    printf("FSREAD COMPLETE\n");
    return 0;
}
