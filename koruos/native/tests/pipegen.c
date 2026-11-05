// Pipe producer oracle: writes a fixed payload to stdout, which the
// pipeline wires to the ring's write end. Exit 52 marks the writer side.
#include <unistd.h>
int main(void) {
    write(1, "PIPE-DATA-1234567890", 20);
    return 52;
}
