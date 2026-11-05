#!/usr/bin/env python3
"""Time the core's disk traffic on the MiSTer (run there): samples the file
position of the SCSI image in MiSTer's main program (/proc/PID/fdinfo) every
5 ms and reports when the traffic began and ended and how busy it was.

usage: disklog.py [--type TEXT] [--idle S] [--max S] [--log FILE]

--type TEXT types TEXT first (kbd.py, next to this file) and times from its
last key.  The log ends once traffic has started and then stopped for
--idle seconds (default 10), or after --max seconds (default 3600).  --log
writes each change: seconds from the last key, then the position in blocks
(1536 bytes of the image).

Main reads and writes the image through stdio (16 KB reads, user_io.cpp),
so a request moves the position once or twice (stdio's aligned seek, then
the transfer): the change count is a measure of activity, not an exact
request count; Genera's meters give that (docs/NOTES.md, "Disk
throughput").  The program's /proc/PID/io doesn't count the image reads.
"""
import argparse, os, subprocess, sys, time

STRIDE = 1536          # a 1280-byte block in three 512-byte sectors


def main_pid():
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            argv0 = open("/proc/%s/cmdline" % p, "rb").read().split(b"\0")[0]
        except OSError:
            continue
        if os.path.basename(argv0).startswith(b"MiSTer"):
            return p
    sys.exit("MiSTer's main program isn't running")


def image_fd(pid):
    d = "/proc/%s/fd" % pid
    for fd in os.listdir(d):
        try:
            target = os.readlink(os.path.join(d, fd))
        except OSError:
            continue
        if target.lower().endswith((".vhd", ".img", ".hdf")) and "/games/" in target:
            return fd, target
    sys.exit("no disk image open in the main program")


def position(path):
    with open(path) as f:
        return int(f.readline().split()[1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--type")
    ap.add_argument("--idle", type=float, default=10.0)
    ap.add_argument("--max", type=float, default=3600.0)
    ap.add_argument("--log")
    a = ap.parse_args()

    pid = main_pid()
    fd, image = image_fd(pid)
    info = "/proc/%s/fdinfo/%s" % (pid, fd)
    print("main program %s, image %s" % (pid, image), flush=True)

    if a.type:
        kbd = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kbd.py")
        subprocess.check_call([sys.executable, kbd, a.type])
        t0 = time.time() - 0.5          # kbd.py waits 0.5 s after the last key
    else:
        t0 = time.time()
    print("from %.3f (Unix time)" % t0, flush=True)

    log = open(a.log, "w") if a.log else None
    last = position(info)
    changes = []                        # times of the position changes
    while True:
        time.sleep(0.005)
        now = time.time()
        p = position(info)
        if p != last:
            changes.append(now)
            if log:
                log.write("%.3f %d\n" % (now - t0, p // STRIDE))
            last = p
        if changes and now - changes[-1] > a.idle:
            break
        if now - t0 > a.max:
            break

    if not changes:
        print("no disk traffic")
        return
    first, end = changes[0] - t0, changes[-1] - t0
    print("traffic from %.2f s to %.2f s: %d position changes, %.0f a second"
          % (first, end, len(changes), len(changes) / max(end - first, 1e-3)))
    per = {}
    for t in changes:
        per[int(t - t0)] = per.get(int(t - t0), 0) + 1
    print("changes in each second: " + " ".join("%d:%d" % (s, per[s]) for s in sorted(per)))


if __name__ == "__main__":
    main()
