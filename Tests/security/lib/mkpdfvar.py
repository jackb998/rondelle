#!/usr/bin/python3 -I
# mkpdfvar.py OUT VARIANT BODY N: encrypted PDFs (Standard, V4/R4, user password empty, owner «proprietario») in the
# variants a reader may know or not (P1). BODY: numeri (N numbers, no operator: a bomb of ≈ 100 KB at 50 million)
# or righe (N lines of text). VARIANT:
#   v4-none     crypt filter /CFM /None: streams in clear
#   v4-v2       crypt filter /CFM /V2 (RC4, 128 bits)
#   v4-aesv2    crypt filter /CFM /AESV2
#   identity    /StmF /Identity: streams in clear
#   nometa      AESV2 with /EncryptMetadata false (the key changes)
#   cryptname   AESV2, but the content says /Filter [/Crypt /FlateDecode] with /Name /Identity: in clear
#   objstm      AESV2, pages in an encrypted object stream, cross-reference stream
#   xrefstm     AESV2, cross-reference stream instead of the table
#   cryptother  the content says /Filter [/Crypt /FlateDecode] with /Name /StdCF, the same as /StmF
#   cryptelse   the same with /Name /AltroCF, RC4 (/V2) for this stream alone while the others are AES
#   nocfm       a crypt filter with no /CFM, which means None: in clear, and not a form Rondelle reads
import hashlib, os, struct, sys, zlib
here = os.path.dirname(os.path.abspath(__file__))
# The RC4 and AES of mkpdfenc.py (its definitions only, before it reads its arguments).
exec(open(os.path.join(here, 'mkpdfenc.py')).read().split('out, kind, body, n =')[0])

out, variant, body, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
LINE = b'BT /F1 8 Tf 20 700 Td (il gatto dorme sul tavolo) Tj ET\n'
content = zlib.compress(b'1 ' * n if body == 'numeri' else LINE * n, 9)
fid = b'0123456789abcdef'; P = -4; size = 16
nometa = variant == 'nometa'
pw = PAD
d = hashlib.md5((b'proprietario' + PAD)[:32]).digest()
for _ in range(50): d = hashlib.md5(d).digest()
O = rc4(d[:size], pw)
for i in range(1, 20): O = rc4(bytes(b ^ i for b in d[:size]), O)
key = hashlib.md5(pw + O + struct.pack('<i', P) + fid + (b'\xff\xff\xff\xff' if nometa else b'')).digest()
for _ in range(50): key = hashlib.md5(key[:size]).digest()
key = key[:size]
U = rc4(key, hashlib.md5(PAD + fid).digest())
for i in range(1, 20): U = rc4(bytes(b ^ i for b in key), U)
U += bytes(16)

def okey(num, aes):
    return hashlib.md5(key + struct.pack('<I', num)[:3] + b'\0\0' + (b'sAlT' if aes else b'')).digest()[:16]

cfm = {'v4-none': b'/None', 'v4-v2': b'/V2', 'nocfm': b''}.get(variant, b'/AESV2')
def seal(num, data):
    if variant in ('v4-none', 'identity', 'nocfm'): return data
    if cfm == b'/V2': return rc4(okey(num, False), data)
    iv = bytes(range(16)); return iv + cbc(okey(num, True), iv, padded(data))

stm = b'/Identity' if variant == 'identity' else b'/StdCF'
enc = (b'<< /Filter /Standard /V 4 /R 4 /Length 128 /O <%s> /U <%s> /P %d /StmF %s /StrF %s /CF << /StdCF << %s /Length 16 /AuthEvent /DocOpen >>%s >>%s >>'
       % (O.hex().encode(), U.hex().encode(), P, stm, stm, b'/CFM ' + cfm if cfm else b'', b' /AltroCF << /CFM /V2 /Length 16 >>' if variant == 'cryptelse' else b'', b' /EncryptMetadata false' if nometa else b''))
if variant == 'cryptname':
    contents = b'<< /Filter [/Crypt /FlateDecode] /DecodeParms [<< /Name /Identity >> null] /Length %d >>\nstream\n' % len(content) + content + b'\nendstream'
elif variant in ('cryptother', 'cryptelse'):
    data = seal(4, content) if variant == 'cryptother' else rc4(okey(4, False), content)
    name = b'/StdCF' if variant == 'cryptother' else b'/AltroCF'
    contents = b'<< /Filter [/Crypt /FlateDecode] /DecodeParms [<< /Name %s >> null] /Length %d >>\nstream\n' % (name, len(data)) + data + b'\nendstream'
else:
    data = seal(4, content)
    contents = b'<< /Filter /FlateDecode /Length %d >>\nstream\n' % len(data) + data + b'\nendstream'
pages = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
         b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>']
trailer = b'/Root 1 0 R /Encrypt 5 0 R /ID [<%s><%s>]' % (fid.hex().encode(), fid.hex().encode())
chunks = [b'%PDF-1.7\n']; position = 9; offsets = {}
def put(num, body):
    global position
    piece = b'%d 0 obj\n' % num + body + b'\nendobj\n'
    offsets[num] = position; chunks.append(piece); position += len(piece)

if variant == 'objstm':
    # The page tree and the page in the object stream; the catalog stays outside, as CoreGraphics needs it there.
    head = b''; inner = b''
    for i, o in enumerate(pages[1:]):
        head += b'%d %d ' % (i + 2, len(inner)); inner += o + b'\n'
    raw = zlib.compress(head + inner)
    sealed = seal(6, raw)
    put(1, pages[0]); put(4, contents); put(5, enc)
    put(6, b'<< /Type /ObjStm /N 2 /First %d /Filter /FlateDecode /Length %d >>\nstream\n' % (len(head), len(sealed)) + sealed + b'\nendstream')
    rows = [(0, 0, 65535), (1, offsets[1], 0), (2, 6, 0), (2, 6, 1), (1, offsets[4], 0), (1, offsets[5], 0), (1, offsets[6], 0), (1, position, 0)]
else:
    for i, o in enumerate(pages): put(i + 1, o)
    put(4, contents); put(5, enc)
    rows = [(0, 0, 65535)] + [(1, offsets[i], 0) for i in range(1, 6)]
if variant in ('objstm', 'xrefstm'):
    num = len(rows) - (0 if variant == 'xrefstm' else 1)
    if variant == 'xrefstm': rows.append((1, position, 0))
    table = b''.join(struct.pack('>BIH', *r) for r in rows)
    start = position
    put(num, b'<< /Type /XRef /Size %d /W [1 4 2] %s /Length %d >>\nstream\n' % (len(rows), trailer, len(table)) + table + b'\nendstream')
    chunks.append(b'startxref\n%d\n%%%%EOF\n' % start)
else:
    xref = b'xref\n0 6\n0000000000 65535 f \n' + b''.join(b'%010d 00000 n \n' % offsets[i] for i in range(1, 6))
    chunks.append(xref + b'trailer << /Size 6 %s >>\nstartxref\n%d\n%%%%EOF\n' % (trailer, position))
open(out, 'wb').write(b''.join(chunks))
