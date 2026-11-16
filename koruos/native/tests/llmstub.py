#!/usr/bin/env python3
"""llmstub — the hermetic upstream for the net-uart-relay gate.

The guest's AF_INET oracle (nettest) and klanker's `chat` both name
10.0.2.2:1234 — slirp's host alias, so on the host side that is
127.0.0.1:1234, the port LM Studio's llama-server also owns. This stub
binds that port only when it is free; if a real provider already
answers there it steps aside — both speak the same shapes:

    GET  /v1/models             -> 200 JSON, Connection: close
    POST /v1/chat/completions   -> 200 text/event-stream (SSE) + close

The chat path defaults stream=true, so the answer must be SSE chunks,
not a JSON body: choices[0].delta.content pieces terminated by
data: [DONE]. `Connection: close` is load-bearing — nettest's `eos`
check asserts the peer's EOF surfaces through the relay.

usage: llmstub.py [port]   (default 1234)
"""

import socket
import sys

MODELS = (
    b'{"object":"list","data":[{"id":"stub-llm","object":"model"}]}'
)
SSE = (
    b'data: {"id":"stub","object":"chat.completion.chunk","choices":'
    b'[{"index":0,"delta":{"content":"stub-pong"},"finish_reason":null}]}\n\n'
    b'data: [DONE]\n\n'
)


def reply(method: bytes) -> bytes:
    if method == b"POST":
        body, ctype = SSE, "text/event-stream"
    else:
        body, ctype = MODELS, "application/json"
    return (
        b"HTTP/1.1 200 OK\r\nContent-Type: " + ctype.encode() + b"\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"Connection: close\r\n\r\n" + body
    )


def serve(port: int) -> None:
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        ls.bind(("127.0.0.1", port))
    except OSError:
        # a live provider already owns the port — it serves the same
        # shapes; the gate still exercises real TCP end to end.
        print(f"llmstub: :{port} busy — deferring to the live service",
              flush=True)
        return
    ls.listen(4)
    print(f"llmstub: serving :{port}", flush=True)
    while True:
        c, _ = ls.accept()
        try:
            c.settimeout(5)
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = c.recv(4096)
                if not chunk:
                    break
                buf += chunk
            head, _, rest = buf.partition(b"\r\n\r\n")
            method = head.split(b" ", 1)[0] if head else b"GET"
            # drain the request body so the reply lands on a quiet wire
            want = 0
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    want = int(line.split(b":", 1)[1].strip() or 0)
            while len(rest) < want:
                chunk = c.recv(min(65536, want - len(rest)))
                if not chunk:
                    break
                rest += chunk
            c.sendall(reply(method))
        except (OSError, ValueError):
            pass
        finally:
            try:
                c.close()
            except OSError:
                pass


if __name__ == "__main__":
    serve(int(sys.argv[1]) if len(sys.argv) > 1 else 1234)
