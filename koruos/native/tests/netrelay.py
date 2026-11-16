#!/usr/bin/env python3
"""netrelay — the host half of the koru native AF_INET bridge.

QEMU is launched with `-serial tcp:127.0.0.1:4567,server=on,wait=off`
(COM2 toward this process); we connect in and speak the wire:

    0x4E | id | op | len:u16le | payload

guest->host: 1 CONNECT{ip:u32be,port:u16be} 2 DATA 3 CLOSE 4 SHUT
host->guest: 1 COK{errno u8} 2 DATA 3 EOF 4 RST

The relay is the TCP stack placement — every session id maps to one
real TCP connection on the host. It is a development oracle (QEMU dev
boots), not a security boundary: the guest can name any host:port.

usage: netrelay.py [qemu-tcp-port]   (default 4567)
"""

import selectors
import socket
import struct
import sys

MAGIC = 0x4E

OP_CONNECT, OP_DATA, OP_CLOSE, OP_SHUT = 1, 2, 3, 4
OP_COK, OP_DATA_H, OP_EOF, OP_RST = 1, 2, 3, 4


def frame(sid, op, payload=b""):
    return bytes([MAGIC, sid, op]) + struct.pack("<H", len(payload)) + payload


class Relay:
    def __init__(self, port):
        self.port = port
        self.sel = selectors.DefaultSelector()
        self.link = None          # the QEMU chardev socket
        self.rxbuf = bytearray()
        self.conns = {}           # sid -> socket
        self.txq = {}             # sid -> outbound bytes (to the peer)
        self.gtx = bytearray()    # framed bytes bound for the guest

    def guest_send(self, sid, op, payload=b""):
        self.gtx += frame(sid, op, payload)
        self._kick_link()

    def _kick_link(self):
        if self.link is not None:
            self.sel.modify(self.link, selectors.EVENT_READ | selectors.EVENT_WRITE, None)

    # ---- link I/O ----------------------------------------------------

    def link_ready(self, key, mask):
        s = key.fileobj
        if mask & selectors.EVENT_READ:
            try:
                data = s.recv(65536)
            except OSError:
                data = b""
            if not data:
                print("netrelay: link dropped", flush=True)
                self.link = None
                self.rxbuf.clear()
                self.gtx.clear()
                self.sel.unregister(s)
                s.close()
                for sid in list(self.conns):
                    self._close_peer(sid)
                return
            self.rxbuf += data
            self._deframe()
        if mask & selectors.EVENT_WRITE and self.gtx:
            try:
                n = s.send(self.gtx)
                del self.gtx[:n]
                print(f"netrelay: link-tx {n}B", flush=True)
            except OSError:
                self.gtx.clear()
            if not self.gtx:
                self.sel.modify(s, selectors.EVENT_READ, None)

    def _deframe(self):
        while True:
            # resync to the magic byte
            while self.rxbuf and self.rxbuf[0] != MAGIC:
                del self.rxbuf[0]
            if len(self.rxbuf) < 5:
                return
            sid, op = self.rxbuf[1], self.rxbuf[2]
            plen = struct.unpack_from("<H", self.rxbuf, 3)[0]
            if len(self.rxbuf) < 5 + plen:
                return
            payload = bytes(self.rxbuf[5:5 + plen])
            del self.rxbuf[:5 + plen]
            self._command(sid, op, payload)

    # ---- guest commands ----------------------------------------------

    def _command(self, sid, op, payload):
        print(f"netrelay: [{sid}] cmd op={op} n={len(payload)}", flush=True)
        if op == OP_CONNECT:
            ip, port = struct.unpack("!IH", payload[:6])
            self._do_connect(sid, ip, port)
        elif op == OP_DATA:
            self.txq[sid] = self.txq.get(sid, b"") + payload
            c = self.conns.get(sid)
            if c is not None:
                self.sel.modify(c, selectors.EVENT_READ | selectors.EVENT_WRITE, sid)
        elif op == OP_CLOSE:
            self._close_peer(sid)
        elif op == OP_SHUT:
            c = self.conns.get(sid)
            if c is not None:
                try:
                    c.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

    def _do_connect(self, sid, ip, port):
        old = self.conns.pop(sid, None)
        if old is not None:
            try:
                self.sel.unregister(old)
            except Exception:
                pass
            old.close()
        # the guest names slirp-view addresses: 10.0.2.2 IS the host
        # from inside QEMU — the relay maps it to host terms like the
        # real slirp peer would; every other address passes through.
        addr = socket.inet_ntoa(struct.pack("!I", ip))
        if ip == 0x0A000202:
            addr = "127.0.0.1"
        c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        c.settimeout(15)
        try:
            c.connect((addr, port))
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            c.setblocking(False)
        except OSError as e:
            c.close()
            # Windows raises WinError 100xx — map to the POSIX errno
            # the guest's musl expects (10060 ETIMEDOUT, 10061
            # ECONNREFUSED, 10065 EHOSTUNREACH, 10013 EACCES).
            wsa = {10060: 110, 10061: 111, 10065: 113, 10013: 13}
            err = wsa.get(e.errno) or e.errno or \
                (110 if isinstance(e, TimeoutError) else 111)
            print(f"netrelay: [{sid}] connect {addr}:{port} -> {e}", flush=True)
            self.guest_send(sid, OP_COK, bytes([err & 0xFF]))
            return
        self.conns[sid] = c
        self.txq.setdefault(sid, b"")
        self.sel.register(c, selectors.EVENT_READ | selectors.EVENT_WRITE, sid)
        print(f"netrelay: [{sid}] connected {addr}:{port}", flush=True)
        self.guest_send(sid, OP_COK, b"\x00")

    def _close_peer(self, sid):
        c = self.conns.pop(sid, None)
        self.txq.pop(sid, None)
        if c is not None:
            try:
                self.sel.unregister(c)
            except Exception:
                pass
            c.close()

    # ---- peer I/O ----------------------------------------------------

    def peer_ready(self, sid, mask):
        c = self.conns.get(sid)
        if c is None:
            return
        if mask & selectors.EVENT_WRITE and self.txq.get(sid):
            try:
                n = c.send(self.txq[sid])
                self.txq[sid] = self.txq[sid][n:]
            except OSError:
                self.txq[sid] = b""
        if mask & selectors.EVENT_READ:
            try:
                data = c.recv(16384)
            except ConnectionResetError:
                data = None
            except OSError:
                data = None
            if data is None:  # reset
                self._close_peer(sid)
                self.guest_send(sid, OP_RST)
                return
            if data == b"":  # orderly FIN
                self._close_peer(sid)
                self.guest_send(sid, OP_EOF)
                return
            print(f"netrelay: [{sid}] peer->guest {len(data)}B", flush=True)
            self.guest_send(sid, OP_DATA_H, data)
        if not self.txq.get(sid) and self.conns.get(sid) is c:
            self.sel.modify(c, selectors.EVENT_READ | (selectors.EVENT_WRITE if self.txq.get(sid) else 0), sid)

    # ---- main loop ----------------------------------------------------

    def run(self):
        while True:
            if self.link is None:
                try:
                    s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
                except OSError:
                    continue
                s.setblocking(False)
                self.link = s
                self.rxbuf.clear()
                self.gtx.clear()
                self.sel.register(s, selectors.EVENT_READ, None)
                print(f"netrelay: link up :{self.port}", flush=True)
            for key, mask in self.sel.select(timeout=1):
                if key.data is None:
                    self.link_ready(key, mask)
                else:
                    self.peer_ready(key.data, mask)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4567
    Relay(port).run()
