#include <stdio.h>
#include <stdlib.h>
int main(int c, char **v){ printf("M5 hello from %s, argc=%d, getenv(PATH)=%s\n", v[0], c, getenv("PATH")); return 42; }
