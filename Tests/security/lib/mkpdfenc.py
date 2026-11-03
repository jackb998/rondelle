#!/usr/bin/python3 -I
# mkpdfenc.py OUT KIND BODY N [PASSWORD]: an encrypted PDF that opens with PASSWORD (default: no password at all).
# KIND: rc4-40, rc4-128, aes-128, aes-256. BODY: numeri (N numbers and no operator) or righe (N lines of ordinary text).
# Standard library only, so AES is written out here: encryption only, and just for these tests.
import hashlib, os, struct, sys, zlib
PAD = bytes.fromhex('28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A')

def rc4(k, d):
    S = list(range(256)); j = 0
    for i in range(256):
        j = (j + S[i] + k[i % len(k)]) % 256; S[i], S[j] = S[j], S[i]
    i = j = 0; o = bytearray()
    for b in d:
        i = (i + 1) % 256; j = (j + S[i]) % 256; S[i], S[j] = S[j], S[i]; o.append(b ^ S[(S[i] + S[j]) % 256])
    return bytes(o)

SBOX = [0] * 256
p = q = 1
while True:
    p = p ^ ((p << 1) & 255) ^ (0x1B if p & 0x80 else 0)
    q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 255
    if q & 0x80: q ^= 0x09
    x = q ^ (q << 1 | q >> 7) & 255 ^ (q << 2 | q >> 6) & 255 ^ (q << 3 | q >> 5) & 255 ^ (q << 4 | q >> 4) & 255
    SBOX[p] = (x ^ 0x63) & 255
    if p == 1: break
SBOX[0] = 0x63
XT = [((i << 1) ^ (0x1B if i & 0x80 else 0)) & 255 for i in range(256)]

def expand(key):
    n = len(key) // 4; rounds = n + 6
    w = [list(key[i * 4:i * 4 + 4]) for i in range(n)]
    rc = 1
    for i in range(n, 4 * (rounds + 1)):
        t = list(w[i - 1])
        if i % n == 0:
            t = [SBOX[t[1]] ^ rc, SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]]; rc = XT[rc]
        elif n > 6 and i % n == 4:
            t = [SBOX[b] for b in t]
        w.append([a ^ b for a, b in zip(w[i - n], t)])
    return w, rounds

def block(w, rounds, s):
    s = [a ^ b for a, b in zip(s, sum(w[:4], []))]
    for r in range(1, rounds + 1):
        s = [SBOX[b] for b in s]
        s = [s[0], s[5], s[10], s[15], s[4], s[9], s[14], s[3], s[8], s[13], s[2], s[7], s[12], s[1], s[6], s[11]]
        if r != rounds:
            o = []
            for c in range(0, 16, 4):
                a = s[c:c + 4]
                o += [XT[a[0]] ^ XT[a[1]] ^ a[1] ^ a[2] ^ a[3], a[0] ^ XT[a[1]] ^ XT[a[2]] ^ a[2] ^ a[3],
                      a[0] ^ a[1] ^ XT[a[2]] ^ XT[a[3]] ^ a[3], XT[a[0]] ^ a[0] ^ a[1] ^ a[2] ^ XT[a[3]]]
            s = o
        s = [a ^ b for a, b in zip(s, sum(w[4 * r:4 * r + 4], []))]
    return s

def cbc(key, iv, data):
    w, rounds = expand(key)
    out = bytearray(); prev = list(iv)
    for i in range(0, len(data), 16):
        prev = block(w, rounds, [a ^ b for a, b in zip(prev, data[i:i + 16])])
        out += bytes(prev)
    return bytes(out)

def padded(d):
    n = 16 - len(d) % 16
    return d + bytes([n]) * n

def hash2b(word, salt, extra=b''):
    k = hashlib.sha256(word + salt + extra).digest()
    i = 0
    while True:
        e = cbc(k[:16], k[16:32], (word + k + extra) * 64)
        m = sum(e[:16]) % 3
        k = (hashlib.sha256 if m == 0 else hashlib.sha384 if m == 1 else hashlib.sha512)(e).digest()
        i += 1
        if i >= 64 and e[-1] <= i - 32:
            return k[:32]

out, kind, body, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
word = (sys.argv[5] if len(sys.argv) > 5 else '').encode()
LINE = b'BT /F1 8 Tf 20 700 Td (il gatto dorme sul tavolo) Tj ET\n'
content = zlib.compress(b'1 ' * n if body == 'numeri' else LINE * n, 9)
fid = b'0123456789abcdef'; P = -4
h = lambda b: b.hex().encode()
num = 4

def object_key(key, aes):
    return hashlib.md5(key + struct.pack('<I', num)[:3] + b'\0\0' + (b'sAlT' if aes else b'')).digest()[:min(len(key) + 5, 16)]

if kind == 'aes-256':
    key = bytes(range(32))
    vs, ks = b'valsalt1', b'keysalt1'
    U = hash2b(word, vs) + vs + ks
    UE = cbc(hash2b(word, ks), bytes(16), key)
    O = hash2b(b'proprietario', vs, U) + vs + ks
    OE = cbc(hash2b(b'proprietario', ks, U), bytes(16), key)
    perms = cbc(key, bytes(16), struct.pack('<i', P) + b'\xff\xff\xff\xffFadb' + b'abcd')
    iv = bytes(16)
    data = iv + cbc(key, iv, padded(content))
    enc = b'<< /Filter /Standard /V 5 /R 6 /Length 256 /O <%s> /U <%s> /OE <%s> /UE <%s> /Perms <%s> /P %d /StmF /StdCF /StrF /StdCF /CF << /StdCF << /CFM /AESV3 /Length 32 /AuthEvent /DocOpen >> >> >>' % (h(O), h(U), h(OE), h(UE), h(perms), P)
else:
    R, V, size = {'rc4-40': (2, 1, 5), 'rc4-128': (3, 2, 16), 'aes-128': (4, 4, 16)}[kind]
    pw = (word + PAD)[:32]
    d = hashlib.md5((b'proprietario' + PAD)[:32]).digest()
    if R >= 3:
        for _ in range(50): d = hashlib.md5(d).digest()
    O = rc4(d[:size], pw)
    if R >= 3:
        for i in range(1, 20): O = rc4(bytes(b ^ i for b in d[:size]), O)
    key = hashlib.md5(pw + O + struct.pack('<i', P) + fid).digest()
    if R >= 3:
        for _ in range(50): key = hashlib.md5(key[:size]).digest()
    key = key[:size]
    if R == 2:
        U = rc4(key, PAD)
    else:
        U = rc4(key, hashlib.md5(PAD + fid).digest())
        for i in range(1, 20): U = rc4(bytes(b ^ i for b in key), U)
        U += bytes(16)
    if kind == 'aes-128':
        iv = bytes(range(16))
        data = iv + cbc(object_key(key, True), iv, padded(content))
        enc = b'<< /Filter /Standard /V 4 /R 4 /Length 128 /O <%s> /U <%s> /P %d /StmF /StdCF /StrF /StdCF /CF << /StdCF << /CFM /AESV2 /Length 16 /AuthEvent /DocOpen >> >> >>' % (h(O), h(U), P)
    else:
        data = rc4(object_key(key, False), content)
        enc = b'<< /Filter /Standard /V %d /R %d%s /O <%s> /U <%s> /P %d >>' % (V, R, b' /Length 128' if R >= 3 else b'', h(O), h(U), P)

font = b''
objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>',
        b'<< /Filter /FlateDecode /Length %d >>\nstream\n' % len(data) + data + b'\nendstream', enc]
chunks = [b'%PDF-1.7\n']; position = 9; offsets = []
for i, o in enumerate(objs):
    piece = b'%d 0 obj\n' % (i + 1) + o + b'\nendobj\n'
    offsets.append(position); chunks.append(piece); position += len(piece)
xref = b'xref\n0 6\n0000000000 65535 f \n' + b''.join(b'%010d 00000 n \n' % o for o in offsets)
chunks.append(xref + b'trailer << /Size 6 /Root 1 0 R /Encrypt 5 0 R /ID [<%s><%s>] >>\nstartxref\n%d\n%%%%EOF\n' % (h(fid), h(fid), position))
open(out, 'wb').write(b''.join(chunks))
