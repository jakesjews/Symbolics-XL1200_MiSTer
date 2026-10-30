"""Annotate xlemu backtrace lines ("  #n pc args...") with kernel function names."""
import bisect, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
starts, names, ends = [], [], []
for line in open(os.path.join(HERE, 'data/i333-functions.txt')):
    a, size, name = line.rstrip('\n').split(' ', 2)
    a = int(a, 16)
    starts.append(a - 2); ends.append(a - 2 + int(size)); names.append(name)


def fname(addr):
    i = bisect.bisect_right(starts, addr) - 1
    return names[i] if i >= 0 and addr < ends[i] else '?'


for line in sys.stdin:
    m = re.match(r'(\s+#\d+\s+)([0-9a-f]{8})(.*)', line)
    if m:
        line = f"{m.group(1)}{m.group(2)} {fname(int(m.group(2), 16)):45s}{m.group(3)}\n"
    sys.stdout.write(line)
