import sys, struct
# mkred.py DIR: thumb.jpg (EXIF thumbnail = a different picture, the QR code, marked CNRYTHUMB) and
# tail.jpg (a fake Motion Photo: an MP4-like blob marked CNRYMOTION after the end of the image).
d = sys.argv[1]
base = open(d + '/base.jpg', 'rb').read()
th = open(d + '/thumbsrc.jpg', 'rb').read()
com = b'CNRYTHUMB'
th = th[:2] + b'\xff\xfe' + struct.pack('>H', len(com) + 2) + com + th[2:]
def ifd(entries, nxt):
    out = struct.pack('>H', len(entries))
    for tag, typ, cnt, val in entries:
        out += struct.pack('>HHI', tag, typ, cnt) + (struct.pack('>HH', val, 0) if typ == 3 else struct.pack('>I', val))
    return out + struct.pack('>I', nxt)
ifd0_off = 8; ifd0_len = 2 + 12 + 4
ifd1_off = ifd0_off + ifd0_len; ifd1_len = 2 + 3 * 12 + 4
th_off = ifd1_off + ifd1_len
tiff = b'MM\x00\x2a' + struct.pack('>I', ifd0_off) + ifd([(0x0112, 3, 1, 1)], ifd1_off) \
     + ifd([(0x0103, 3, 1, 6), (0x0201, 4, 1, th_off), (0x0202, 4, 1, len(th))], 0) + th
app1 = b'Exif\x00\x00' + tiff
seg = b'\xff\xe1' + struct.pack('>H', len(app1) + 2) + app1
open(d + '/thumb.jpg', 'wb').write(base[:2] + seg + base[2:])
blob = struct.pack('>I', 24) + b'ftypmp42' + b'\x00' * 12 + b'CNRYMOTION' * 2000
open(d + '/tail.jpg', 'wb').write(base + blob)
