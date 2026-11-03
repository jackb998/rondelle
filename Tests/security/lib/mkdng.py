#!/usr/bin/python3 -I
# mkdng.py OUT WIDTH HEIGHT: a minimal camera RAW (DNG 1.4, LinearRaw RGB, 16 bit, uncompressed) with a gradient,
# that ImageIO opens like a photo. WIDTH × HEIGHT × 6 bytes on disk.
import struct, sys
out, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
row = b''.join(struct.pack('<HHH', x * 65535 // max(w - 1, 1), 30000, 20000) for x in range(w))
extra = bytearray()
def add(b):
    off = len(extra)
    extra.extend(b)
    if len(extra) % 2: extra.append(0)
    return off
entries = 16
base = 8 + 2 + entries * 12 + 4
bps = add(struct.pack('<HHH', 16, 16, 16))
model = add(b'Rondelle Test\0')
matrix = add(b''.join(struct.pack('<ii', v, 10000) for v in [10000, 0, 0, 0, 10000, 0, 0, 0, 10000]))
neutral = add(b''.join(struct.pack('<II', 1, 1) for _ in range(3)))
pixels = base + len(extra)
tags = sorted([
    (254, 4, 1, 0), (256, 4, 1, w), (257, 4, 1, h), (258, 3, 3, base + bps), (259, 3, 1, 1),
    (262, 3, 1, 34892), (273, 4, 1, pixels), (277, 3, 1, 3), (278, 4, 1, h), (279, 4, 1, w * h * 6),
    (284, 3, 1, 1), (50706, 1, 4, int.from_bytes(bytes([1, 4, 0, 0]), 'little')), (50708, 2, 14, base + model),
    (50721, 10, 9, base + matrix), (50728, 5, 3, base + neutral), (50778, 3, 1, 21),
])
ifd = struct.pack('<H', entries)
for tag, kind, count, value in tags:
    ifd += struct.pack('<HHI', tag, kind, count) + (struct.pack('<HH', value, 0) if kind == 3 and count == 1 else struct.pack('<I', value))
with open(out, 'wb') as f:
    f.write(b'II*\0' + struct.pack('<I', 8) + ifd + struct.pack('<I', 0) + extra)
    for _ in range(h): f.write(row)
