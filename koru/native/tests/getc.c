// Blocking-read fixture: prompt, park on read(0) until the 8042's IRQ1
// delivers a console byte, echo it back, exit 42. The child spends real
// time in .blocked — the keypress is what resumes it, nothing else.
#include <stdio.h>
#include <unistd.h>
int main(void) {
    printf("?> ");
    fflush(stdout);
    char c = 0;
    if (read(0, &c, 1) != 1) return 3;
    printf("GOT=%c\n", c);
    return 42;
}
