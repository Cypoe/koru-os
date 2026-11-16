// nettest.c — the AF_INET oracle for the COM2 relay bridge: real
// socket/connect/send/recv/poll/EOS against a live host TCP service
// (10.0.2.2:1234 via slirp — llmstub.py answers when the port is free,
// LM Studio's llama-server serves the same shapes when it owns it),
// plus the negative: a connect to a dead port must come back
// ECONNREFUSED through the relay's COK error path, not a hang or a lie.
#define _GNU_SOURCE
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <poll.h>

static int fails = 0;
#define CK(tag, got, want) do { long _g = (long)(got); \
    printf("NET %s got=%ld want=%ld\n", tag, _g, (long)(want)); \
    fflush(stdout); \
    if (_g != (long)(want)) fails++; } while (0)

int main(void) {
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = inet_addr("10.0.2.2");

    int fd0 = socket(AF_INET, SOCK_STREAM, 0);
    sa.sin_port = htons(9); // discard port — nothing listens
    errno = 0;
    CK("refused-rc", connect(fd0, (void *)&sa, sizeof(sa)), -1);
    CK("refused-errno", errno, ECONNREFUSED);
    close(fd0);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    CK("socket", fd >= 0, 1);

    sa.sin_port = htons(1234); // the live llama-server
    errno = 0;
    CK("connect", connect(fd, (void *)&sa, sizeof(sa)), 0);

    const char *req = "GET /v1/models HTTP/1.1\r\n"
                      "Host: 10.0.2.2\r\nConnection: close\r\n\r\n";
    CK("send", send(fd, req, strlen(req), 0) > 0, 1);

    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    CK("poll", poll(&pfd, 1, 15000) > 0, 1);

    char buf[4096];
    int total = 0, eos = 0;
    for (;;) {
        int n = recv(fd, buf + total, sizeof(buf) - 1 - total, 0);
        if (n <= 0) { eos = (n == 0); break; }
        total += n;
        if (total >= (int)sizeof(buf) - 1) break;
    }
    buf[total] = 0;
    CK("recv-bytes", total > 0, 1);
    CK("http-200", strstr(buf, "200") != 0, 1);
    CK("eos", eos, 1); // Connection: close — the relay's EOF surfaced
    CK("close", close(fd), 0);
    printf("NET COMPLETE fails=%d\n", fails);
    return fails ? 1 : 0;
}
