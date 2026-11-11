#!/usr/bin/python3 -I
# mkiwork.py OUT [BASE.key]: hostile Keynote, Numbers and Pages files for section U (1.0.11.1 audit, A1–A3): decompression
# bombs, a lying block header, 2 million tiny blocks, cut blocks, 10 million fields, 2 million archives, deep nesting,
# a text whose style tables cost paragraphs × entries, and the files exactly at each cap and one past it (32 MB per .iwa,
# 64 MB per file, 1024 blocks per .iwa, 8192 per file, 100 000 fields per message and per Archive.parse, 20 000 archives
# per file). With BASE.key (a real Keynote file), the caps of the whole file are also tried on it with padding .iwa files.
# Standard library only.
import os, sys, zipfile, shutil
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
def v(x):
    b = bytearray()
    while True:
        y = x & 0x7f; x >>= 7
        if x: b.append(y | 0x80)
        else: b.append(y); return bytes(b)
def lit(d):
    n = len(d) - 1
    if n < 60: return bytes([n << 2]) + d
    if n < 256: return bytes([60 << 2, n]) + d
    if n < 65536: return bytes([61 << 2]) + n.to_bytes(2, 'little') + d
    return bytes([62 << 2]) + n.to_bytes(3, 'little') + d
def copies(period, n):   # n more bytes repeating the last `period` bytes
    b = bytearray(); full, r = divmod(n, 64)
    b += (bytes([0xFE]) + period.to_bytes(2, 'little')) * full
    if r: b += bytes([((r - 1) << 2) | 2]) + period.to_bytes(2, 'little')
    return bytes(b)
def chunk(block): return bytes([0]) + len(block).to_bytes(3, 'little') + block
CH = 4_000_000
def blocks(segs):
    """segs: ('lit', bytes) or ('rep', pattern, n): decoded bytes → IWA chunks, at most CH decoded per chunk."""
    res = []; merged = []
    for s in segs:   # adjacent literals in one block, as Apple writes them (blocks of up to 64 KB, here CH)
        if s[0] == 'lit' and merged and merged[-1][0] == 'lit': merged[-1] = ('lit', merged[-1][1] + s[1])
        else: merged.append(s)
    for s in merged:
        if s[0] == 'lit':
            d = s[1]
            for i in range(0, len(d), CH): res.append(chunk(v(len(d[i:i+CH])) + lit(d[i:i+CH])))
        else:
            _, p, n = s
            while n > 0:
                m = min(n, CH); m -= m % len(p) if m > len(p) else 0
                if m < len(p): m = n
                body = lit(p[:m]) + (copies(len(p), m - len(p)) if m > len(p) else b'')
                res.append(chunk(v(m) + body)); n -= m
    return res
def info(oid, typ, size, extra=b''):
    mi = b'\x08' + v(typ) + b'\x18' + v(size)
    i = b'\x08' + v(oid) + b'\x12' + v(len(mi)) + mi + extra
    return v(len(i)) + i
def text_archive(oid=1, text=b'Testo di prova A1', fields=0):
    payload = b'\x1a' + v(len(text)) + text
    return [('lit', info(oid, 2001, len(payload) + 2 * fields) + payload)] + ([('rep', b'\x08\x00', 2 * fields)] if fields else [])
def pad_archive(oid, size):
    return [('lit', info(oid, 9999, size))] + ([('rep', b'\x00', size)] if size else [])
def seglen(segs): return sum(len(s[1]) if s[0] == 'lit' else s[2] for s in segs)
def padded_to(total, oid=2, head=None):
    head = head if head is not None else text_archive()
    used = seglen(head); hdr = len(info(oid, 9999, 0))
    size = total - used - hdr
    while len(info(oid, 9999, size)) + used + size != total: size -= 1
    return head + pad_archive(oid, size)
def folder(name, files):
    p = os.path.join(out, name)
    if os.path.exists(p): shutil.rmtree(p)
    os.makedirs(os.path.join(p, 'Index'))
    for n, data in files.items(): open(os.path.join(p, 'Index', n), 'wb').write(data)
def zipped(name, files):
    z = zipfile.ZipFile(os.path.join(out, name), 'w', zipfile.ZIP_DEFLATED)
    for n, data in files.items(): z.writestr('Index/' + n, data)
    z.close()
def iwa(segs, extra_empty=0): return b''.join(blocks(segs)) + chunk(b'\x00') * extra_empty
# Bombs (copies of 64 bytes from 3): ~1 GB decoded from 50 MB, deflated in a ZIP to ~48 KB.
bl = bytearray(lit(b'\0'))
while len(bl) + 3 <= (1 << 24) - 64: bl += b'\xfe\x01\x00'
exp = 1 + (len(bl) - 1) // 3 * 64
bomb = chunk(v(exp) + bytes(bl))
zipped('bomb.key', {'Document.iwa': bomb * 3}); zipped('bomb.numbers', {'Document.iwa': bomb * 3})
bl86 = bytearray(lit(b'\0'))
while len(bl86) + 3 <= 8_600_000: bl86 += b'\xfe\x01\x00'
folder('bomb86.pages', {'Document.iwa': chunk(v(1 + (len(bl86) - 1) // 3 * 64) + bytes(bl86))})
# Many tiny chunks: 2 000 000 empty blocks (10 MB, ~10 KB zipped).
zipped('tiny.key', {'Document.iwa': chunk(b'\x00') * 2_000_000})
folder('tiny.pages', {'Document.iwa': iwa(text_archive(), 2_000_000)})
# A lying header: «10 bytes» and 1 GB of copies.
folder('liar.pages', {'Document.iwa': chunk(v(10) + bytes(bl))})
zipped('liar.key', {'Document.iwa': chunk(v(10) + bytes(bl))})
# Cut in the middle of a chunk: the header announces 16 MB, 1 MB follows.
folder('trunc.pages', {'Document.iwa': bomb[:1_000_000]})
zipped('trunc.key', {'Document.iwa': bomb[:1_000_000]})
# Deep nesting: a chain of 15 000 paragraph styles, each the parent of the one before, and a message nested 100 000 deep.
ref = b'\x08' + v(10)                      # the paragraph style of the text: the last of the chain (id 10)
entry = b'\x08\x00\x12' + v(len(ref)) + ref
table = b'\x0a' + v(len(entry)) + entry
txt = b'Testo di prova A1'; dp = b'\x1a' + v(len(txt)) + txt + b'\x2a' + v(len(table)) + table
deep = [('lit', info(1, 2001, len(dp)) + dp)]
nest = b'\x1a\x00'
for _ in range(100_000): nest = b'\x0a' + v(len(nest)) + nest if len(nest) < 2_000_000 else nest
deep += [('lit', info(3, 2001, len(nest)) + nest)]
for k in range(15_000):
    hdr = b'\x1a\x02\x08' + v(10 + k + 1)          # header field 3 → parent reference
    hdr = b'\x1a' + v(len(b'\x08' + v(10 + k + 1))) + b'\x08' + v(10 + k + 1)
    payload = b'\x0a' + v(len(hdr)) + hdr
    deep += [('lit', info(10 + k, 2022, len(payload)) + payload)]
folder('deep.pages', {'Document.iwa': iwa(deep)})
# Many fields: one text storage with 10 000 000 empty fields (20 MB).
folder('campi.pages', {'Document.iwa': iwa(text_archive(fields=10_000_000))})
zipped('campi.key', {'Document.iwa': iwa(text_archive(fields=10_000_000))})
# Many archives: 2 000 000 empty archives (each one byte: an empty info).
folder('archivi.pages', {'Document.iwa': iwa(text_archive() + [('rep', b'\x00', 2_000_000)])})
# --- At each cap and one past it.
MB = 1_000_000
folder('cap-iwa.pages', {'Document.iwa': iwa(padded_to(32 * MB))})
folder('cap-iwa+1.pages', {'Document.iwa': iwa(padded_to(32 * MB + 1))})
zipped('cap-tot.key', {'Document.iwa': iwa(padded_to(32 * MB)), 'Slide-1.iwa': iwa(padded_to(32 * MB))})
zipped('cap-tot+1.key', {'Document.iwa': iwa(padded_to(32 * MB)), 'Slide-1.iwa': iwa(padded_to(32 * MB)), 'Slide-2.iwa': iwa(pad_archive(5, 0))})
def nchunks(segs): return len(blocks(segs))
t = text_archive(); base = nchunks(t)
folder('cap-chunk.pages', {'Document.iwa': iwa(t, 1024 - base)})
folder('cap-chunk+1.pages', {'Document.iwa': iwa(t, 1025 - base)})
zipped('cap-chunktot.key', {('Slide-%d.iwa' % k): chunk(b'\x00') * 1024 for k in range(8)})
zipped('cap-chunktot+1.key', dict({('Slide-%d.iwa' % k): chunk(b'\x00') * 1024 for k in range(8)}, **{'Slide-9.iwa': chunk(b'\x00')}))
folder('cap-campi.pages', {'Document.iwa': iwa(text_archive(fields=99_999))})
folder('cap-campi+1.pages', {'Document.iwa': iwa(text_archive(fields=100_000))})
def archives(n):   # the text storage and n - 1 empty archives
    return text_archive() + ([('rep', b'\x00', n - 1)] if n > 1 else [])
folder('cap-archivi.pages', {'Document.iwa': iwa(archives(20_000))})
folder('cap-archivi+1.pages', {'Document.iwa': iwa(archives(20_001))})
def infos(total):   # the text storage, then archives whose infos add up to `total` fields (with the text's own 4)
    segs = text_archive(); left = total - 4; oid = 100
    while left > 0:
        k = min(left, 50_000) - 1   # id + k extra fields
        extra = b'\x18\x00' * k
        i = b'\x08' + v(oid) + extra
        segs.append(('lit', v(len(i)) + i)); left -= k + 1; oid += 1
    return segs
folder('cap-info.pages', {'Document.iwa': iwa(infos(100_000))})
folder('cap-info+1.pages', {'Document.iwa': iwa(infos(100_001))})
# --- File caps on a real Keynote (copied into OUT/../real/k1.key): padding .iwa files («Slide-pad*.iwa») up to the cap and one past it.
def real_counts(path, wanted):
    z = zipfile.ZipFile(path); b = c = a = 0
    for n in z.namelist():
        if not (n.startswith('Index/') and n.endswith('.iwa') and wanted(n[6:])): continue
        raw = z.read(n); i = 0; dec = bytearray()
        while i < len(raw):
            L = int.from_bytes(raw[i+1:i+4], 'little'); blk = raw[i+4:i+4+L]; i += 4 + L; c += 1
            exec_snappy(blk, dec)
        b += len(dec); j = 0
        while j < len(dec):
            m, j = rv(dec, j); inf = dec[j:j+m]; j += m; a += 1
            for size in msg_sizes(inf): j += size
    return b, c, a
def rv(d, i):
    x = s = 0
    while True:
        y = d[i]; i += 1; x |= (y & 0x7f) << s; s += 7
        if y < 0x80: return x, i
def exec_snappy(d, out):
    start = len(out); e, i = rv(d, 0)
    while i < len(d):
        t = d[i]; i += 1; k = t & 3
        if k == 0:
            n = t >> 2
            if n >= 60: m = n - 59; n = int.from_bytes(d[i:i+m], 'little'); i += m
            n += 1; out += d[i:i+n]; i += n; continue
        if k == 1: n = ((t >> 2) & 7) + 4; off = ((t >> 5) << 8) | d[i]; i += 1
        elif k == 2: n = (t >> 2) + 1; off = int.from_bytes(d[i:i+2], 'little'); i += 2
        else: n = (t >> 2) + 1; off = int.from_bytes(d[i:i+4], 'little'); i += 4
        for _ in range(n): out.append(out[-off])
def msg_sizes(inf):
    res = []; j = 0
    while j < len(inf):
        k, j = rv(inf, j); w = k & 7
        if w == 0: _, j = rv(inf, j)
        elif w == 2:
            m, j = rv(inf, j); d = inf[j:j+m]; j += m
            if k >> 3 == 2:
                q = 0; sz = 0
                while q < len(d):
                    kk, q = rv(d, q); ww = kk & 7
                    if ww == 0:
                        val, q = rv(d, q)
                        if kk >> 3 == 3: sz = val
                    elif ww == 2: mm, q = rv(d, q); q += mm
                    elif ww == 1: q += 8
                    else: q += 4
                res.append(sz)
        elif w == 1: j += 8
        else: j += 4
    return res
k1 = sys.argv[2] if len(sys.argv) > 2 else None
kw = lambda n: n in ('Document.iwa', 'DocumentStylesheet.iwa', 'Metadata.iwa') or (n.startswith('Slide-') and n.endswith('.iwa'))
if k1:
    B0, C0, A0 = real_counts(k1, kw)
    def with_pads(name, pads):
        shutil.copy(k1, os.path.join(out, name)); z = zipfile.ZipFile(os.path.join(out, name), 'a', zipfile.ZIP_DEFLATED)
        for n, data in pads.items(): z.writestr('Index/' + n, data)
        z.close()
    def bytes_pads(total):   # padding .iwa files of at most 30 MB decoded each, adding up to `total`
        pads = {}; k = 0; left = total
        while left > 0:
            m = min(left, 30 * MB)
            if left - m and left - m < 64: m -= 64
            pads['Slide-pad%d.iwa' % k] = iwa(padded_to(m, 900 + k, head=[])); left -= m; k += 1
        return pads
    with_pads('cap-tot-k1.key', bytes_pads(64 * MB - B0))
    with_pads('cap-tot-k1+1.key', bytes_pads(64 * MB - B0 + 1))
    def chunk_pads(n):
        pads = {}; k = 0
        while n > 0: m = min(n, 1000); pads['Slide-padc%d.iwa' % k] = chunk(b'\x00') * m; n -= m; k += 1
        return pads
    with_pads('cap-chunktot-k1.key', chunk_pads(8192 - C0))
    with_pads('cap-chunktot-k1+1.key', chunk_pads(8193 - C0))
    with_pads('cap-archivi-k1.key', {'Slide-pada.iwa': iwa([('rep', b'\x00', 20_000 - A0)])})
    with_pads('cap-archivi-k1+1.key', {'Slide-pada.iwa': iwa([('rep', b'\x00', 20_001 - A0)])})
# A ZIP whose one block is under the 50 MB of input and decodes to ~350 MB.
zipped('bomb16.key', {'Document.iwa': bomb})
folder('bomb16.pages', {'Document.iwa': bomb})
# Style tables of 99 000 entries over 1 000 000 paragraphs: the style in force must be found without a pass over the
# whole table at every paragraph (before: hours, and «Annulla» not heard).
def table(num, n):
    t = bytearray()
    for k in range(n):
        ref = b'\x08' + v(5)
        e = b'\x08' + v(k) + b'\x12' + v(len(ref)) + ref
        t += b'\x0a' + v(len(e)) + e
    return bytes([num << 3 | 2]) + v(len(t)) + bytes(t)
txt = b'a\n' * 1_000_000
qp = b'\x1a' + v(len(txt)) + txt + table(5, 99_000) + table(8, 99_000)
folder('quad.pages', {'Document.iwa': iwa([('lit', info(1, 2001, len(qp)) + qp)])})
