#!/usr/bin/env python3
"""Tiny X11 protocol logging proxy (Unix sockets only).
usage: xproxy.py LISTEN_DISPLAY_NUM TARGET_DISPLAY_NUM LOGFILE
Logs one line per request / reply / event / error, per connection."""
import os, selectors, socket, struct, sys, time

CORE = {1:"CreateWindow",2:"ChangeWindowAttributes",3:"GetWindowAttributes",4:"DestroyWindow",8:"MapWindow",
 12:"ConfigureWindow",14:"GetGeometry",15:"QueryTree",16:"InternAtom",18:"ChangeProperty",20:"GetProperty",
 23:"GetSelectionOwner",25:"SendEvent",26:"GrabPointer",27:"UngrabPointer",31:"GrabKeyboard",32:"UngrabKeyboard",
 36:"GrabServer",37:"UngrabServer",38:"QueryPointer",42:"SetInputFocus",43:"GetInputFocus",45:"OpenFont",
 46:"CloseFont",47:"QueryFont",49:"ListFonts",50:"ListFontsWithInfo",51:"SetFontPath",52:"GetFontPath",
 53:"CreatePixmap",54:"FreePixmap",55:"CreateGC",56:"ChangeGC",59:"SetClipRectangles",60:"FreeGC",61:"ClearArea",
 62:"CopyArea",63:"CopyPlane",64:"PolyPoint",65:"PolyLine",66:"PolySegment",67:"PolyRectangle",69:"FillPoly",
 70:"PolyFillRectangle",72:"PutImage",73:"GetImage",74:"PolyText8",76:"ImageText8",78:"CreateColormap",
 84:"AllocColor",85:"AllocNamedColor",91:"QueryColors",92:"LookupColor",93:"CreateCursor",94:"CreateGlyphCursor",
 97:"QueryBestSize",98:"QueryExtension",99:"ListExtensions",100:"ChangeKeyboardMapping",101:"GetKeyboardMapping",
 102:"ChangeKeyboardControl",103:"GetKeyboardControl",104:"Bell",107:"SetScreenSaver",115:"ForceScreenSaver",
 116:"SetPointerMapping",117:"GetPointerMapping",118:"SetModifierMapping",119:"GetModifierMapping",127:"NoOperation"}
EVENTS = {2:"KeyPress",3:"KeyRelease",4:"ButtonPress",5:"ButtonRelease",6:"MotionNotify",7:"EnterNotify",8:"LeaveNotify",
 9:"FocusIn",10:"FocusOut",11:"KeymapNotify",12:"Expose",13:"GraphicsExpose",14:"NoExpose",15:"VisibilityNotify",
 19:"MapNotify",22:"ConfigureNotify",28:"PropertyNotify",33:"ClientMessage",34:"MappingNotify"}

listen_n, target_n, logname = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
log = open(logname, "a", buffering=1)
path = "/tmp/.X11-unix/X%d" % listen_n
try: os.unlink(path)
except FileNotFoundError: pass
ls = socket.socket(socket.AF_UNIX); ls.bind(path); ls.listen(8)
lock = "/tmp/.X%d-lock" % listen_n
open(lock, "w").write("%10d\n" % os.getpid())
import signal
def bye(*_):
    for f in (path, lock):
        try: os.unlink(f)
        except OSError: pass
    sys.exit(0)
signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGINT, bye)
sel = selectors.DefaultSelector(); sel.register(ls, selectors.EVENT_READ, None)
conns = {}; nextid = [0]

class Half:
    def __init__(s, cid, c2s): s.cid=cid; s.c2s=c2s; s.buf=b""; s.setup=True; s.seq=0
    def feed(s, data):
        s.buf += data
        out = []
        while True:
            b = s.buf
            if s.c2s:
                if s.setup:
                    if len(b) < 12: break
                    n, d = struct.unpack("<HH", b[6:10]); tot = 12 + ((n+3)&~3) + ((d+3)&~3)
                    if len(b) < tot: break
                    out.append("SETUP-REQ"); s.setup=False; s.buf=b[tot:]; continue
                if len(b) < 4: break
                ln = struct.unpack("<H", b[2:4])[0]*4
                if ln == 0:
                    if len(b) < 8: break
                    ln = struct.unpack("<I", b[4:8])[0]*4
                if len(b) < ln: break
                s.seq += 1; op=b[0]
                name = CORE.get(op, "op%d" % op)
                extra = ""
                if op == 118:
                    k = b[1]; codes = list(b[4:4+8*k])
                    extra = " kpm=%d %s" % (k, [[c for c in codes[i*k:(i+1)*k] if c] for i in range(8)])
                if op in (119, 101): s.pending = getattr(s, "pending", {}); s.pending[s.seq & 0xffff] = op
                out.append("REQ #%d %s%s len=%d" % (s.seq & 0xffff, name, extra, ln)); s.buf=b[ln:]
            else:
                if s.setup:
                    if len(b) < 8: break
                    tot = 8 + struct.unpack("<H", b[6:8])[0]*4
                    if len(b) < tot: break
                    out.append("SETUP-REPLY status=%d" % b[0]); s.setup=False; s.buf=b[tot:]; continue
                if len(b) < 32: break
                t = b[0]; seq = struct.unpack("<H", b[2:4])[0]
                if t == 1:
                    tot = 32 + struct.unpack("<I", b[4:8])[0]*4
                    if len(b) < tot: break
                    extra = ""
                    peer = getattr(s, "peer", None)
                    if peer is not None and getattr(peer, "pending", {}).get(seq) == 119:
                        k = b[1]; codes = list(b[32:32+8*k])
                        extra = " MODMAP kpm=%d %s" % (k, [[c for c in codes[i*k:(i+1)*k] if c] for i in range(8)])
                    out.append("REPLY seq=%d b1=%d len=%d%s" % (seq, b[1], tot, extra))
                elif t == 0:
                    tot = 32; out.append("ERROR code=%d seq=%d major=%d" % (b[1], seq, b[10]))
                elif (t & 0x7f) == 35:
                    tot = 32 + struct.unpack("<I", b[4:8])[0]*4
                    if len(b) < tot: break
                    out.append("EVENT Generic")
                else:
                    tot = 32; e = t & 0x7f
                    nm = EVENTS.get(e, "ev%d" % e)
                    if e == 34: nm += " request=%d" % b[4]
                    if e in (2, 3): nm += " keycode=%d state=%#x" % (b[1], struct.unpack("<H", b[28:30])[0])
                    out.append("EVENT %s seq=%d" % (nm, seq))
                s.buf = b[tot:]
        for o in out:
            log.write("%.3f c%d %s %s\n" % (time.time(), s.cid, "C>S" if s.c2s else "S>C", o))

while True:
    for key, _ in sel.select():
        if key.data is None:
            c, _ = ls.accept(); u = socket.socket(socket.AF_UNIX); u.connect("/tmp/.X11-unix/X%d" % target_n)
            cid = nextid[0]; nextid[0] += 1
            log.write("%.3f c%d CONNECT\n" % (time.time(), cid))
            h1 = Half(cid, True); h2 = Half(cid, False); h2.peer = h1
            sel.register(c, selectors.EVENT_READ, (u, h1, cid))
            sel.register(u, selectors.EVENT_READ, (c, h2, cid))
            continue
        src = key.fileobj; dst, half, cid = key.data
        try: data = src.recv(65536)
        except OSError: data = b""
        if not data:
            log.write("%.3f c%d CLOSE\n" % (time.time(), cid))
            for s in (src, dst):
                try: sel.unregister(s)
                except Exception: pass
                s.close()
            continue
        dst.sendall(data)
        try: half.feed(data)
        except Exception as e: log.write("parse error %r\n" % e); half.feed = lambda d: None
