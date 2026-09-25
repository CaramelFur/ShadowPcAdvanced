#!/usr/bin/env python3
"""A fake SPICE server for `ShadowPcAdvanced --selftest-input ws://127.0.0.1:PORT/`.

Speaks just enough SPICE over WebSocket (main + inputs channels, no display,
ticket not checked) for spice-glib to bring its inputs channel up, then prints
every inputs-channel message with its arrival time, grouped by the markers the
self-test sends between scenarios (a pointer position with x = 9000 + n), and a
tally per scenario: how many key make codes arrived per key. That is what one
keystroke becomes on the wire.

    Scripts/fake-spice-inputs.py [port]        # default 8766; Ctrl-C to stop

Needs only python3 and the openssl CLI (for a throwaway RSA key: spice-glib
encrypts the ticket with it; the server never decrypts).
"""
import asyncio
import base64
import collections
import hashlib
import struct
import subprocess
import sys
import time

# Must match InputSelfTest.scenarios (App/Console/InputSelfTest.swift).
SCENARIOS = [
    "tap A (70 ms)",
    "hold A 350 ms (macOS repeats after InitialKeyRepeat)",
    "hold D 900 ms (a deliberate hold, e.g. Backspace)",
    "Shift+S, Shift let go before S",
    "rollover: Q down, W down, Q up, W up",
    "left click",
    "⌘ tap (→ Windows key)",
    "⌘K with no menu item (AppKit never delivers K's key-up)",
]

MAIN, INPUTS = 1, 3
MSG = {101: "KEY_DOWN", 102: "KEY_UP", 103: "KEY_MODIFIERS", 104: "KEY_SCANCODE",
       111: "MOUSE_MOTION", 112: "MOUSE_POSITION", 113: "MOUSE_PRESS", 114: "MOUSE_RELEASE"}


def make_pubkey():
    der = subprocess.run("openssl genrsa 1024 2>/dev/null | openssl rsa -pubout -outform DER 2>/dev/null",
                         shell=True, capture_output=True, check=True).stdout
    assert len(der) == 162, f"unexpected public key size {len(der)}"
    return der


PUBKEY = make_pubkey()
T0 = time.monotonic()


def stamp():
    return f"{(time.monotonic() - T0) * 1000:9.1f} ms"


class WebSocket:
    def __init__(self, reader, writer):
        self.reader, self.writer, self.buf = reader, writer, bytearray()

    async def handshake(self):
        head = await self.reader.readuntil(b"\r\n\r\n")
        key = next(l.split(b":", 1)[1].strip() for l in head.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key:"))
        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        self.writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          b"Sec-WebSocket-Protocol: binary\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")

    async def _frame(self):
        b0, b1 = await self.reader.readexactly(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", await self.reader.readexactly(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", await self.reader.readexactly(8))[0]
        mask = await self.reader.readexactly(4) if b1 & 0x80 else b"\0\0\0\0"
        data = bytearray(await self.reader.readexactly(n))
        for i in range(n):
            data[i] ^= mask[i & 3]
        return b0 & 0x0F, bytes(data)

    async def read(self, n):
        while len(self.buf) < n:
            opcode, data = await self._frame()
            if opcode == 0x8:
                raise EOFError
            if opcode in (0x0, 0x1, 0x2):
                self.buf += data
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def send(self, data):
        n = len(data)
        head = bytes([0x82, n]) if n < 126 else bytes([0x82, 126]) + struct.pack(">H", n)
        self.writer.write(head + data)


def spice_msg(msg_type, body=b""):
    return struct.pack("<HI", msg_type, len(body)) + body  # mini header


async def link(ws):
    magic, major, minor, size = struct.unpack("<4sIII", await ws.read(16))
    assert magic == b"REDQ" and major == 2, (magic, major)
    mess = await ws.read(size)
    _, ctype, cid, _, _, _ = struct.unpack("<IBBIII", mess[:18])
    common = [(1 << 0) | (1 << 1) | (1 << 3)]  # auth selection, spice auth, mini header
    chan = [1] if ctype == INPUTS else []      # SPICE_INPUTS_CAP_KEY_SCANCODE, like spice-server
    reply = struct.pack("<I", 0) + PUBKEY + struct.pack("<III", len(common), len(chan), 4 + 162 + 12)
    reply += b"".join(struct.pack("<I", c) for c in common + chan)
    ws.send(struct.pack("<4sIII", b"REDQ", 2, 2, len(reply)) + reply)
    await ws.read(4)    # auth mechanism
    await ws.read(128)  # encrypted ticket, not checked
    ws.send(struct.pack("<I", 0))
    return ctype, cid


class Recorder:
    """Groups inputs messages by scenario marker and tallies make codes."""

    def __init__(self):
        self.scenario = None
        self.makes = collections.Counter()
        self.lines = []

    def close_scenario(self):
        if self.scenario is None:
            return
        name = SCENARIOS[self.scenario] if self.scenario < len(SCENARIOS) else f"scenario {self.scenario}"
        tally = ", ".join(f"{code}: {n} make{'s' if n != 1 else ''}" for code, n in self.makes.items()) or "no key make codes"
        print(f"  => {tally}", flush=True)
        self.scenario = None

    def marker(self, n):
        self.close_scenario()
        self.scenario, self.makes = n, collections.Counter()
        name = SCENARIOS[n] if n < len(SCENARIOS) else f"scenario {n}"
        print(f"--- {n + 1}. {name}", flush=True)

    def key_bytes(self, raw):
        """Counts make codes in a set-1 byte sequence (E0-prefixed = one key)."""
        i = 0
        while i < len(raw):
            prefix = ""
            if raw[i] == 0xE0 and i + 1 < len(raw):
                prefix, i = "e0", i + 1
            code = raw[i]
            if not code & 0x80:
                self.makes[f"0x{prefix}{code:02x}"] += 1
            i += 1


async def serve_inputs(ws, rec):
    ws.send(spice_msg(101, struct.pack("<H", 0)))  # INPUTS_INIT, no locks
    motions = 0
    while True:
        t, n = struct.unpack("<HI", await ws.read(6))
        body = await ws.read(n)
        name = MSG.get(t, f"type {t}")
        if t == 112:
            x, y, mask, _ = struct.unpack("<IIHB", body)
            motions += 1
            if x >= 9000:
                rec.marker(x - 9000)
                detail = None
            else:
                detail = f"{x},{y} mask={mask}"
        elif t in (101, 102):
            code = struct.unpack("<I", body)[0]
            raw = bytes(b for b in struct.pack("<I", code) if b)
            detail = raw.hex(" ")
            if t == 101:
                rec.key_bytes(raw)
        elif t == 104:
            detail = body.hex(" ") + "  (press+release in one message)"
            rec.key_bytes(body)
        elif t in (113, 114):
            button, mask = struct.unpack("<BH", body)
            detail = f"button={button} mask={mask}"
        elif t == 111:
            dx, dy, mask = struct.unpack("<iiH", body)
            motions += 1
            detail = f"{dx},{dy} mask={mask}"
        else:
            detail = body.hex(" ")
        if detail is not None:
            print(f"  {stamp()}  {name:<14} {detail}", flush=True)
        if t in (111, 112) and motions % 4 == 0:
            ws.send(spice_msg(111))  # MOUSE_MOTION_ACK keeps spice-glib's pointer queue open


async def serve_main(ws):
    ws.send(spice_msg(103, struct.pack("<8I", 1, 0, 3, 2, 0, 0, 0, 0)))  # INIT: client mouse mode
    while True:
        t, n = struct.unpack("<HI", await ws.read(6))
        await ws.read(n)
        if t == 104:  # ATTACH_CHANNELS → just an inputs channel
            ws.send(spice_msg(104, struct.pack("<I", 1) + bytes([INPUTS, 0])))


async def handle(reader, writer, rec):
    ws = WebSocket(reader, writer)
    try:
        await ws.handshake()
        ctype, cid = await link(ws)
        print(f"# channel {ctype}.{cid} linked", flush=True)
        if ctype == MAIN:
            await serve_main(ws)
        elif ctype == INPUTS:
            await serve_inputs(ws, rec)
        else:
            await reader.read()
    except (EOFError, asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        if rec.scenario is not None:
            rec.close_scenario()
        writer.close()


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
    rec = Recorder()
    server = await asyncio.start_server(lambda r, w: handle(r, w, rec), "127.0.0.1", port)
    print(f"# fake SPICE server on ws://127.0.0.1:{port}/", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
