// Pipe consumer oracle: drains stdin to EOS, echoes the payload to its
// own stdout (wired to conout in the pipeline), then reports the count.
// Its read(0) parks on the pipe ring — not the console — until bytes or
// the writer's death arrive. Exit 51 marks a clean drain.
#include <stdio.h>
#include <unistd.h>
int main(void) {
    char b[64];
    long t = 0;
    for (;;) {
        long n = read(0, b, sizeof(b));
        if (n <= 0) break;
        t += n;
        write(1, b, n);
    }
    printf("\nCATC n=%ld\n", t);
    return 51;
}
