"""Map the model's error microstates (the VLM's rev-5 numbering) to the rev-4
Ivory's, for chip revision 4 (the XL1200).

Genera decodes an error trap by looking its microstate up in
DBG:*TRAP-DISPATCH-TABLES*, one 2048-entry table of trap descriptors per chip
revision.  Open Genera's world has the rev-4 and rev-5 tables; each rev-5
microstate maps to a rev-4 microstate with the same descriptor.

    python3 tools/errortable.py Genera-8-5.vlod     prints the C table
"""
import sys
import worldfile
from ivory import T, wtype


def dispatch_tables(w):
    s = w.symbols('*TRAP-DISPATCH-TABLES*')[0]
    v = w[s + 1]
    while wtype(v) == T['ONE-Q-FORWARD']:
        v = w[v[1]]
    return {rev: [e[1] if wtype(e) == T['FIXNUM'] else None for e in w.array_elements(t)]
            for rev, t in enumerate(w.array_elements(v)) if wtype(t) == T['ARRAY']}


def main():
    tables = dispatch_tables(worldfile.WorldFile(sys.argv[1]))
    t4, t5 = tables[4], tables[5]
    out = [0]
    for m5 in range(1, max(i for i, d in enumerate(t5) if d) + 1):
        out.append(next(i for i, d in enumerate(t4) if d == t5[m5] and i))
    print(f"static const uint16_t rev4_microstate[{len(out)}] = {{")
    for i in range(0, len(out), 12):
        print("    " + ", ".join(str(x) for x in out[i:i + 12]) + ",")
    print("};")


if __name__ == '__main__':
    main()
