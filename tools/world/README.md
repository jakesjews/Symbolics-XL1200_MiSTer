# Reference VLM

Symbolics' Virtual Lisp Machine (Open Genera 2.0) on x86-64 Linux, used as a
tool: Genera running on it compiles Lisp for the Ivory and saves worlds, and
its source-level behaviour is a reference for the core.

## What you need

- An x86-64 Linux machine (tested on Ubuntu)
- `Genera-8-5.vlod` and `VLM_debugger` from Open Genera 2.0
- gcc, autoconf, automake, git, Xvfb, xdotool, xwd, [pasta](https://passt.top/) and python3 with Pillow

## Use

1. `tools/world/build.sh` clones [linux-vlm](https://github.com/jjachemich/linux-vlm) (commit 4157f06), applies `patches/linux-vlm-modern-linux.patch` and builds it.
2. `VLM_WORLD=Genera-8-5.vlod VLM_DEBUGGER=VLM_debugger tools/world/run-genera.sh` starts it on a private X server.
3. `geval.sh "(+ 1 2)"` types a form and saves a screenshot in `shots/`; `gtype.sh TEXT` or `gtype.sh -k Return` types without one.
4. `run-genera.sh stop` stops it.

## Gotchas

- **The VLM shifts its calendar clock back 28 years**, because the stock world rejects dates after 1999.
- Genera reaches Linux files as `DIS-EMB-HOST:/absolute/path`, only under `VLM_NFS_ROOT` (default `work/` here); log in (`Login Lisp-Machine`) first.
- The VLM ignores SIGTERM, so `run-genera.sh stop` kills it; nothing is saved.

## Troubleshooting

- "VLM exited during boot": read `run/vlm.log`.
- Screenshots hang: an X client holds a server grab; restart with `VLM_XPROXY=1` and read `run/xproxy.log`.
- "no usable version of NFS": read `run/nfs2d.log` and run `tools/nfs-restart.sh`.
