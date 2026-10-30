"""Summarize an xlemu trace as a call trace using the kernel function table.

Prints a line whenever execution enters a function (entry instruction) or a
trap/IO event appears.  Usage: calltrace.py trace.txt [maxlines]
"""
import bisect, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
starts, names, ends = [], [], []
for line in open(os.path.join(HERE, 'data/i333-functions.txt')):
    a, size, name = line.rstrip('\n').split(' ', 2)
    a = int(a, 16)
    starts.append(a - 2); ends.append(a - 2 + int(size)); names.append(name)


def fname(addr):
    i = bisect.bisect_right(starts, addr) - 1
    if i >= 0 and addr < ends[i]:
        return names[i]
    return f'?{addr:08x}'


def main():
    path = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10**9
    n = 0
    for line in open(path):
        m = re.match(r'([0-9a-f]+) ([0-9a-f]{8})\.\d  (entry-rest-\S+)', line)
        if m:
            print(f"{m.group(1)} {fname(int(m.group(2), 16))}")
            n += 1
        elif 'TRAP' in line or 'EXCEPTION' in line or 'BUS ERROR' in line:
            print(line.rstrip())
            n += 1
        if n >= limit:
            break


if __name__ == '__main__':
    main()
