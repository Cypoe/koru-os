// shellproof.elf — the pty child oracle for the foot rung. foot forks
// this onto its own pty slave as $SHELL; writing /footproof on the ext2
// view proves the whole spawn chain (posix_openpt→grantpt→unlockpt→
// fork→exec) produced a live process with a real fs view.
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

int main(void) {
    int fd = open("/footproof", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        dprintf(fd, "SHELLPROOF pid=%d\n", getpid());
        close(fd);
    }
    // keep the session alive like a real shell — foot reaps at exit
    char *argv[] = { "/bin/sh", "-i", NULL };
    execv("/bin/sh", argv);
    _exit(113);
}
