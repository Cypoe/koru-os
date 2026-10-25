// koru shell rung: a musl child that prompts, blocks on read(0) one byte
// at a time (each keypress is a real IRQ1 wake), echoes, and on Enter
// spawns the typed name through nr 57 — the caller parks .blocked on the
// spawned child's exit and the status comes back in rax. Bare names
// resolve in bin/ (PATH's honest first shape); 'q' quits the shell.
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>

#define KORU_SPAWN 57

int main(void) {
    char line[64];
    for (;;) {
        printf("koru> ");
        fflush(stdout);
        int n = 0;
        for (;;) {
            char ch = 0;
            if (read(0, &ch, 1) != 1) return 4;
            if (ch == '\r' || ch == '\n') { write(1, "\n", 1); break; }
            write(1, &ch, 1);
            if (n < (int)sizeof(line) - 1) line[n++] = ch;
        }
        line[n] = 0;
        if (n == 0) continue;
        if (n == 1 && line[0] == 'q') { printf("bye\n"); return 47; }
        char path[96];
        int pn = 0, has_sep = 0;
        for (int i = 0; i < n; i++) if (line[i] == '/' || line[i] == '.') has_sep = 1;
        if (!has_sep) { path[pn++] = 'b'; path[pn++] = 'i'; path[pn++] = 'n'; path[pn++] = '/'; }
        for (int i = 0; i < n && pn < (int)sizeof(path) - 1; i++) path[pn++] = line[i];
        path[pn] = 0;
        long st = syscall(KORU_SPAWN, path, ~0UL);
        printf("exit=%ld\n", st);
    }
}
