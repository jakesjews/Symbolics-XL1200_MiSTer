#!/usr/bin/env python3
"""Minimal user-space NFS v2 + MOUNT v1 + portmapper v2 server (UDP only).

Written so Genera on the VLM can reach host files as DIS-EMB-HOST:/path without a
kernel NFS server or root.  It runs inside the VLM's private network namespace and
binds the Linux end of the tap link (10.0.0.1 by default).

Only paths under ROOT are readable/writable.  The directories above ROOT (/, /home, ...)
are visible only along the way down to ROOT so that Genera can walk the full path.

usage: nfs2d.py [--bind 10.0.0.1] [--root DIR] [--log FILE]
"""
import argparse, errno, os, select, socket, stat, struct, sys, time

PMAP_PROG, MOUNT_PROG, NFS_PROG = 100000, 100005, 100003
NFS_PORT, MOUNT_PORT, PMAP_PORT = 2049, 635, 111

NFS_OK, NFSERR_PERM, NFSERR_NOENT, NFSERR_IO, NFSERR_ACCES = 0, 1, 2, 5, 13
NFSERR_EXIST, NFSERR_NOTDIR, NFSERR_ISDIR, NFSERR_NOSPC = 17, 20, 21, 28
NFSERR_ROFS, NFSERR_NAMETOOLONG, NFSERR_NOTEMPTY, NFSERR_STALE = 30, 63, 66, 70
ERRNO_MAP = {errno.EPERM: NFSERR_PERM, errno.ENOENT: NFSERR_NOENT, errno.EIO: NFSERR_IO,
             errno.EACCES: NFSERR_ACCES, errno.EEXIST: NFSERR_EXIST, errno.ENOTDIR: NFSERR_NOTDIR,
             errno.EISDIR: NFSERR_ISDIR, errno.ENOSPC: NFSERR_NOSPC, errno.EROFS: NFSERR_ROFS,
             errno.ENAMETOOLONG: NFSERR_NAMETOOLONG, errno.ENOTEMPTY: NFSERR_NOTEMPTY,
             errno.ESTALE: NFSERR_STALE}
NFNON, NFREG, NFDIR, NFBLK, NFCHR, NFLNK = 0, 1, 2, 3, 4, 5
NOVAL = 0xFFFFFFFF


class NfsError(Exception):
    def __init__(self, code):
        self.code = code


class Unpacker:
    def __init__(self, data):
        self.d, self.p = data, 0
    def u32(self):
        v = struct.unpack_from(">I", self.d, self.p)[0]; self.p += 4; return v
    def opaque_fixed(self, n):
        v = self.d[self.p:self.p + n]; self.p += (n + 3) & ~3; return v
    def opaque(self):
        return self.opaque_fixed(self.u32())
    def string(self):
        return self.opaque().decode("latin-1")


class Packer:
    def __init__(self):
        self.parts = []
    def u32(self, v):
        self.parts.append(struct.pack(">I", v & 0xFFFFFFFF)); return self
    def opaque_fixed(self, b):
        self.parts.append(b + b"\0" * ((4 - len(b) % 4) % 4)); return self
    def opaque(self, b):
        self.u32(len(b)); return self.opaque_fixed(b)
    def string(self, s):
        return self.opaque(s.encode("latin-1"))
    def bytes(self):
        return b"".join(self.parts)


class Server:
    def __init__(self, root, log):
        self.root = os.path.realpath(root)
        self.log = log
        self.handles = {}          # handle bytes -> path
        self.root_chain = []       # "/", "/home", ... ROOT
        p = self.root
        while True:
            self.root_chain.insert(0, p)
            if p == "/":
                break
            p = os.path.dirname(p)

    # ---- path policy -------------------------------------------------------
    def inside(self, path):
        return path == self.root or path.startswith(self.root + "/")

    def visible(self, path):
        return self.inside(path) or path in self.root_chain

    def check_write(self, path):
        if not self.inside(path):
            raise NfsError(NFSERR_ACCES)

    # ---- file handles ------------------------------------------------------
    def fh_for(self, path):
        st = os.lstat(path)
        fh = struct.pack(">QQ", st.st_dev, st.st_ino) + b"VLMNFS2\0" + b"\0" * 8
        self.handles[fh] = path
        return fh

    def find_inode(self, dev, ino):
        """Recover a path for a handle issued before a server restart (handles are just dev/ino)."""
        for p in self.root_chain:
            st = os.lstat(p)
            if (st.st_dev, st.st_ino) == (dev, ino):
                return p
        for d, dirs, files in os.walk(self.root):
            for n in dirs + files:
                p = os.path.join(d, n)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if (st.st_dev, st.st_ino) == (dev, ino):
                    return p
        return None

    def path_for(self, fh):
        path = self.handles.get(bytes(fh))
        if path is None and bytes(fh[16:24]) == b"VLMNFS2\0":
            dev, ino = struct.unpack(">QQ", bytes(fh[:16]))
            path = self.find_inode(dev, ino)
            if path is not None:
                self.handles[bytes(fh)] = path
                self.log("recovered handle for %s" % path)
        if path is None:
            raise NfsError(NFSERR_STALE)
        try:
            st = os.lstat(path)
        except OSError:
            raise NfsError(NFSERR_STALE)
        if struct.pack(">QQ", st.st_dev, st.st_ino) != bytes(fh[:16]):
            raise NfsError(NFSERR_STALE)
        return path

    def child(self, dirpath, name):
        if name in ("", ".") :
            return dirpath
        if name == "..":
            return os.path.dirname(dirpath) if dirpath != "/" else "/"
        if "/" in name or "\0" in name:
            raise NfsError(NFSERR_ACCES)
        path = os.path.join(dirpath, name)
        if not self.visible(path):
            raise NfsError(NFSERR_NOENT)
        if os.path.lexists(path) and not self.visible(os.path.realpath(path)):
            raise NfsError(NFSERR_ACCES)          # symlink pointing outside ROOT
        return path

    # ---- attributes --------------------------------------------------------
    def fattr(self, p, path):
        st = os.lstat(path)
        m = st.st_mode
        ftype = NFDIR if stat.S_ISDIR(m) else NFLNK if stat.S_ISLNK(m) else NFREG if stat.S_ISREG(m) \
            else NFCHR if stat.S_ISCHR(m) else NFBLK if stat.S_ISBLK(m) else NFNON
        if not self.inside(path):
            m = (m & ~0o222)                      # ancestors look read-only
        def t(x):
            return (int(x), int((x - int(x)) * 1e6))
        p.u32(ftype).u32(m).u32(st.st_nlink).u32(st.st_uid).u32(st.st_gid)
        p.u32(min(st.st_size, 0xFFFFFFFF)).u32(4096).u32(st.st_rdev & 0xFFFFFFFF)
        p.u32((st.st_size + 4095) // 4096).u32(st.st_dev & 0xFFFFFFFF).u32(st.st_ino & 0xFFFFFFFF)
        for x in (st.st_atime, st.st_mtime, st.st_ctime):
            s, us = t(x); p.u32(s).u32(us)

    def apply_sattr(self, path, u):
        mode, uid, gid, size = u.u32(), u.u32(), u.u32(), u.u32()
        asec, ausec, msec, musec = u.u32(), u.u32(), u.u32(), u.u32()
        if mode != NOVAL:
            os.chmod(path, mode & 0o7777)
        if size != NOVAL:
            os.truncate(path, size)
        if asec != NOVAL or msec != NOVAL:
            st = os.stat(path)
            a = st.st_atime if asec == NOVAL else asec + ausec / 1e6
            m = st.st_mtime if msec == NOVAL else msec + musec / 1e6
            os.utime(path, (a, m))
        # uid/gid changes are ignored (we are not root on the host)

    # ---- dispatch ----------------------------------------------------------
    def handle(self, data):
        u = Unpacker(data)
        xid, mtype = u.u32(), u.u32()
        if mtype != 0:
            return None
        rpcvers, prog, vers, proc = u.u32(), u.u32(), u.u32(), u.u32()
        u.u32(); u.opaque()          # credentials (ignored)
        u.u32(); u.opaque()          # verifier
        r = Packer().u32(xid).u32(1).u32(0).u32(0).u32(0)    # REPLY, MSG_ACCEPTED, AUTH_NULL verf
        if rpcvers != 2:
            return Packer().u32(xid).u32(1).u32(1).u32(0).u32(2).u32(2).bytes()  # RPC_MISMATCH
        table = {(PMAP_PROG, 2): self.pmap, (MOUNT_PROG, 1): self.mount, (MOUNT_PROG, 2): self.mount,
                 (NFS_PROG, 2): self.nfs}
        fn = table.get((prog, vers))
        if fn is None:
            if prog in (PMAP_PROG, MOUNT_PROG, NFS_PROG):
                lo, hi = {PMAP_PROG: (2, 2), MOUNT_PROG: (1, 2), NFS_PROG: (2, 2)}[prog]
                return r.u32(2).u32(lo).u32(hi).bytes()           # PROG_MISMATCH
            return r.u32(1).bytes()                               # PROG_UNAVAIL
        body = Packer()
        try:
            ok = fn(proc, u, body)
        except (struct.error, IndexError):
            return r.u32(4).bytes()                               # GARBAGE_ARGS
        if ok is False:
            return r.u32(3).bytes()                               # PROC_UNAVAIL
        return r.u32(0).bytes() + body.bytes()

    def pmap(self, proc, u, p):
        if proc == 0:
            return True
        if proc == 3:                                             # GETPORT
            prog, vers, prot, _ = u.u32(), u.u32(), u.u32(), u.u32()
            port = {NFS_PROG: NFS_PORT, MOUNT_PROG: MOUNT_PORT, PMAP_PROG: PMAP_PORT}.get(prog, 0)
            if prot != 17:
                port = 0
            self.log("pmap GETPORT prog=%d vers=%d prot=%d -> %d" % (prog, vers, prot, port))
            p.u32(port)
            return True
        if proc == 4:                                             # DUMP
            for prog, vers, port in ((PMAP_PROG, 2, PMAP_PORT), (MOUNT_PROG, 1, MOUNT_PORT),
                                     (MOUNT_PROG, 2, MOUNT_PORT), (NFS_PROG, 2, NFS_PORT)):
                p.u32(1).u32(prog).u32(vers).u32(17).u32(port)
            p.u32(0)
            return True
        return False

    def mount(self, proc, u, p):
        if proc == 0:
            return True
        if proc == 1:                                             # MNT
            path = os.path.normpath("/" + u.string().lstrip("/"))
            self.log("mount MNT %s" % path)
            if not self.visible(path) or not os.path.isdir(path):
                p.u32(NFSERR_ACCES if os.path.isdir(path) else NFSERR_NOENT)
            else:
                p.u32(0).opaque_fixed(self.fh_for(path))
            return True
        if proc == 2:                                             # DUMP
            p.u32(0); return True
        if proc in (3, 4):                                        # UMNT, UMNTALL
            return True
        if proc == 5:                                             # EXPORT
            p.u32(1).string("/").u32(0).u32(0)
            return True
        return False

    def nfs(self, proc, u, p):
        names = {0: "NULL", 1: "GETATTR", 2: "SETATTR", 4: "LOOKUP", 5: "READLINK", 6: "READ", 8: "WRITE",
                 9: "CREATE", 10: "REMOVE", 11: "RENAME", 12: "LINK", 13: "SYMLINK", 14: "MKDIR",
                 15: "RMDIR", 16: "READDIR", 17: "STATFS"}
        if proc == 0:
            return True
        if proc not in names:
            return False
        mark = len(p.parts)
        try:
            self.nfs_proc(proc, u, p, names[proc])
        except NfsError as e:
            del p.parts[mark:]
            p.u32(e.code)
            self.log("  -> error %d" % e.code)
        except OSError as e:
            del p.parts[mark:]
            p.u32(ERRNO_MAP.get(e.errno, NFSERR_IO))
            self.log("  -> OSError %s" % e)
        return True

    def nfs_proc(self, proc, u, p, name):
        if proc == 1:                                             # GETATTR
            path = self.path_for(u.opaque_fixed(32))
            self.log("GETATTR %s" % path)
            p.u32(NFS_OK); self.fattr(p, path)
        elif proc == 2:                                           # SETATTR
            path = self.path_for(u.opaque_fixed(32))
            self.log("SETATTR %s" % path)
            self.check_write(path)
            self.apply_sattr(path, u)
            p.u32(NFS_OK); self.fattr(p, path)
        elif proc == 4:                                           # LOOKUP
            d = self.path_for(u.opaque_fixed(32)); name = u.string()
            self.log("LOOKUP %s %r" % (d, name))
            path = self.child(d, name)
            if not os.path.lexists(path):
                raise NfsError(NFSERR_NOENT)
            p.u32(NFS_OK).opaque_fixed(self.fh_for(path)); self.fattr(p, path)
        elif proc == 5:                                           # READLINK
            path = self.path_for(u.opaque_fixed(32))
            p.u32(NFS_OK).string(os.readlink(path))
        elif proc == 6:                                           # READ
            path = self.path_for(u.opaque_fixed(32)); off, count = u.u32(), u.u32(); u.u32()
            self.log("READ %s off=%d count=%d" % (path, off, count))
            if not self.inside(path):
                raise NfsError(NFSERR_ACCES)
            if os.path.isdir(path):
                raise NfsError(NFSERR_ISDIR)
            with open(path, "rb") as f:
                f.seek(off); data = f.read(min(count, 8192))
            p.u32(NFS_OK); self.fattr(p, path); p.opaque(data)
        elif proc == 8:                                           # WRITE
            path = self.path_for(u.opaque_fixed(32)); u.u32(); off = u.u32(); u.u32(); data = u.opaque()
            self.log("WRITE %s off=%d len=%d" % (path, off, len(data)))
            self.check_write(path)
            fd = os.open(path, os.O_WRONLY)
            try:
                os.pwrite(fd, data, off)
            finally:
                os.close(fd)
            p.u32(NFS_OK); self.fattr(p, path)
        elif proc in (9, 14):                                     # CREATE, MKDIR
            d = self.path_for(u.opaque_fixed(32)); name = u.string()
            path = self.child(d, name)
            self.log("%s %s" % ("CREATE" if proc == 9 else "MKDIR", path))
            self.check_write(path)
            sattr_pos = u.p
            mode = u.u32()
            mode = 0o644 if mode == NOVAL else mode & 0o7777
            if proc == 9:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode); os.close(fd)
            else:
                os.mkdir(path, mode)
            u.p = sattr_pos
            self.apply_sattr(path, u)
            p.u32(NFS_OK).opaque_fixed(self.fh_for(path)); self.fattr(p, path)
        elif proc in (10, 15):                                    # REMOVE, RMDIR
            d = self.path_for(u.opaque_fixed(32)); path = self.child(d, u.string())
            self.log("%s %s" % ("REMOVE" if proc == 10 else "RMDIR", path))
            self.check_write(path)
            (os.unlink if proc == 10 else os.rmdir)(path)
            p.u32(NFS_OK)
        elif proc == 11:                                          # RENAME
            d1 = self.path_for(u.opaque_fixed(32)); a = self.child(d1, u.string())
            d2 = self.path_for(u.opaque_fixed(32)); b = self.child(d2, u.string())
            self.log("RENAME %s -> %s" % (a, b))
            self.check_write(a); self.check_write(b)
            os.rename(a, b)
            p.u32(NFS_OK)
        elif proc == 12:                                          # LINK
            src = self.path_for(u.opaque_fixed(32)); d = self.path_for(u.opaque_fixed(32))
            dst = self.child(d, u.string()); self.check_write(dst)
            os.link(src, dst); p.u32(NFS_OK)
        elif proc == 13:                                          # SYMLINK
            d = self.path_for(u.opaque_fixed(32)); path = self.child(d, u.string()); target = u.string()
            self.check_write(path); os.symlink(target, path); p.u32(NFS_OK)
        elif proc == 16:                                          # READDIR
            d = self.path_for(u.opaque_fixed(32)); cookie = struct.unpack(">I", u.opaque_fixed(4))[0]
            count = u.u32()
            self.log("READDIR %s cookie=%d count=%d" % (d, cookie, count))
            if not os.path.isdir(d):
                raise NfsError(NFSERR_NOTDIR)
            if self.inside(d):
                names = [".", ".."] + sorted(os.listdir(d))
            else:
                nxt = self.root_chain[self.root_chain.index(d) + 1]
                names = [".", "..", os.path.basename(nxt)]
            p.u32(NFS_OK)
            used, i, eof = 16, cookie, True
            while i < len(names):
                nm = names[i]
                need = 16 + ((len(nm) + 3) & ~3)
                if used + need > count:
                    eof = False
                    break
                try:
                    ino = os.lstat(self.child(d, nm)).st_ino & 0xFFFFFFFF
                except (OSError, NfsError):
                    i += 1
                    continue
                p.u32(1).u32(ino).string(nm).opaque_fixed(struct.pack(">I", i + 1))
                used += need; i += 1
            p.u32(0).u32(1 if eof else 0)
        elif proc == 17:                                          # STATFS
            path = self.path_for(u.opaque_fixed(32))
            sv = os.statvfs(path)
            p.u32(NFS_OK).u32(8192).u32(4096)
            scale = sv.f_frsize / 4096.0
            for v in (sv.f_blocks, sv.f_bfree, sv.f_bavail):
                p.u32(min(int(v * scale), 0xFFFFFFFF))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="10.0.0.1")
    ap.add_argument("--root", required=True)
    ap.add_argument("--log", default=None)
    a = ap.parse_args()
    logf = open(a.log, "a", buffering=1) if a.log else None
    def log(msg):
        if logf:
            logf.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    srv = Server(a.root, log)
    socks = []
    for port in (PMAP_PORT, MOUNT_PORT, NFS_PORT):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((a.bind, port))
        socks.append(s)
    log("serving %s on %s (ports %d/%d/%d)" % (srv.root, a.bind, PMAP_PORT, MOUNT_PORT, NFS_PORT))
    while True:
        for s in select.select(socks, [], [])[0]:
            data, addr = s.recvfrom(65536)
            try:
                reply = srv.handle(data)
            except Exception as e:                       # never die on a bad packet
                log("internal error %r" % (e,))
                reply = None
            if reply is not None:
                s.sendto(reply, addr)


if __name__ == "__main__":
    main()
