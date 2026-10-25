// argv evidence child for the shell rung: prints the vector the spawn
// ABI built on its stack, then exits with argc as the status — the
// shell's `exit=N` line proves the number rode home as well.
#include <stdio.h>

int main(int argc, char **argv) {
    printf("argc=%d\n", argc);
    for (int i = 0; i < argc; i++) printf("argv%d=%s\n", i, argv[i]);
    return argc;
}
