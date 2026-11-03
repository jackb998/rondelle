import sys, zlib, struct
# pngalpha.py FILE.png: decodes the PNG itself (8-bit RGBA) and reports the stored RGB under alpha 0.
for p in sys.argv[1:]:
    d = open(p, 'rb').read(); i = 8; idat = b''; w = h = 0; ct = bd = None
    while i < len(d):
        n, t = struct.unpack('>I4s', d[i:i+8]); c = d[i+8:i+8+n]
        if t == b'IHDR': w, h, bd, ct = struct.unpack('>IIBB', c[:10])
        if t == b'IDAT': idat += c
        i += 12 + n
    if ct != 6 or bd != 8: print(p.split('/')[-1], f'PNG tipo {ct}/{bd} bit: non RGBA 8 bit'); continue
    raw = zlib.decompress(idat); bpp = 4; stride = w * bpp; prev = bytearray(stride); out = bytearray(); o = 0
    for y in range(h):
        f = raw[o]; line = bytearray(raw[o+1:o+1+stride]); o += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line; prev = line
    zero = 0; mx = 0
    for k in range(0, len(out), 4):
        if out[k+3] == 0: zero += 1; mx = max(mx, out[k], out[k+1], out[k+2])
    print(p.split('/')[-1], f'PNG (decodificato a mano): {zero} pixel con alpha 0, max RGB fra questi {mx}')
