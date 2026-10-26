// koru shell rung: a musl child that prompts, blocks on read(0) one byte
// at a time (each keypress is a real IRQ1 wake), echoes, and on Enter
// tokenizes the line into an argv block — NUL-separated strings passed
// to nr 512 as (path, rights, blob, bloblen). The spawner parks on the
// child's exit; the status comes back in rax. Bare names resolve in
// bin/ (PATH's honest first shape); 'q' quits the shell.
//
// `a | b` is the pipeline arm: pipe() mints a kernel ring into the
// shell's fd table; nr513 spawn_start projects ends into each child —
// the READER spawns first (its read parks on the empty ring, .pipe wait
// kind), then the writer with fd1 wired to the write end. The shell
// closes its own ends (writer's exit is then the only EOS source) and
// nr61 waits each zombie's status.
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/wait.h>

// koru's own ABI lives at 512+ — musl's namespace keeps its real nrs:
// nr57 IS fork (musl _Fork sends it), nr61 wait4 is real already.
// canonNr folds 512/513 onto caps 57/58, so bags read the same.
#define KORU_SPAWN 512
#define KORU_SPAWN_START 513
#define KORU_WAIT 61
#define NO_FD (~0UL)

// The spawn blob is the bag's wire form: 'KGRB' + nsec + TLV sections.
// The shell marshals argv only (section 1, NUL-separated); grants would
// ride section 2 — object-scoped rights a mask cannot say.
#define SECT_MAGIC 0x4252474BUL // 'KGRB'
#define TAG_ARGV 1

// little-endian byte stores — the stream is byte-defined, and a u32
// store through char* can land misaligned (UBSan aborts on it).
static void w16(char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void w32(char *p, unsigned long v) {
    w16(p, v & 0xffff); w16(p + 2, (v >> 16) & 0xffff);
}

// wrap an argv blob into the KGRB section stream; returns stream len.
static int wrap_blob(char *argv, int alen, char *out, int omax) {
    if (alen + 10 > omax) return 0;
    w32(out + 0, SECT_MAGIC);
    w16(out + 4, 1); // nsec
    w16(out + 6, TAG_ARGV);
    w16(out + 8, (unsigned)alen);
    for (int i = 0; i < alen; i++) out[10 + i] = argv[i];
    return 10 + alen;
}

// tokenize s[0..n) on spaces into a NUL-separated argv blob; blob len or 0.
static int tokenize(char *s, int n, char *blob, int bmax) {
    int bn = 0, argc = 0, i = 0;
    while (i < n) {
        while (i < n && s[i] == ' ') i++;
        if (i >= n) break;
        if (argc >= 8 || bn >= bmax - 1) break;
        argc++;
        while (i < n && s[i] != ' ' && bn < bmax - 1)
            blob[bn++] = s[i++];
        blob[bn++] = 0;
    }
    return argc ? bn : 0;
}

// resolve argv[0] of a blob into path — bare names get bin/; a path with
// '/' or '.' is taken as spelled. argv[0] itself stays as typed.
static void resolve(char *blob, char *path, int pmax) {
    int pn = 0, has_sep = 0, i;
    for (i = 0; blob[i] != 0; i++) if (blob[i] == '/' || blob[i] == '.') has_sep = 1;
    if (!has_sep) { path[pn++] = 'b'; path[pn++] = 'i'; path[pn++] = 'n'; path[pn++] = '/'; }
    for (i = 0; blob[i] != 0 && pn < pmax - 1; i++) path[pn++] = blob[i];
    path[pn] = 0;
}

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

        // one '|' splits a pipeline: left produces, right consumes
        int bar = -1;
        for (int i = 0; i < n; i++) if (line[i] == '|') bar = i;
        char blob[192], blob2[192], path[96], path2[96];
        char sect[224], sect2[224];
        if (bar >= 0) {
            int bn = tokenize(line, bar, blob, sizeof(blob));
            int bn2 = tokenize(line + bar + 1, n - bar - 1, blob2, sizeof(blob2));
            if (!bn || !bn2) { printf("pipe: bad side\n"); continue; }
            resolve(blob, path, sizeof(path));
            resolve(blob2, path2, sizeof(path2));
            int slen = wrap_blob(blob, bn, sect, sizeof(sect));
            int slen2 = wrap_blob(blob2, bn2, sect2, sizeof(sect2));
            if (!slen || !slen2) { printf("pipe: blob\n"); continue; }
            int pfds[2];
            if (syscall(22, pfds) < 0) { printf("pipe: refused\n"); continue; }
            // reader first: its read parks on the empty ring — the .pipe
            // block is deterministic evidence, not timing luck.
            // fd args must be (long) — an int through varargs reaches
            // r8/r9 with poisoned high bits (observed: 0xaaaa0003).
            long rd = syscall(KORU_SPAWN_START, path2, ~0UL, sect2, (long)slen2, (long)pfds[0], NO_FD);
            long wr = rd < 0 ? rd
                : syscall(KORU_SPAWN_START, path, ~0UL, sect, (long)slen, NO_FD, (long)pfds[1]);
            close(pfds[0]);
            close(pfds[1]);
            if (rd < 0 || wr < 0) { printf("pipe: spawn=%ld/%ld errno=%d\n", rd, wr, errno); continue; }
            int wcode = -1, rcode = -1;
            syscall(KORU_WAIT, wr, &wcode);
            syscall(KORU_WAIT, rd, &rcode);
            // nr61 hands a real wait4 status word — the code is encoded
            printf("pipe: w=%d r=%d\n", WEXITSTATUS(wcode), WEXITSTATUS(rcode));
            continue;
        }

        int bn = tokenize(line, n, blob, sizeof(blob));
        if (!bn) continue;
        resolve(blob, path, sizeof(path));
        int slen = wrap_blob(blob, bn, sect, sizeof(sect));
        if (!slen) continue;
        long st = syscall(KORU_SPAWN, path, ~0UL, sect, (long)slen);
        printf("exit=%ld\n", st);
    }
}
