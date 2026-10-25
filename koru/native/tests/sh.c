// koru shell rung: a musl child that prompts, blocks on read(0) one byte
// at a time (each keypress is a real IRQ1 wake), echoes, and on Enter
// tokenizes the line into an argv block — NUL-separated strings passed
// to nr 57 as (path, rights, blob, bloblen). The spawner parks on the
// child's exit; the status comes back in rax. Bare names resolve in
// bin/ (PATH's honest first shape); 'q' quits the shell.
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
        // tokenize on spaces into a NUL-separated argv blob: argv[0] is
        // the first token; the rest ride as real arguments.
        char blob[192];
        int bn = 0, argc = 0;
        int i = 0;
        while (i < n) {
            while (i < n && line[i] == ' ') i++;
            if (i >= n) break;
            if (argc >= 8 || bn >= (int)sizeof(blob) - 1) break;
            argc++;
            while (i < n && line[i] != ' ' && bn < (int)sizeof(blob) - 1)
                blob[bn++] = line[i++];
            blob[bn++] = 0;
        }
        if (argc == 0) continue;
        // path resolution applies to argv[0] only — the blob keeps the
        // name as typed (argv[0] is what was invoked, not where from).
        char path[96];
        int pn = 0, has_sep = 0;
        for (i = 0; blob[i] != 0; i++) if (blob[i] == '/' || blob[i] == '.') has_sep = 1;
        if (!has_sep) { path[pn++] = 'b'; path[pn++] = 'i'; path[pn++] = 'n'; path[pn++] = '/'; }
        for (i = 0; blob[i] != 0 && pn < (int)sizeof(path) - 1; i++) path[pn++] = blob[i];
        path[pn] = 0;
        long st = syscall(KORU_SPAWN, path, ~0UL, blob, bn);
        printf("exit=%ld\n", st);
    }
}
