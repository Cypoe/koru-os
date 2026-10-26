// writable-fs oracle — a musl child mutates the scoped ext2 view
// through real libc calls, then proves identity survived the view:
//   WTEST-W     — fopen("w") → fwrite → fclose: O_CREAT|O_WRONLY|O_TRUNC
//                 through openat, write(1) on an .fs fd with V_WRITE
//   WTEST-RB    — reopen + read(2) returns the bytes that were written
//   WTEST-RENAME— rename(2): old path is ENOENT, new path carries the
//                 SAME st_ino — the inode is the identity, the path a
//                 projection over it
//   WTEST-UNLINK— unlink(2): the name dies, subsequent open is ENOENT
//   WTEST-DOTDOT— "/bin/../hello.txt" resolves through the on-disk ..
// The gate greps the composite WTEST line; /wren.txt is left in the
// image so the host-side debugfs check can see the mutation persisted.
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

static int fails = 0;
#define CHK(cond, tag) do { if (!(cond)) { fails++; printf("WTEST-FAIL %s e=%d\n", tag, errno); } } while (0)

int main(void) {
    const char *msg = "koru-write: identity survives the view";
    // 1. create + write + close — O_CREAT|O_WRONLY|O_TRUNC on openat,
    //    then write(1) through the .fs fd's W verb.
    FILE *f = fopen("/wlive.txt", "w");
    CHK(f != NULL, "fopen-w");
    if (!f) return 1;
    size_t w = fwrite(msg, 1, strlen(msg), f);
    fclose(f);
    CHK(w == strlen(msg), "fwrite");

    // 2. read it back — the same bytes, on the same fs.
    struct stat st1;
    int fd = open("/wlive.txt", O_RDONLY);
    CHK(fd >= 0, "reopen");
    char rb[64] = {0};
    ssize_t n = read(fd, rb, sizeof(rb) - 1);
    CHK(n == (ssize_t)strlen(msg) && strcmp(rb, msg) == 0, "readback");
    CHK(fstat(fd, &st1) == 0, "fstat1");
    close(fd);

    // 3. rename — the path is a view: the inode underneath must not move.
    CHK(rename("/wlive.txt", "/wren.txt") == 0, "rename");
    errno = 0;
    CHK(open("/wlive.txt", O_RDONLY) < 0 && errno == ENOENT, "old-path-dead");
    struct stat st2;
    int fd2 = open("/wren.txt", O_RDONLY);
    CHK(fd2 >= 0, "new-path");
    CHK(fstat(fd2, &st2) == 0, "fstat2");
    CHK(st2.st_ino == st1.st_ino && st2.st_dev == st1.st_dev, "same-ino");
    memset(rb, 0, sizeof(rb));
    ssize_t n2 = read(fd2, rb, sizeof(rb) - 1);
    CHK(n2 == (ssize_t)strlen(msg) && strcmp(rb, msg) == 0, "rename-content");
    close(fd2);

    // 4. create + unlink — the name and the object both die.
    int fd3 = open("/wdead.txt", O_WRONLY | O_CREAT);
    CHK(fd3 >= 0, "creat2");
    close(fd3);
    CHK(unlink("/wdead.txt") == 0, "unlink");
    errno = 0;
    CHK(open("/wdead.txt", O_RDONLY) < 0 && errno == ENOENT, "unlink-enoent");

    // 5. ".." resolves through the on-disk entry — no special-casing.
    int fd4 = open("/bin/../hello.txt", O_RDONLY);
    CHK(fd4 >= 0, "dotdot");
    if (fd4 >= 0) close(fd4);

    printf("WTEST w=%d rb=%d ino=%llx renamed=%d same-ino=%d unl=%d dot=%d %s\n",
           (int)w, (int)n, (unsigned long long)st1.st_ino,
           st2.st_ino == st1.st_ino ? 1 : 0,
           st2.st_ino == st1.st_ino ? (int)n2 : -1,
           1, fd4 >= 0 ? 1 : 0, fails == 0 ? "DONE" : "FAILS");
    return fails == 0 ? 0 : 1;
}
