#!/usr/bin/python3 -I
# mkpdfid.py KIND IN OUT [MB]: variants of an encrypted test PDF made by mkpdfenc.py (T1, the /ID of the file).
#   idpad   an unreferenced object of MB megabytes of «/ID[<» before the xref (the attack)
#   incr    an incremental update: a second xref section and trailer, with /Prev and the same /ID
#   fakeid  a false «/ID [<…>]» written after %%EOF, with no new startxref
import re, sys
kind, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(src, 'rb').read()
x = d.index(b'xref\n')
old = int(re.search(rb'startxref\n(\d+)', d).group(1))
fid = re.search(rb'/ID \[(<[0-9a-f]+>)', d).group(1)
if kind == 'idpad':
    payload = b'/ID[<' * int(float(sys.argv[4]) * 1_000_000 / 5)
    junk = b'6 0 obj\n<< /Length %d >>\nstream\n' % len(payload) + payload + b'\nendstream\nendobj\n'
    d = d[:x] + junk + re.sub(rb'startxref\n\d+', b'startxref\n%d' % (x + len(junk)), d[x:])
elif kind == 'incr':
    at = len(d)
    obj = b'1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
    xref = at + len(obj)
    d += obj + b'xref\n0 1\n0000000000 65535 f \n1 1\n%010d 00000 n \n' % at
    d += b'trailer << /Size 6 /Root 1 0 R /Encrypt 5 0 R /ID [%s%s] /Prev %d >>\nstartxref\n%d\n%%%%EOF\n' % (fid, fid, old, xref)
elif kind == 'fakeid':
    d += b'% after the end\n/ID [<ffffffffffffffffffffffffffffffff><00>]\n'
open(out, 'wb').write(d)
