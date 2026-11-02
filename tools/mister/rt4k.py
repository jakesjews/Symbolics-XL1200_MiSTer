#!/usr/bin/env python3
"""Screenshots from the RetroTink 4K through the DonutShop bridge, with direct
video on (the MiSTer's own screenshots are useless then).

  tools/mister/rt4k.py capture OUT.png     Capture Input (AUX 5), answer the OSD's OK,
                                            fetch the PNG the RetroTink saved, delete it there
  tools/mister/rt4k.py cmd 'remote menu'   send one serial command, print its reply lines
  tools/mister/rt4k.py ls [DIR]            list a directory of the RetroTink's SD card

The DonutShop (https://github.com/svirant/DonutShop) serves a WebSocket at
ws://donutshop.local:81 that carries the RetroTink's serial bytes as binary
messages. Commands are lines ending in CR and answer in lines; a file comes
back after a "get ready" line as RTL1 frames (A5 5A, nonce, length, type,
sequence, payload, CRC-16/CCITT-FALSE), ended by a RESP frame. All of it as
the DonutShop's web client does it (RT4K WebCtl, firmware 1.72+).
Standard library only.
"""
import base64, hashlib, os, re, socket, struct, sys, time

HOST = os.environ.get("RT4K_HOST", "donutshop.local")
PORT = 81

T_CMD, T_RESP, T_DATA, T_ACK, T_NAK, T_ABORT, T_PING = 1, 2, 3, 4, 5, 6, 7

CRC_TBL = []
for i in range(256):
    c = (i << 8) & 0xFFFF
    for _ in range(8):
        c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    CRC_TBL.append(c)


def crc16(b):
    c = 0xFFFF
    for x in b:
        c = ((c << 8) & 0xFFFF) ^ CRC_TBL[((c >> 8) ^ x) & 0xFF]
    return c


def rtl1_frame(nonce, type_, seq, payload=b""):
    f = bytes([0xA5, 0x5A, nonce & 0xFF, nonce >> 8, len(payload) & 0xFF, len(payload) >> 8, type_, seq & 0xFF]) + payload
    c = crc16(f[2:])
    return f + bytes([c & 0xFF, c >> 8])


class Link:
    """A WebSocket to the bridge, read as a byte stream."""

    def __init__(self, host=HOST, port=PORT):
        self.s = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: http://{host}\r\n\r\n").encode())
        hdr = b""
        while b"\r\n\r\n" not in hdr:
            d = self.s.recv(1024)
            if not d:
                raise RuntimeError("bridge closed the connection")
            hdr += d
        if b" 101 " not in hdr.split(b"\r\n")[0]:
            raise RuntimeError("no WebSocket: " + hdr.split(b"\r\n")[0].decode(errors="replace"))
        self.raw = hdr.split(b"\r\n\r\n", 1)[1]   # WebSocket frames
        self.bytes = b""                         # serial bytes received
        self.send_text('{"type":"rt4k-bridge","op":"hello"}')

    def _frame(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        h = bytes([0x80 | opcode])
        if n < 126:
            h += bytes([0x80 | n])
        elif n < 65536:
            h += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            h += bytes([0x80 | 127]) + struct.pack(">Q", n)
        return h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    def send_text(self, s):
        self.s.sendall(self._frame(1, s.encode()))

    def send(self, b):
        self.s.sendall(self._frame(2, b))

    def pump(self, timeout):
        """Read WebSocket frames for up to timeout seconds; binary payloads
        join the serial byte stream. Returns False on a quiet timeout."""
        self.s.settimeout(timeout)
        try:
            d = self.s.recv(65536)
        except socket.timeout:
            return False
        if not d:
            raise RuntimeError("bridge closed the connection")
        self.raw += d
        while True:
            if len(self.raw) < 2:
                return True
            fin_op, l = self.raw[0], self.raw[1] & 0x7F
            off = 2
            if l == 126:
                if len(self.raw) < 4:
                    return True
                l = struct.unpack(">H", self.raw[2:4])[0]
                off = 4
            elif l == 127:
                if len(self.raw) < 10:
                    return True
                l = struct.unpack(">Q", self.raw[2:10])[0]
                off = 10
            if self.raw[1] & 0x80:
                off += 4   # a masked frame from the server: not expected
            if len(self.raw) < off + l:
                return True
            payload = self.raw[off:off + l]
            self.raw = self.raw[off + l:]
            op = fin_op & 0x0F
            if op == 2:
                self.bytes += payload
            elif op == 9:
                self.s.sendall(self._frame(10, payload))
            elif op == 8:
                raise RuntimeError("bridge closed the WebSocket")

    def lines(self):
        """Take the complete text lines received so far."""
        out = []
        while True:
            i = self.bytes.find(b"\n")
            if i < 0:
                break
            l = self.bytes[:i].decode(errors="replace").rstrip("\r")
            out.append(re.sub(r"^\[(COM|HD15)\] ", "", l))   # the port the line came in on
            self.bytes = self.bytes[i + 1:]
        return out

    def cmd(self, line, until, timeout=5.0):
        """Send a command line; collect the reply lines until one matches."""
        self.bytes = b""
        self.send(line.encode() + b"\r")
        got = []
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.2)
            for l in self.lines():
                got.append(l)
                if re.search(until, l):
                    return got
        raise RuntimeError(f"{line}: no answer matching {until!r}; got {got}")

    def remote(self, key, settle=0.4):
        self.cmd("remote " + key, r"^Serial Remote", timeout=2)
        time.sleep(settle)

    def ls(self, path=""):
        lines = self.cmd("ls" + (" " + path if path else ""), r"^ls (end|err)|^ls: busy", timeout=20)
        if re.match(r"^ls: busy", lines[-1]):
            return None
        ents = []
        for l in lines:
            m = re.match(r"^ent t=([DF]) sz=(\d+) mt=(\d+) nm=(.*)$", l)
            if m:
                ents.append((m.group(1) == "D", int(m.group(2)), int(m.group(3)), m.group(4)))
        return ents

    def get(self, path, timeout=120):
        """Fetch a file: a plain get (the RetroTink answers with its SHA-256)."""
        lines = self.cmd("get -- " + path,
                         r"^get ready off=(\d+) len=(\d+) total=(\d+) nonce=0x([0-9A-Fa-f]+)|busy|err|bad flags|need a path",
                         timeout=10)
        m = re.match(r"^get ready off=(\d+) len=(\d+) total=(\d+) nonce=0x([0-9A-Fa-f]+)", lines[-1])
        if not m:
            raise RuntimeError("get: " + lines[-1])
        total, nonce = int(m.group(3)), int(m.group(4), 16)
        out = bytearray()
        seq = 0
        sha = None
        end = time.time() + timeout
        # the decoder over the byte stream: resync on A5 5A
        while time.time() < end and sha is None:
            self.pump(0.5)
            while True:
                i = self.bytes.find(b"\xa5\x5a")
                if i < 0:
                    self.bytes = b""
                    break
                if len(self.bytes) < i + 8:
                    self.bytes = self.bytes[i:]
                    break
                n = self.bytes[i + 4] | (self.bytes[i + 5] << 8)
                if n > 2048:
                    self.bytes = self.bytes[i + 1:]
                    continue
                if len(self.bytes) < i + 10 + n:
                    self.bytes = self.bytes[i:]
                    break
                f = self.bytes[i:i + 10 + n]
                self.bytes = self.bytes[i + 10 + n:]
                if crc16(f[2:8 + n]) != (f[8 + n] | (f[9 + n] << 8)):
                    continue
                fnonce, ftype, fseq, payload = f[2] | (f[3] << 8), f[6], f[7], f[8:8 + n]
                if fnonce != nonce:
                    continue
                if ftype == T_DATA:
                    if fseq != (seq & 0xFF):
                        self.send(rtl1_frame(nonce, T_ABORT, 0))
                        raise RuntimeError(f"get: sequence {fseq}, wanted {seq & 0xFF}")
                    out += payload
                    seq += 1
                elif ftype == T_RESP:
                    sha = bytes(payload)
                elif ftype == T_NAK:
                    raise RuntimeError("get: device NAK")
        if sha is None:
            self.send(rtl1_frame(nonce, T_ABORT, 0))
            raise RuntimeError(f"get: timed out with {len(out)} of {total} bytes")
        if len(out) != total:
            raise RuntimeError(f"get: {len(out)} of {total} bytes")
        if len(sha) == 32 and hashlib.sha256(out).digest() != sha:
            raise RuntimeError("get: SHA-256 mismatch")
        # the terminal text after the session
        time.sleep(0.3)
        self.pump(0.3)
        self.bytes = b""
        return bytes(out)

    def rm(self, path):
        self.cmd("rm " + path, r"^rm (ok|err)|^rm: busy", timeout=10)


def capture(out_path, link):
    before = {e[3] for e in (link.ls("screenshots") or [])}
    link.remote("aux5")               # Capture Input: the OSD asks, Cancel selected
    link.remote("right")
    link.remote("ok")
    name = None
    size = -1
    for _ in range(60):               # the picture pauses while it saves
        time.sleep(2)
        ents = link.ls("screenshots")
        if ents is None:
            continue
        new = [e for e in ents if not e[0] and e[3] not in before and e[3].lower().endswith(".png")]
        if new:
            e = max(new, key=lambda e: e[2])
            if e[1] > 0 and e[1] == size:
                name = e[3]
                break
            size = e[1]
    if not name:
        raise RuntimeError("no new screenshot appeared on the RetroTink")
    data = link.get("screenshots/" + name)
    with open(out_path, "wb") as f:
        f.write(data)
    link.rm("screenshots/" + name)
    return name, len(data)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("capture", "cmd", "ls"):
        print(__doc__)
        return 2
    link = Link()
    if sys.argv[1] == "capture":
        name, n = capture(sys.argv[2], link)
        print(f"{sys.argv[2]}: {n} bytes ({name})")
    elif sys.argv[1] == "cmd":
        for l in link.cmd(sys.argv[2], r"$^|.", timeout=1.5):
            print(l)
        time.sleep(0.5); link.pump(0.5)
        for l in link.lines():
            print(l)
    else:
        for d, sz, _mt, nm in link.ls(sys.argv[2] if len(sys.argv) > 2 else "") or []:
            print(f"{'d' if d else ' '} {sz:>10} {nm}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
