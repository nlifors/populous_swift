#!/usr/bin/env python3
"""Lays an AmigaDOS hunk executable out as one flat image, relocated to a base
address, so Ghidra can load it as raw binary: flatten_hunks.py <exe> <out> <base-hex>
Prints where each hunk went."""
import struct, sys

data = open(sys.argv[1], 'rb').read()
base = int(sys.argv[3], 16)
pos = 0
def long():
    global pos
    value = struct.unpack('>I', data[pos:pos + 4])[0]
    pos += 4
    return value

assert long() == 0x3F3
long()
count = long(); long(); long()
sizes = [(long() & 0x3FFFFFFF) * 4 for _ in range(count)]
starts = [base + sum(sizes[:i]) for i in range(count)]
image = bytearray(sum(sizes))
hunk = 0
while pos < len(data):
    kind = long() & 0x3FFFFFFF
    if kind in (0x3E9, 0x3EA):
        size = long() * 4
        offset = starts[hunk] - base
        image[offset:offset + size] = data[pos:pos + size]
        pos += size
    elif kind == 0x3EB:
        long()
    elif kind == 0x3EC:
        while True:
            n = long()
            if n == 0: break
            target = long()
            for _ in range(n):
                at = starts[hunk] - base + long()
                value = struct.unpack('>I', image[at:at + 4])[0] + starts[target]
                image[at:at + 4] = struct.pack('>I', value & 0xFFFFFFFF)
    elif kind == 0x3F2:
        hunk += 1
    else:
        raise SystemExit('unsupported hunk type %x' % kind)
open(sys.argv[2], 'wb').write(image)
for i, (start, size) in enumerate(zip(starts, sizes)):
    print('hunk %d: %x..%x' % (i, start, start + size))
