"""Read and write Symbolics FEP file system (FEPFS) disk images.

A FEPFS disk is a sequence of 1280-byte blocks numbered by DPN. The file
system's own blocks (label, directory pages, file headers, free map) hold 320
little-endian 32-bit words; the data blocks of world files hold 256 tagged
Ivory words (see fepfile.py). The images are SCSI2SD SD-card dumps, block n at
byte n*STRIDE (1536: three 512-byte sectors, the last 256 bytes padding).
Layout and sources: docs/NOTES.md, "FEP file system layout".

    python3 tools/fepfs.py ls IMAGE
        label, directories, files with sizes and blocks, free space
    python3 tools/fepfs.py get IMAGE PATH OUT
        copy a file's contents out (PATH like >I333.Boot or >dir>name.type.3)
    python3 tools/fepfs.py mkworld TEMPLATE WORLD OUT [--name Genera-8-3.ilod]
        copy TEMPLATE to OUT, grow it to the size its label gives, and add the
        Ivory world load file WORLD (GENERA_8_3.ILOD from the Genera 8.3 CD)
        and a paging file (>Page.page, the rest of the disk) to the root
        directory; --text FILE (repeatable) adds a text file before the
        paging file, e.g. a Lisp source to compile in Genera; --blocks N
        first makes the disk N blocks (the label and free map grown);
        --paging N makes the paging file N blocks (leave room for a saved
        world); --standalone adds Symbolics' standalone site, so Genera
        boots configured (docs/NOTES.md, "Compatibility")
"""
import argparse, io, os, shutil, struct, sys, time

BLOCK = 1280                  # bytes in a block
WORDS = BLOCK // 4            # %page-size32 on the Ivory (storage/disk-definitions.lisp)
UT_EPOCH = 2208988800         # universal time (seconds since 1900) minus Unix time
DPN_MASK = 0x7FFFFFF          # page number; bits 31:27 of an in-memory DPN are the unit
WORLD_COOKIE = b'HIJc'        # tag bytes of an Ivory world file's first word (VLM world_tools.h)

# Word offsets, from DEFFEPBLOCK in l-sys/fep-stream.lisp (a Base 8 file).
# Every block starts with FEPH: id, header version, npages, timestamp, sequence number.
ID, HVERSION, NPAGES, TIMESTAMP, SEQUENCE = range(5)
# LABL: the disk label, blocks 0, 1 and 2
L_NCYL, L_NHEADS, L_NPPT, L_CDATE = 5, 6, 7, 8
L_AUTHOR, L_PACK, L_COMMENT = (9, 16), (16, 24), (24, 48)
L_ROOT, L_PACK_ID, L_FAST, L_DISK_TYPE, L_DIAG, L_FEP, L_BACKUP_FEP, L_COLOR = range(48, 56)
# FEPF: a file header; its data map (FEPP entries) starts at word 51
F_OWNER, F_VERSION, F_TYPE, F_CDATE = 5, 6, 7, 8
F_AUTHOR, F_NAME, F_COMMENT = (9, 16), (16, 24), (24, 48)
F_LENGTH, F_FLAGS, F_NENTRIES, F_MAP = 48, 49, 50, 51
MAP_MAX = (WORDS - F_MAP) // 2            # 134 two-word entries a block
INDIRECT = 1 << 24                        # entry: npages<23:0>, indirect<24>, suspect<25>; then DPN
DIRECTORY, READ_ONLY, FIXED, DELETED = 1, 2, 4, 8
# FEPD: a directory page; entries are name (8 words), type, version, header DPN
D_PAGE, D_NENTRIES, D_ENTRY, D_ESIZE = 5, 13, 14, 11
D_MAX = (WORDS - D_ENTRY) // D_ESIZE      # 27 entries a page


def get_string(ws, span):
    a, b = span
    return b''.join(struct.pack('<I', w) for w in ws[a:b]).rstrip(b'\0').decode('latin-1')


def set_string(ws, span, s):
    a, b = span
    raw = s.encode('latin-1')
    if len(raw) > 4 * (b - a):
        sys.exit(f"{s!r} is longer than {4 * (b - a)} characters")
    ws[a:b] = struct.unpack(f'<{b - a}I', raw.ljust(4 * (b - a), b'\0'))


def ut_string(ut):
    return time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(ut - UT_EPOCH)) if ut else '-'


class Disk:
    """Blocks of an image file, block n at byte n*stride."""

    def __init__(self, path, stride=1536, write=False):
        self.path, self.stride = path, stride
        self.f = open(path, 'r+b' if write else 'rb')
        self.size_changed()

    def size_changed(self):
        size = os.path.getsize(self.path)
        self.nblocks = (size - BLOCK) // self.stride + 1 if size >= BLOCK else 0

    def raw(self, dpn):
        if not 0 <= dpn < self.nblocks:
            sys.exit(f"block {dpn} is beyond the image ({self.nblocks} blocks)")
        self.f.seek(dpn * self.stride)
        return self.f.read(BLOCK)

    def put_raw(self, dpn, data):
        self.f.seek(dpn * self.stride)
        self.f.write(data.ljust(BLOCK, b'\0') + b'D' * (self.stride - BLOCK))

    def read(self, dpn):
        return list(struct.unpack(f'<{WORDS}I', self.raw(dpn)))

    def write(self, dpn, ws):
        self.put_raw(dpn, struct.pack(f'<{WORDS}I', *ws))


class Entry:
    """A directory entry and the file header it names."""

    def __init__(self, fs, page, index, ws, directory):
        self.page, self.index, self.directory = page, index, directory
        self.name = get_string(ws, (index, index + 8))
        self.type = get_string(ws, (index + 8, index + 9))
        self.version = ws[index + 9]
        self.dpn = ws[index + 10] & DPN_MASK
        self.header = fs.header(self.dpn)

    @property
    def path(self):
        return f"{self.directory}{self.name}.{self.type}.{self.version}"


class FEPFS:
    def __init__(self, disk):
        self.disk = disk
        self.label = disk.read(0)
        if get_string(self.label, (ID, ID + 1)) != 'LABL':
            sys.exit(f"{disk.path}: block 0 is not a FEPFS label")
        L = self.label
        self.capacity = L[L_NCYL] * L[L_NHEADS] * L[L_NPPT]

    def header(self, dpn):
        ws = self.disk.read(dpn)
        if get_string(ws, (ID, ID + 1)) != 'FEPF':
            sys.exit(f"block {dpn} is not a file header")
        return ws

    def data_map(self, hdr, tables=None):
        """[(npages, dpn)] of a header or page table, following FEPP blocks."""
        runs = []
        for k in range(hdr[F_NENTRIES]):
            e, dpn = hdr[F_MAP + 2 * k], hdr[F_MAP + 2 * k + 1] & DPN_MASK
            if e & INDIRECT:
                if tables is not None:
                    tables.append(dpn)
                runs += self.data_map(self.disk.read(dpn), tables)
            else:
                runs.append((e & 0xFFFFFF, dpn))
        return runs

    def blocks(self, hdr):
        return [d for n, d in self.data_map(hdr) for d in range(d, d + n)]

    def entries(self, dir_dpn, directory='>'):
        """Entries of the directory whose header is at dir_dpn."""
        out = []
        for page in self.blocks(self.header(dir_dpn)):
            ws = self.disk.read(page)
            if get_string(ws, (ID, ID + 1)) != 'FEPD':
                sys.exit(f"block {page} is not a directory page")
            out += [Entry(self, page, D_ENTRY + D_ESIZE * k, ws, directory)
                    for k in range(ws[D_NENTRIES])]
        return out

    def walk(self, dir_dpn=None, directory='>'):
        """Every entry, depth first (the root lists itself as ROOT-DIRECTORY.DIR)."""
        dir_dpn = self.label[L_ROOT] if dir_dpn is None else dir_dpn
        for e in self.entries(dir_dpn, directory):
            yield e
            if e.header[F_FLAGS] & DIRECTORY and e.dpn != self.label[L_ROOT]:
                yield from self.walk(e.dpn, f"{directory}{e.name}>")

    def lookup(self, path):
        """Entry for >dir>name.type[.version]; the newest version if none is given."""
        parts = path.lstrip('>').split('>')
        dpn, directory = self.label[L_ROOT], '>'
        for d in parts[:-1]:
            dpn = self.lookup_in(dpn, d, 'DIR', None).dpn
            directory += d + '>'
        bits = parts[-1].split('.')
        version = None
        if len(bits) > 2 and bits[-1].isdigit():
            version = int(bits.pop())
        if len(bits) < 2:
            sys.exit(f"{path}: want name.type")
        return self.lookup_in(dpn, '.'.join(bits[:-1]), bits[-1], version, directory)

    def lookup_in(self, dir_dpn, name, typ, version, directory='>'):
        hits = [e for e in self.entries(dir_dpn, directory) if e.name.lower() == name.lower()
                and e.type.lower() == typ.lower() and version in (None, e.version)]
        if not hits:
            sys.exit(f"no file {name}.{typ}{'' if version is None else f'.{version}'}")
        return max(hits, key=lambda e: e.version)

    def system_file(self, name):
        return self.lookup_in(self.label[L_ROOT], name, 'FEP', None)

    # Free map: FREE-PAGES.FEP, one bit a block (1 = in use), 32 a word, 10240 a block.
    def load_free_map(self):
        self.map_blocks = self.blocks(self.system_file('FREE-PAGES').header)
        self.map_words = [self.disk.read(d) for d in self.map_blocks]
        self.map_dirty = set()

    def in_use(self, dpn):
        b, i = divmod(dpn, 32 * WORDS)
        return self.map_words[b][i // 32] >> (i % 32) & 1

    def set_in_use(self, dpn):
        b, i = divmod(dpn, 32 * WORDS)
        self.map_words[b][i // 32] |= 1 << (i % 32)
        self.map_dirty.add(b)

    def free_runs(self):
        runs, start = [], None
        for d in range(self.capacity + 1):
            free = d < self.capacity and not self.in_use(d)
            if free and start is None:
                start = d
            elif not free and start is not None:
                runs.append((d - start, start))
                start = None
        return runs

    def allocate(self, n):
        """First fit from DPN 0, as :ALLOCATE-FREE-BLOCKS does; returns [(npages, dpn)]."""
        runs, d, limit = [], 0, min(self.capacity, self.disk.nblocks)
        while n:
            while d < limit and self.in_use(d):
                d += 1
            if d >= limit:
                sys.exit(f"no room: {n} more blocks wanted, the image ends at {limit}")
            self.set_in_use(d)
            if runs and runs[-1][1] + runs[-1][0] == d:
                runs[-1] = (runs[-1][0] + 1, runs[-1][1])
            else:
                runs.append((1, d))
            n -= 1
        return runs

    def write_free_map(self):
        for b in sorted(self.map_dirty):
            self.disk.write(self.map_blocks[b], self.map_words[b])

    def resize(self, capacity):
        """Make the disk CAPACITY blocks: the label's cylinder count, the image's
        size, and a bigger free map (FREE-PAGES.FEP, one bit a block), written
        afresh in one run with the old one's blocks freed."""
        L = self.label
        per_cyl = L[L_NHEADS] * L[L_NPPT]
        if capacity <= self.capacity:
            sys.exit(f"the disk already has {self.capacity} blocks")
        if capacity % per_cyl:
            sys.exit(f"the capacity must be a multiple of {per_cyl} blocks (a cylinder)")
        now = int(time.time()) + UT_EPOCH
        self.load_free_map()
        old_blocks = self.map_blocks
        nmap = -(-capacity // (32 * WORDS))
        words = [list(w) for w in self.map_words] + [[0] * WORDS for _ in range(nmap - len(self.map_words))]
        for d in range(self.capacity, min(capacity, len(words) * 32 * WORDS)):   # past the old end: free now
            b, i = divmod(d, 32 * WORDS)
            words[b][i // 32] &= ~(1 << (i % 32))
        self.capacity = capacity
        L[L_NCYL] = capacity // per_cyl
        for d in range(3):                       # the label and its copies
            if get_string(self.disk.read(d), (ID, ID + 1)) == 'LABL':
                self.disk.write(d, L)
        self.disk.f.truncate(capacity * self.disk.stride)
        self.disk.size_changed()
        self.map_words, self.map_dirty = words, set()
        runs = self.allocate(nmap)
        if len(runs) != 1:
            sys.exit(f"no run of {nmap} free blocks for the free map")
        (_, dpn), = runs
        for d in old_blocks:
            b, i = divmod(d, 32 * WORDS)
            self.map_words[b][i // 32] &= ~(1 << (i % 32))
        self.map_blocks = list(range(dpn, dpn + nmap))
        for b in range(nmap):
            self.disk.write(self.map_blocks[b], self.map_words[b])
        self.map_dirty = set()
        e = self.system_file('FREE-PAGES')
        hdr = e.header
        hdr[F_NENTRIES], hdr[F_MAP], hdr[F_MAP + 1] = 1, nmap, dpn
        hdr[F_LENGTH], hdr[TIMESTAMP] = nmap * BLOCK, now
        self.disk.write(e.dpn, hdr)
        print(f"{self.disk.path}: {capacity} blocks ({L[L_NCYL]} cylinders), free map {nmap} blocks at {dpn}")

    def next_sequence_number(self):
        """The sequence-number file's word 0 is the highest number handed out."""
        dpn = self.blocks(self.system_file('SEQUENCE-NUMBER').header)[0]
        ws = self.disk.read(dpn)
        ws[0] += 1
        self.disk.write(dpn, ws)
        return ws[0]

    def directory_page_with_room(self, dir_dpn, now):
        """A page of the directory with a free entry, adding a page if they are full."""
        hdr = self.header(dir_dpn)
        pages = self.blocks(hdr)
        for page in pages:
            ws = self.disk.read(page)
            if ws[D_NENTRIES] < D_MAX:
                return page, ws
        n = hdr[F_NENTRIES]
        if n >= MAP_MAX or any(hdr[F_MAP + 2 * k] & INDIRECT for k in range(n)):
            sys.exit("directory full")
        (_, page), = self.allocate(1)
        ws = [0] * WORDS
        set_string(ws, (ID, ID + 1), 'FEPD')
        ws[HVERSION], ws[NPAGES], ws[SEQUENCE] = 1, 1, hdr[SEQUENCE]
        ws[D_PAGE] = len(pages)
        self.disk.write(page, ws)                # valid (empty) before the directory names it
        hdr[F_MAP + 2 * n], hdr[F_MAP + 2 * n + 1] = 1, page
        hdr[F_NENTRIES] = n + 1
        hdr[TIMESTAMP] = now
        self.disk.write(dir_dpn, hdr)
        return page, ws

    def free_blocks(self):
        """Blocks free in both the free map and the image."""
        self.load_free_map()
        return sum(not self.in_use(d) for d in range(min(self.capacity, self.disk.nblocks)))

    def add_file(self, name, typ, src, nbytes, author, comment, cdate):
        """Add a file to the root directory, its data read from the file object src
        (None: leave the blocks as they are)."""
        now = int(time.time()) + UT_EPOCH
        nblocks = -(-nbytes // BLOCK)
        root = self.label[L_ROOT]
        version = 1 + max([e.version for e in self.entries(root)
                           if e.name.lower() == name.lower() and e.type.lower() == typ.lower()],
                          default=0)
        self.load_free_map()
        page, dws = self.directory_page_with_room(root, now)
        (_, hdr_dpn), = self.allocate(1)
        runs = self.allocate(nblocks)
        if len(runs) > MAP_MAX:
            sys.exit(f"the free space is in {len(runs)} pieces; page tables (FEPP) not supported")
        for n, d in runs:
            for dpn in range(d, d + n):
                if src:
                    self.disk.put_raw(dpn, src.read(BLOCK))
        hdr = [0] * WORDS
        set_string(hdr, (ID, ID + 1), 'FEPF')
        hdr[HVERSION], hdr[NPAGES], hdr[TIMESTAMP] = 1, 1, now
        hdr[SEQUENCE] = self.next_sequence_number()
        hdr[F_OWNER], hdr[F_VERSION], hdr[F_CDATE] = dws[SEQUENCE], version, cdate
        set_string(hdr, (F_TYPE, F_TYPE + 1), typ)
        set_string(hdr, F_AUTHOR, author)
        set_string(hdr, F_NAME, name)
        set_string(hdr, F_COMMENT, comment)
        hdr[F_LENGTH], hdr[F_NENTRIES] = nbytes, len(runs)
        for k, (n, d) in enumerate(runs):
            hdr[F_MAP + 2 * k], hdr[F_MAP + 2 * k + 1] = n, d
        self.disk.write(hdr_dpn, hdr)
        i = D_ENTRY + D_ESIZE * dws[D_NENTRIES]
        set_string(dws, (i, i + 8), name)
        set_string(dws, (i + 8, i + 9), typ)
        dws[i + 9], dws[i + 10] = version, hdr_dpn
        dws[D_NENTRIES] += 1
        dws[TIMESTAMP] = now
        self.disk.write(page, dws)
        self.write_free_map()
        return version, hdr_dpn, runs


def lispm_text(data):
    """A text file in the Lisp Machine character set: Return, Tab and Page are
    #o215, #o211 and #o214; the codes below 32 are graphics there, and the
    Genera sources on the CD keep them as they are."""
    return data.replace(b'\n', b'\x8d').replace(b'\t', b'\x89').replace(b'\x0c', b'\x8c')


def runs_string(runs):
    s = ' '.join(f"{d}+{n}" if n > 1 else f"{d}" for n, d in runs[:4]) or '-'
    return s + (f" (+{len(runs) - 4} more)" if len(runs) > 4 else '')


def cmd_ls(args):
    disk = Disk(args.image, args.stride)
    fs = FEPFS(disk)
    L = fs.label
    for copy in (1, 2):
        if disk.read(copy) != L:
            print(f"warning: label copy in block {copy} differs from block 0")
    print(f"label: pack {get_string(L, L_PACK)!r}, {get_string(L, L_COMMENT)!r}, "
          f"by {get_string(L, L_AUTHOR)} {ut_string(L[L_CDATE])}")
    print(f"  {L[L_NCYL]} cylinders x {L[L_NHEADS]} heads x {L[L_NPPT]} blocks = {fs.capacity} "
          f"blocks; the image has {disk.nblocks} (stride {disk.stride})")
    entries = list(fs.walk())
    by_dpn = {e.dpn: e.path for e in entries}
    print("  " + "; ".join(f"{what} {L[w]}" + (f" {by_dpn[L[w]]}" if L[w] in by_dpn else '')
                           for what, w in (('root directory', L_ROOT), ('FEP kernel', L_FEP),
                                           ('backup kernel', L_BACKUP_FEP),
                                           ('color startup', L_COLOR),
                                           ('diagnostic', L_DIAG))))
    print()
    claimed = set()
    for e in entries:
        h = e.header
        tables = []
        runs = fs.data_map(h, tables)
        nblk = sum(n for n, _ in runs)
        claimed.update([e.dpn] + tables + [d for n, d0 in runs for d in range(d0, d0 + n)])
        flags = ','.join(f for bit, f in ((DIRECTORY, 'dir'), (READ_ONLY, 'dont-delete'),
                                          (FIXED, 'fixed'), (DELETED, 'deleted'))
                         if h[F_FLAGS] & bit)
        print(f"{e.path:36} {nblk:6} {h[F_LENGTH]:10}  {ut_string(h[F_CDATE])}  "
              f"{get_string(h, F_AUTHOR):8} {flags:15} hdr {e.dpn} data {runs_string(runs)}"
              + (f"  [{get_string(h, F_COMMENT)}]" if get_string(h, F_COMMENT) else ''))
    fs.load_free_map()
    used = {d for d in range(fs.capacity) if fs.in_use(d)}
    free = fs.free_runs()
    print()
    print(f"free: {fs.capacity - len(used)} of {fs.capacity} blocks in {len(free)} pieces"
          + (f", largest {max(free)[0]} at {max(free)[1]}" if free else ''))
    if used != claimed:
        print(f"free map: {len(used - claimed)} blocks marked in use belong to no file, "
              f"{len(claimed - used)} blocks of files marked free")


def cmd_get(args):
    fs = FEPFS(Disk(args.image, args.stride))
    e = fs.lookup(args.path)
    left = e.header[F_LENGTH]
    with open(args.out, 'wb') as out:
        for dpn in fs.blocks(e.header):
            if left <= 0:
                break
            out.write(fs.disk.raw(dpn)[:left])
            left -= BLOCK
    print(f"{e.path}: {e.header[F_LENGTH]} bytes to {args.out}")


def cmd_mkworld(args):
    name, _, typ = args.name.rpartition('.')
    if not name or not typ:
        sys.exit("--name wants name.type")
    size = os.path.getsize(args.world)
    with open(args.world, 'rb') as f:
        if f.read(4) != WORLD_COOKIE and not args.force:
            sys.exit(f"{args.world} does not start with the Ivory world cookie (--force adds it anyway)")
    if size % BLOCK and not args.force:
        sys.exit(f"{args.world} is not a whole number of {BLOCK}-byte blocks")
    if os.path.abspath(args.out) in (os.path.abspath(args.template), os.path.abspath(args.world)):
        sys.exit("OUT must be a new file")
    shutil.copyfile(args.template, args.out)
    try:
        build_world_disk(args, name, typ, size)
    except BaseException:
        os.remove(args.out)              # no half-built images
        raise


def standalone_site_files(internet=None):
    """The files of Symbolics' standalone site for the FEP disk, written the
    way a new XL1200 was shipped (the Genera 8.3 Software Installation Guide
    for XL Family Machines, "The Symbolics Standalone Site"; the CD's
    sys.sct/standalone-site/xl1200/): a namespace with one host, XL1200, and
    one user, Lisp-Machine, named by boot options in the Hello.boot. The
    machine ships with the dummy Chaos address 52525; this one is 1200 to
    match the template's Local.boot. The site's sys.translations has to be
    on the LMFS (FEP file types are at most four characters), so it is here
    as sys-translations.text for a Copy File in Genera: docs/NOTES.md,
    "Compatibility".  With an Internet address the namespace also has the
    INTERNET network, the host's address on it and its TCP services, and the
    Hello.boot tells the FEP both addresses (docs/NOTES.md, "Network")."""
    hello = ("Hello I333\n"
             "Hello Local\n"
             + (f"Set Network Address CHAOS|1200,INTERNET|{internet}\n" if internet else "")
             + "Set Boot Options :Site Name Standalone\n"
             "Set Boot Options :Namespace Descriptor File FEP7:>standalone-namespace.text\n")
    namespace = ('VERSION "FEP7:>standalone-namespace-log.text.newest"\n'
                 '* "FEP7:>standalone-objects.text.newest"\n'
                 'CHANGES "FEP7:>standalone-namespace-changes.text.newest"\n')
    objects = """;-*- Mode: Text; Network-Namespace: STANDALONE-*-
NAMESPACE STANDALONE
PRIMARY-NAME-SERVER XL1200
SEARCH-RULES STANDALONE
DESCRIPTOR-FILE "FEP7:>standalone-namespace.text.newest"

SITE STANDALONE
PRETTY-NAME Standalone
LOCAL-NAMESPACE STANDALONE
SITE-DIRECTORY "XL1200:>sys>site>"
TIMEZONE EST
HOST-FOR-BUG-REPORTS XL1200
STANDALONE YES

NETWORK CHAOS
SITE STANDALONE
TYPE CHAOS
""" + ("""
NETWORK INTERNET
SITE STANDALONE
TYPE INTERNET
""" if internet else "") + """
HOST XL1200
SYSTEM-TYPE LISPM
SERVICE CHAOS-STATUS CHAOS-SIMPLE CHAOS-STATUS
SERVICE SHOW-USERS CHAOS NAME
SERVICE TIME CHAOS-SIMPLE TIME-SIMPLE
SERVICE UPTIME CHAOS-SIMPLE UPTIME-SIMPLE
SERVICE LOGIN CHAOS TELNET
SERVICE LOGIN CHAOS SUPDUP
SERVICE LOGIN CHAOS 3600-LOGIN
SERVICE SEND CHAOS SEND
SERVICE SEND CHAOS CONVERSE
SERVICE NAMESPACE CHAOS NAMESPACE
SERVICE NAMESPACE-TIMESTAMP CHAOS-SIMPLE NAMESPACE-TIMESTAMP
SERVICE LISPM-FINGER CHAOS-SIMPLE LISPM-FINGER
SERVICE FILE CHAOS QFILE
SERVICE FILE CHAOS NFILE
SERVICE CONFIGURATION CHAOS CONFIGURATION
ADDRESS CHAOS 1200
""" + (f"""ADDRESS INTERNET {internet}
SERVICE LOGIN TCP TELNET
SERVICE FILE TCP TCP-FTP
SERVICE TIME UDP TIME-SIMPLE-MSB
""" if internet else "") + """SITE STANDALONE
MACHINE-TYPE XL1200

USER LISP-MACHINE
HOME-HOST XL1200
LISPM-NAME LISPM
"""
    log = "3/2/93 21:55:00 STANDALONE created by LISPM\n"
    changes = "TIMESTAMP 1\n"
    translations = """;;; -*- Mode: Lisp; Syntax: Common-Lisp; Package: FS; Base: 10 -*-

(SET-LOGICAL-PATHNAME-HOST "SYS" :TRANSLATIONS
  '(("SYS:SITE;**;*.*.*" "XL1200:>sys>site>**>*.*.*")
    ("SYS:**;*.*.*" "XL1200:>sys>**>*.*.*")))
"""
    return [('standalone-namespace', 'text', namespace),
            ('standalone-objects', 'text', objects),
            ('standalone-namespace-log', 'text', log),
            ('standalone-namespace-changes', 'text', changes),
            ('sys-translations', 'text', translations),
            ('Hello', 'boot', hello)]


def build_world_disk(args, name, typ, size):
    disk = Disk(args.out, args.stride, write=True)
    fs = FEPFS(disk)
    if args.blocks:
        fs.resize(args.blocks)
    if not args.no_grow and disk.nblocks < fs.capacity:
        disk.f.truncate(fs.capacity * disk.stride)
        disk.size_changed()
    with open(args.world, 'rb') as src:
        version, hdr, runs = fs.add_file(name, typ, src, size, args.author, args.comment,
                                         int(os.path.getmtime(args.world)) + UT_EPOCH)
    print(f"{args.out}: >{name}.{typ}.{version}, {size} bytes, header {hdr}, "
          f"data {runs_string(runs)}; image {disk.nblocks} blocks")
    def add_text(name, typ, data, cdate):
        data = lispm_text(data)
        version, hdr, runs = fs.add_file(name, typ, io.BytesIO(data), len(data), args.author, '', cdate)
        print(f"{args.out}: >{name}.{typ}.{version}, {len(data)} bytes of text, header {hdr}, "
              f"data {runs_string(runs)}")
    for path in args.text or []:
        name, _, typ = os.path.basename(path).rpartition('.')
        if not name or len(typ) > 4 or len(name) > 32:
            sys.exit(f"{path}: wants name.type, a name of at most 32 characters and a type of at most 4")
        with open(path, 'rb') as f:
            add_text(name, typ, f.read(), int(os.path.getmtime(path)) + UT_EPOCH)
    if args.standalone:
        for name, typ, text in standalone_site_files(args.internet):
            add_text(name, typ, text.encode('ascii'), int(time.time()) + UT_EPOCH)
    # Load World pages to the declared paging files, FEPn:>Page.page by default.
    paging = fs.free_blocks() - 4 if args.paging == 'rest' else int(args.paging)   # a header, and a directory page if one is needed
    if paging > 0:
        version, hdr, runs = fs.add_file('Page', 'page', None, paging * BLOCK, args.author, '',
                                         int(time.time()) + UT_EPOCH)
        print(f"{args.out}: >Page.page.{version}, {paging} blocks, header {hdr}, "
              f"data {runs_string(runs)}")
    disk.f.close()


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('-S', '--stride', type=int, default=1536,
                   help="bytes from one block to the next in the image (default 1536)")
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('ls', help="show the label, every file and the free space")
    s.add_argument('image')
    s.set_defaults(fn=cmd_ls)
    s = sub.add_parser('get', help="copy a file's contents out of the image")
    s.add_argument('image')
    s.add_argument('path', help="e.g. >Hello.boot or >douglas>test2.text.1")
    s.add_argument('out')
    s.set_defaults(fn=cmd_get)
    s = sub.add_parser('mkworld', help="copy TEMPLATE to OUT and add a world load file to it")
    s.add_argument('template', help="FEPFS image to start from (not changed)")
    s.add_argument('world', help="Ivory world load file, e.g. GENERA_8_3.ILOD")
    s.add_argument('out', help="new image")
    s.add_argument('--name', default='Genera-8-3.ilod', help="FEP file name (default %(default)s)")
    s.add_argument('--author', default='LISPM', help="default %(default)s")
    s.add_argument('--comment', default='', help="file comment")
    s.add_argument('--text', action='append', metavar='FILE',
                   help="also add this text file (Lisp Machine character set), before the paging file")
    s.add_argument('--paging', default='rest', metavar='BLOCKS',
                   help="also add the paging file >Page.page of this many blocks; "
                        "'rest' (the default) uses all the free space, 0 adds none")
    s.add_argument('--standalone', action='store_true',
                   help="also add the files of Symbolics' standalone site (a Hello.boot with the "
                        "boot options, the namespace, sys-translations.text for the LMFS)")
    s.add_argument('--internet', metavar='A.B.C.D',
                   help="with --standalone: the machine's Internet address (the INTERNET network "
                        "and TCP services go in the namespace, both addresses in the Hello.boot)")
    s.add_argument('--no-grow', action='store_true',
                   help="keep the template's size instead of the label's disk size")
    s.add_argument('--blocks', type=int, metavar='N',
                   help="make the disk N blocks (a bigger label and free map) before adding files")
    s.add_argument('--force', action='store_true', help="add WORLD even if it doesn't look like one")
    s.set_defaults(fn=cmd_mkworld)
    args = p.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
