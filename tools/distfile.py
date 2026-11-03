#!/usr/bin/env python3
"""Genera distribution files ("dummy tape" files for Restore Distribution :Use Disk).

usage: distfile.py ls DIST...
       distfile.py get DIST NAME OUT          (a file's bytes, uncompressed: 8-bit stream)
       distfile.py make OUT TITLE SPEC...     (write a distribution)

A distribution is an embedded-length stream, version 1
(sys.sct/distribution/embedded-length-stream.lisp): the line
"EMBEDDED-LENGTH-STREAM VERSION 1", "END", then tape files, each "FILE name",
data blocks "BLOK" + 12-digit length + bytes, and "EOF "; "EOV " ends the
volume.  Lines end in the Lisp Machine Return, 0x8D.  The first tape file is
"Files on this tape", a Lisp form naming the files and systems; each file
then takes two tape files (tape-interface.lisp): "ATTRIBUTES-File PATH", a
printed FILE-ATTRIBUTE-INFO-V-1 structure (overhead, writer and file-system
property lists; :ELEMENT-TYPE says how to write it back), and "File PATH",
the contents: characters in the Lisp Machine character set, 16-bit bytes low
byte first.  Several distribution files concatenated (ill.dist.*) are one.

A SPEC for make is DIR=LOGICAL-DIRECTORY[=SYSTEM]: every file under DIR goes to
that logical directory, subdirectories becoming subdirectories
("sys:contributed;macsyma-421;"), with SYSTEM as its parent system (default:
the first NAME.SYSTEM-DIR found there, each of which is listed as a system
with that directory as its journal directory).
Local names may carry a version as NAME.TYPE.~N~ (a Unix host's) or NAME.TYPE;N;
without one it is 1, and a name without a type gets TEXT.  Text files are taken
in a Unix host's translation (Return is LF) and stored in the Lisp Machine set;
.ibin/.vbin and the other binary types as 16-bit bytes, low byte first.
"""
import os, re, sys, time

RETURN = 0x8D
TEXT_TYPES = {"lisp", "text", "system", "translations", "sab", "sar", "mss", "tex", "sty", "bib",
              "bst", "doc", "pl", "web", "ch", "c", "h", "f", "pas", "mac", "dem", "usg", "help",
              "component-dir", "patch-dir", "system-dir", "html", "htm", "txt", "lsp", "cl", "el",
              "readme", "notes", "make", "defsystem", "lispm", "data", "dict", "translations-text",
              "spd", "bdf", "pcf", "fasl-map", "ps", "css", "xml", "dtd", "ent", "gif-map", "tbl", "pool"}
BINARY16 = {"ibin", "bin", "vbin", "bfd", "dump", "image", "fep", "flod", "load", "ilod", "vlod",
            "font", "kst", "ast", "widths", "lgp2-metrics"}
# 8-bit as Genera writes them (the TeX tape's .tfm, .fmt and .gf files)
BINARY8 = {"tfm", "gf", "pk", "dvi", "fmt", "gif", "jpg", "jpeg", "au", "mpg", "class", "wrl-gz"}


def read_stream(data):
    """Yield (tape-file name, bytes) for each tape file."""
    i = 0
    end = data.index(RETURN, i)
    if b"EMBEDDED-LENGTH-STREAM" not in data[:end] or b"VERSION 1" not in data[:end]:
        raise ValueError("not a version 1 embedded-length stream")
    i = end + 1
    end = data.index(RETURN, i)
    if data[i:end] != b"END":
        raise ValueError("no END after the sentinel")
    i = end + 1
    name, chunks = "", []
    while i < len(data):
        key = data[i:i + 4]
        i += 4
        if key == b"FILE":
            end = data.index(RETURN, i)
            name = data[i:end].decode("latin-1").strip()
            i = end + 1
        elif key == b"BLOK":
            n = int(data[i:i + 12])
            i += 12
            chunks.append(data[i:i + n])
            i += n
        elif key == b"EOF ":
            yield name, b"".join(chunks)
            name, chunks = "", []
        elif key == b"EOV ":
            # concatenated volumes: a new sentinel may follow
            if data[i:i + 22] == b"EMBEDDED-LENGTH-STREAM":
                i = data.index(RETURN, data.index(RETURN, i) + 1) + 1
                continue
            return
        else:
            raise ValueError(f"tape out of sync at {i - 4}: {key!r}")


def entries(data):
    """Yield (path, attributes text, contents) for each file on the tape."""
    pending = None
    for name, body in read_stream(data):
        if name.startswith("ATTRIBUTES-"):
            pending = (name[len("ATTRIBUTES-"):], body.decode("latin-1"))
        elif pending and name == pending[0]:
            yield name[len("File "):], pending[1], body
            pending = None
        else:
            yield name, None, body


def cmd_ls(paths):
    for p in paths:
        data = open(p, "rb").read()
        for name, attrs, body in entries(data):
            et = re.search(r":ELEMENT-TYPE (\([^)]*\)|\S+)", attrs or "")
            print(f"{len(body):9d}  {et.group(1) if et else '-':22s}  {name}")


def uncompress(body):
    """A file written with :COMPRESSION :SYMBOLICS: a Symbolics preamble
    (sys.sct/compression/preambles.lisp: five parity bytes, the version, a
    length, then the code sizes and flags) before Unix compress's LZW data, so
    gzip unpacks it once the preamble is swapped for compress's three bytes."""
    import subprocess
    if body[:5] != bytes([0x55, 0xAA, 0x54, 0xA8, 0x8D]):
        return body
    data, maxbits = body[7 + body[7]:], body[9]
    r = subprocess.run(["gzip", "-dc"], input=bytes([0x1F, 0x9D, 0x80 | maxbits]) + data, capture_output=True)
    return r.stdout


def cmd_get(path, want, out):
    for name, attrs, body in entries(open(path, "rb").read()):
        if name.upper() == want.upper():
            open(out, "wb").write(uncompress(body) if ":COMPRESSION" in (attrs or "") else body)
            print(attrs)
            return
    sys.exit(f"{want} not on {path}")


# Unix host translation (sys.sct/nfs/nfs-common.lisp, UNIX-TRANSLATION-TABLE):
# the Lisp Machine's Backspace, Tab, Page and Rubout are the ASCII codes there,
# Return is LF and Line is CR, and the Lisp Machine characters with those
# codes travel the other way.  A swap, so it reverses.
UNIX_SWAP = {8: 0x88, 9: 0x89, 10: 0x8D, 12: 0x8C, 13: 0x8A, 127: 0x87}
UNIX_SWAP.update({v: k for k, v in list(UNIX_SWAP.items())})
UNIX_TABLE = bytes(UNIX_SWAP.get(c, c) for c in range(256))


def unix_to_lispm(b):
    return bytes(b).translate(UNIX_TABLE)


def split_version(fn):
    m = re.match(r"(.*?)(?:;(\d+)|\.~(\d+)~)$", fn)
    if m:
        return m.group(1), int(m.group(2) or m.group(3))
    return fn, 1


def logical_name(rel, logdir):
    """'code/foo.lisp.~3~' under 'sys:contributed;x;' -> SYS:CONTRIBUTED;X;CODE;FOO.LISP.3"""
    parts = rel.split("/")
    base, version = split_version(parts[-1])
    host, _, dirs = logdir.partition(":")
    dirs = [d for d in dirs.strip().rstrip(";").split(";") if d] + parts[:-1]
    name, dot, typ = base.rpartition(".")
    if not dot or not name:
        name, typ = base, "text"          # README: a type, so the version isn't read as one
    # extra dots would read as type and version: they become '-'
    clean = lambda s: s.replace(".", "-").upper()
    path = f"{host.upper()}:" + "".join(clean(d) + ";" for d in dirs) + clean(name) + "." + clean(typ)
    return path + f".{version}", typ.lower()


def element_type(typ, body):
    if typ in BINARY16:
        return "(LISP:UNSIGNED-BYTE 16)"
    if typ in BINARY8 or typ.endswith("gf"):
        return "(LISP:UNSIGNED-BYTE 8)"
    if typ in TEXT_TYPES:
        return "CHARACTER"
    # unknown types: text if it looks like text
    sample = body[:4096]
    return "CHARACTER" if all(c >= 32 or c in (8, 9, 10, 12, 13) for c in sample) else "(LISP:UNSIGNED-BYTE 8)"


def universal_time(t):
    return int(t) + 2208988800


def tape_file(out, name, body):
    out += b"FILE " + name.encode("latin-1") + bytes([RETURN])
    for k in range(0, len(body), 4096):
        chunk = body[k:k + 4096]
        out += b"BLOK%012d" % len(chunk) + chunk
    out += b"EOF "


def cmd_make(out_path, title, specs):
    files, systems = [], []
    for spec in specs:
        local, logdir, system = (spec.split("=") + [""])[:3]
        found = []
        for root, _, names in os.walk(local):
            for fn in sorted(names):
                full = os.path.join(root, fn)
                path, typ = logical_name(os.path.relpath(full, local), logdir)
                files.append([path, typ, full, system])
                if typ == "system-dir":
                    # a system's journal directory: NAME.SYSTEM-DIR lives in it
                    name = path.rsplit(";", 1)[1].split(".")[0]
                    found.append((name, path.rsplit(";", 1)[0] + ";", name))
        systems += [s for s in found if s not in systems]
        default = found[0][0] if found else logdir.rstrip(";").split(";")[-1].split(":")[-1]
        for f in files:
            # the system whose journal directory holds the file or is nearest above it
            if not f[3]:
                owners = [s for s in found if f[0].startswith(s[1].rsplit("PATCH;", 1)[0])]
                f[3] = max(owners, key=lambda s: len(s[1]))[0] if owners else default
    files.sort()
    out = bytearray(b"EMBEDDED-LENGTH-STREAM VERSION 1" + bytes([RETURN]) + b"END" + bytes([RETURN]))
    # the directory, as make-directory-string-for-tape writes it
    listing = (";;;  -*- Mode: LISP; Base: 10; Syntax: Zetalisp -*-\n;;; Written %s by XL1200 (tools/distfile.py)\n(\n"
               " ;;; Files on this tape:\n \n (" % time.strftime("%m/%d/%y %H:%M:%S"))
    listing += "\n  ".join('"%s"' % f[0] for f in files) + ")\n \n"
    listing += " ;;; Systems and their journal-directories on this tape:\n \n ("
    listing += "".join('(%s "%s" "%s")' % s for s in systems) + ")\n \n"
    listing += " ;;; Files on this tape, with parent system for each:\n \n ("
    listing += "\n  ".join('("%s" :%s)' % (f[0], f[3].upper()) for f in files) + "))"
    tape_file(out, "Files on this tape", listing.replace("\n", "\x8d").encode("latin-1"))
    files = [tuple(f[:3]) for f in files]
    seen = set()
    for path, typ, full in files:
        if path in seen:
            sys.exit(f"two files map to {path}")
        seen.add(path)
        body = open(full, "rb").read()
        et = element_type(typ, body)
        if et == "CHARACTER":
            body = unix_to_lispm(body)
        elif et == "(LISP:UNSIGNED-BYTE 16)" and len(body) % 2:
            sys.exit(f"{full}: odd length for a 16-bit file")
        st = os.stat(full)
        length = len(body) if et != "(LISP:UNSIGNED-BYTE 16)" else len(body) // 2
        attrs = ('#S(DIS:FILE-ATTRIBUTE-INFO-V-1 :OVERHEAD-ATTRIBUTES (:USER-ID "XL1200" :DUMP-TIME %d) '
                 ':FILE-WRITER-ATTRIBUTES (:REEL-TITLE "%s" :ORIGINAL-PATHNAME #P"%s") '
                 ':FILE-SYSTEM-ATTRIBUTES (:ELEMENT-TYPE %s :CREATION-DATE %d :AUTHOR "XL1200" :LENGTH-IN-BYTES %d))'
                 % (universal_time(time.time()), title, path, et, universal_time(st.st_mtime), length))
        tape_file(out, "ATTRIBUTES-File " + path, attrs.encode("latin-1"))
        tape_file(out, "File " + path, body)
    out += b"EOV "
    open(out_path, "wb").write(out)
    print(f"{out_path}: {len(files)} files, {len(out)} bytes")


def main():
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "ls":
        cmd_ls(a[1:])
    elif len(a) == 4 and a[0] == "get":
        cmd_get(*a[1:])
    elif len(a) >= 4 and a[0] == "make":
        cmd_make(a[1], a[2], a[3:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
