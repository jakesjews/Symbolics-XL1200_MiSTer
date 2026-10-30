#!/bin/sh
# Build the reference VLM (jjachemich/linux-vlm + our patches) on x86-64 Ubuntu without root.
# Result: ./linux-vlm/src/genera
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
SR="$HERE/sysroot"

# 1. X11 development headers without sudo: unpack the -dev packages into ./sysroot.
#    (The runtime libraries libX11/libxcb/... are already installed system-wide.)
if [ ! -f "$SR/usr/include/X11/Xlib-xcb.h" ]; then
    mkdir -p debs "$SR"
    (cd debs && apt-get download libx11-dev libx11-xcb-dev x11proto-dev libxcb1-dev libxau-dev libxdmcp-dev)
    for d in debs/*.deb; do dpkg -x "$d" "$SR"; done
    # Point the unversioned .so symlinks at the system's runtime libraries.
    for l in "$SR"/usr/lib/x86_64-linux-gnu/*.so; do
        t=$(readlink "$l")
        case "$t" in /*) ;; *) ln -sfn "/usr/lib/x86_64-linux-gnu/$t" "$l" ;; esac
    done
fi

# 2. Sources: jjachemich/linux-vlm (Brad Parker's C translation of the Alpha emulator).
[ -d linux-vlm ] || git clone https://github.com/jjachemich/linux-vlm.git
cd linux-vlm
git checkout -q 4157f06
if git apply --check ../patches/linux-vlm-modern-linux.patch 2>/dev/null; then
    git apply ../patches/linux-vlm-modern-linux.patch
fi

# 3. Configure and build.  GCC 15 needs: gnu99 (not C23), gnu89 inline semantics,
#    -fcommon (globals defined in headers) and -fpermissive (old prototypes).
autoreconf -fi
./configure --enable-debug --disable-fast \
    CFLAGS="-g -std=gnu99 -fgnu89-inline -fcommon -fpermissive" \
    CPPFLAGS="-I$SR/usr/include" LDFLAGS="-L$SR/usr/lib/x86_64-linux-gnu"
# stub/i*.c are pre-generated from alpha-emulator/*.as; make them newer than their
# sources so make does not try to regenerate them (that needs CLISP).
touch stub/i*.c
make -j"$(nproc)"
ls -l src/genera
