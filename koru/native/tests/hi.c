// PT_INTERP fixture: a two-lib dynamic hello — NEEDED [liblibhi.so, libc.so].
// The answer crosses a real DSO boundary: openat → file-mmap → reloc → call.
#include <stdio.h>
int hi(void);
int main(void) { printf("HI=%d\n", hi()); return 0; }
