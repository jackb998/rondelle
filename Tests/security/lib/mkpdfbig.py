#!/usr/bin/python3 -I
# mkpdfbig.py OUT MODE SIZE: an encrypted PDF (AESV2, no password to type, made by mkpdfvar.py) with one more stream,
# not used by any page, of SIZE bytes in the file (T2). MODE:
#   raw    no filter, random bytes
#   dct    /Filter /DCTDecode, random bytes (an image: nothing in it to check)
#   flate  /Filter /FlateDecode, AES-encrypted like the others, that unpacks to random bytes
# AES of a few hundred MB goes through the system's openssl; the rest is mkpdfvar.py.
import os, re, subprocess, sys, tempfile, zlib
OUT, MODE, SIZE = sys.argv[1], sys.argv[2], int(sys.argv[3])   # mkpdfvar.py has its own out and size
here = os.path.dirname(os.path.abspath(__file__))
sys.argv = ['mkpdfvar.py', OUT, 'v4-aesv2', 'righe', '10']
exec(open(os.path.join(here, 'mkpdfvar.py')).read())   # defines okey() and writes the base file to `out`
d = open(OUT, 'rb').read()
x = d.index(b'xref\n')
if MODE == 'flate':
    # raw = iv + AES(padded(content)): content is size - 32 bytes, so that the padding is one whole block
    clear = SIZE - 32
    body = zlib.compress(os.urandom(clear), 0)[:clear]
    body += os.urandom(clear - len(body))
    iv = bytes(range(16))
    with tempfile.TemporaryDirectory() as t:
        open(os.path.join(t, 'p'), 'wb').write(body + bytes([16]) * 16)
        subprocess.run(['/usr/bin/openssl', 'enc', '-aes-128-cbc', '-K', okey(6, True).hex(), '-iv', iv.hex(), '-nopad',
                        '-in', os.path.join(t, 'p'), '-out', os.path.join(t, 'e')], check=True)
        data = iv + open(os.path.join(t, 'e'), 'rb').read()
    head = b'6 0 obj\n<< /Filter /FlateDecode /Length %d >>\nstream\n' % len(data)
else:
    data = os.urandom(SIZE).replace(b'endstream', b'endstreaX')
    head = b'6 0 obj\n<< %s/Length %d >>\nstream\n' % (b'/Filter /DCTDecode ' if MODE == 'dct' else b'', SIZE)
junk = head + data + b'\nendstream\nendobj\n'
d = d[:x] + junk + re.sub(rb'startxref\n\d+', b'startxref\n%d' % (x + len(junk)), d[x:])
open(OUT, 'wb').write(d)
