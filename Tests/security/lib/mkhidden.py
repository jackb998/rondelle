#!/usr/bin/python3 -I
# mkhidden.py OUT.pdf: visible text, white text and text under a black box.
import sys, zlib
content = (b'BT /F1 18 Tf 50 700 Td (Il documento pubblico parla del giardino) Tj ET\n'
           b'1 1 1 rg BT /F1 18 Tf 50 650 Td (CANARINOBIANCO codice segreto) Tj ET\n'
           b'0 0 0 rg BT /F1 18 Tf 50 600 Td (CANARINOCOPERTO nome riservato) Tj ET\n'
           b'40 590 500 35 re f\n')
z = zlib.compress(content)
objs = [b'<</Type/Catalog/Pages 2 0 R>>', b'<</Type/Pages/Kids[3 0 R]/Count 1>>',
        b'<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>',
        b'<</Length %d/Filter/FlateDecode>>\nstream\n' % len(z) + z + b'\nendstream',
        b'<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>']
out = b'%PDF-1.4\n'; offsets = []
for i, o in enumerate(objs, 1):
    offsets.append(len(out)); out += b'%d 0 obj\n' % i + o + b'\nendobj\n'
x = len(out)
out += b'xref\n0 6\n0000000000 65535 f \n' + b''.join(b'%010d 00000 n \n' % o for o in offsets)
out += b'trailer<</Size 6/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n' % x
open(sys.argv[1], 'wb').write(out)
