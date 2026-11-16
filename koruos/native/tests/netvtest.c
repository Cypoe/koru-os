// netvtest.c — the AF_INET oracle for the native virtio-net stack:
// the same socket seam nettest.c drives, but the wire truth is ours —
// guest TCP over eth/ARP/IPv4 to slirp's host alias (10.0.2.2), the
// stub or live LM Studio answering :1234. The negative names what our
// stack can prove honestly: 10.0.2.99 is an address slirp doesn't own,
// so ARP goes unanswered and connect must land EHOSTUNREACH — where the
// relay row's real host RST gave ECONNREFUSED, the slirp peer here
// drops dead-port SYNs silently, so a refused assertion would be a lie.
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

    int fd0 = socket(AF_INET, SOCK_STREAM, 0);
    sa.sin_addr.s_addr = inet_addr("10.0.2.99"); // nobody — ARP dies
    sa.sin_port = htons(80);
    errno = 0;
    CK("unreach-rc", connect(fd0, (void *)&sa, sizeof(sa)), -1);
    CK("unreach-errno", errno, EHOSTUNREACH);
    close(fd0);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    CK("socket", fd >= 0, 1);

    sa.sin_addr.s_addr = inet_addr("10.0.2.2"); // slirp's host alias
    sa.sin_port = htons(1234);
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
    CK("eos", eos, 1); // Connection: close — our FIN/FIN surfaced as 0
    CK("close", close(fd), 0);
    printf("NET COMPLETE fails=%d\n", fails);
    return fails ? 1 : 0;
}
