#!/usr/bin/python3 -I
# fuzz-iwork.py [--count N] [--jobs J] [--seed S] [--keep DIR] -- BIN FILE.pages FILE.key FILE.numbers
#
# Structural fuzzing of the Keynote, Numbers and Pages readers of a DEBUG build: each mutant is a copy of a real file
# with one change where the readers trust the file (an IWA block's length, a Snappy block's announced size, an archive
# or message length, a protobuf length or varint, blocks split, repeated, dropped or cut), read with
# --test-pages-read / --test-keynote-read / --test-numbers-read. Prints only a summary per reader: crashes, reads over
# 10 s, peaks over 500 MB. Mutants that crash, hang or pass 500 MB are kept in --keep (default: a folder in $TMPDIR).
# The files and the mutants stay in $TMPDIR; no text of the files is printed.
import ctypes, io, os, random, subprocess, sys, tempfile, threading, time, zipfile
from concurrent.futures import ThreadPoolExecutor

args = sys.argv[1:]
count, jobs, seed, keep = 10_000, 4, 1, None
while args and args[0] != '--':
    k, v = args[0], args[1]; args = args[2:]
    if k == '--count': count = int(v)
    elif k == '--jobs': jobs = int(v)
    elif k == '--seed': seed = int(v)
    elif k == '--keep': keep = v
    else: sys.exit('opzione sconosciuta: ' + k)
if len(args) < 3: sys.exit('uso: fuzz-iwork.py [--count N] [--jobs J] [--seed S] [--keep DIR] -- BIN FILE...')
binary, files = args[1], args[2:]
keep = keep or tempfile.mkdtemp(prefix='fuzz-iwork-keep-', dir=os.environ.get('TMPDIR'))
os.makedirs(keep, exist_ok=True)
work = tempfile.mkdtemp(prefix='fuzz-iwork-', dir=os.environ.get('TMPDIR'))

libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
def memory_mb(pid):
    info = (ctypes.c_uint8 * 256)()
    if libproc.proc_pid_rusage(pid, 0, info) != 0: return 0
    d = bytes(info)
    return max(int.from_bytes(d[64:72], 'little'), int.from_bytes(d[72:80], 'little')) / 1e6

# --- IWA, Snappy and protobuf, just enough to find the fields and write the blocks back
def rv(d, i):
    x = s = 0
    while True:
        if i >= len(d) or s > 63: raise ValueError
        y = d[i]; i += 1; x |= (y & 0x7f) << s; s += 7
        if y < 0x80: return x, i
def wv(x):
    b = bytearray()
    while True:
        y = x & 0x7f; x >>= 7
        if x: b.append(y | 0x80)
        else: b.append(y); return bytes(b)
def snappy(d):
    out = bytearray(); _, i = rv(d, 0)
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
    return bytes(out)
def blocks(raw):
    res = []; i = 0
    while i + 4 <= len(raw):
        n = int.from_bytes(raw[i+1:i+4], 'little'); res.append(raw[i+4:i+4+n]); i += 4 + n
    return res
def literal(d):
    n = len(d) - 1
    if n < 60: return bytes([n << 2]) + d
    if n < 256: return bytes([60 << 2, n]) + d
    if n < 65536: return bytes([61 << 2]) + n.to_bytes(2, 'little') + d
    return bytes([62 << 2]) + n.to_bytes(3, 'little') + d
def encode(data, size=65536):
    out = bytearray()
    for i in range(0, max(len(data), 1), size):
        part = data[i:i+size]; b = wv(len(part)) + (literal(part) if part else b'')
        out += bytes([0]) + len(b).to_bytes(3, 'little') + b
    return bytes(out)
def header(b): return bytes([0]) + len(b).to_bytes(3, 'little') + b

def varints(data):
    """Positions (start, end, value) of the varints the readers trust: archive lengths, the fields of the archive
    infos, and the keys, lengths and values of the messages' fields down to three levels."""
    found = []
    def fields(lo, hi, depth):
        i = lo
        while i < hi:
            s = i; key, i = rv(data, i); found.append((s, i, key)); w = key & 7
            if w == 0: s = i; v, i = rv(data, i); found.append((s, i, v))
            elif w == 2:
                s = i; n, i = rv(data, i); found.append((s, i, n))
                if i + n > hi: raise ValueError
                if depth < 3:
                    try: fields(i, i + n, depth + 1)
                    except ValueError: pass
                i += n
            elif w == 1: i += 8
            elif w == 5: i += 4
            else: raise ValueError
    i = 0
    try:
        while i < len(data):
            s = i; n, i = rv(data, i); found.append((s, i, n))
            info_end = i + n; sizes = []
            j = i
            while j < info_end:
                key, j = rv(data, j); w = key & 7
                if w == 0: _, j = rv(data, j)
                elif w == 2:
                    m, j = rv(data, j)
                    if key >> 3 == 2:
                        q = j
                        while q < j + m:
                            kk, q = rv(data, q); ww = kk & 7
                            if ww == 0:
                                sq = q; val, q = rv(data, q)
                                if kk >> 3 == 3: sizes.append(val); found.append((sq, q, val))
                            elif ww == 2: mm, q = rv(data, q); q += mm
                            elif ww == 1: q += 8
                            else: q += 4
                    j += m
                elif w == 1: j += 8
                else: j += 4
            i = info_end
            for size in sizes:
                try: fields(i, i + size, 0)
                except ValueError: pass
                i += size
    except (ValueError, IndexError):
        pass
    return found

EXTREMES = [0, 1, 127, 128, 255, 65535, 65536, 1 << 24, (1 << 31) - 1, 1 << 31, 1 << 32, (1 << 63) - 1, 1 << 63, (1 << 64) - 1]
def value(rnd, old):
    r = rnd.random()
    if r < 0.5: return rnd.choice(EXTREMES)
    if r < 0.8: return max(0, old + rnd.choice([-2, -1, 1, 2, 7, 64, 4096]))
    return rnd.getrandbits(rnd.choice([8, 16, 32, 64]))

def mutate(rnd, raw):
    """One structural change to the bytes of one .iwa; returns the new bytes and the kind of change."""
    bl = blocks(raw)
    kind = rnd.choice(['blocco-lunghezza', 'snappy-annunciato', 'campo', 'campo', 'campo', 'campo', 'blocchi', 'troncato'])
    if kind == 'blocco-lunghezza' and bl:
        k = rnd.randrange(len(bl)); out = bytearray()
        for i, b in enumerate(bl):
            n = len(b) if i != k else min(value(rnd, len(b)), (1 << 24) - 1)
            out += bytes([0]) + n.to_bytes(3, 'little') + b
        return bytes(out), kind
    if kind == 'snappy-annunciato' and bl:
        k = rnd.randrange(len(bl)); b = bl[k]
        _, i = rv(b, 0); bl[k] = wv(value(rnd, len(snappy(b)))) + b[i:]
        return b''.join(header(x) for x in bl), kind
    data = b''.join(snappy(b) for b in bl)
    if kind == 'blocchi':
        how = rnd.choice(['minuscoli', 'ripetuti', 'tolto', 'vuoti'])
        if how == 'minuscoli': return encode(data, rnd.choice([1, 2, 7, 16])), kind + '-' + how
        if how == 'ripetuti' and bl: k = rnd.randrange(len(bl)); return b''.join(header(x) for x in bl[:k + 1] + [bl[k]] * rnd.choice([2, 50, 1000]) + bl[k + 1:]), kind + '-' + how
        if how == 'tolto' and len(bl) > 1: k = rnd.randrange(len(bl)); return b''.join(header(x) for i, x in enumerate(bl) if i != k), kind + '-' + how
        return raw + header(b'\x00') * rnd.choice([1, 1000, 5000]), kind + '-vuoti'
    if kind == 'troncato':
        cut = rnd.randrange(max(len(raw), 1)); return raw[:cut], kind
    spots = varints(data)
    if not spots: return raw[:len(raw) // 2], 'troncato'
    s, e, old = rnd.choice(spots)
    new = data[:s] + wv(value(rnd, old)) + data[e:]
    return encode(new), kind

def mutant(rnd, src, path):
    z = zipfile.ZipFile(src)
    names = [n for n in z.namelist() if n.startswith('Index/') and n.endswith('.iwa')]
    main = [n for n in names if n.endswith(('Document.iwa', 'DocumentStylesheet.iwa', 'Tile.iwa')) or '/Tile' in n or 'Slide' in n or 'DataList' in n]
    target = rnd.choice(main if main and rnd.random() < 0.7 else names)
    data, kind = mutate(rnd, z.read(target))
    out = zipfile.ZipFile(path, 'w', zipfile.ZIP_STORED)
    for info in z.infolist(): out.writestr(info, data if info.filename == target else z.read(info.filename))
    out.close()
    return kind

def run(path, test):
    p = subprocess.Popen([binary, test, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    peak, start, state = 0.0, time.time(), 'ok'
    while p.poll() is None:
        peak = max(peak, memory_mb(p.pid))
        if peak > 6000: p.kill(); state = 'oltre-ram'
        elif time.time() - start > 30: p.kill(); state = 'oltre-tempo'
        time.sleep(0.02)
    return p.returncode, time.time() - start, peak, state

TESTS = {'.pages': '--test-pages-read', '.key': '--test-keynote-read', '.numbers': '--test-numbers-read'}
lock = threading.Lock()
for src in files:
    ext = os.path.splitext(src)[1]; test = TESTS[ext]
    stats = {'letti': 0, 'rifiutati': 0, 'arresti': 0, 'oltre10s': 0, 'oltre500MB': 0}
    peak_all, slow_all, kinds = 0.0, 0.0, {}
    def one(n):
        global peak_all, slow_all
        rnd = random.Random(seed * 1_000_003 + n)
        path = os.path.join(work, 'm%d%s' % (n, ext))
        kind = mutant(rnd, src, path)
        rc, secs, peak, state = run(path, test)
        bad = []
        if state == 'ok' and rc not in (0, 1): bad.append('arresti')     # a signal, or an exit other than read/refused
        if secs > 10 or state == 'oltre-tempo': bad.append('oltre10s')
        if peak > 500 or state == 'oltre-ram': bad.append('oltre500MB')
        with lock:
            stats['letti' if rc == 0 and state == 'ok' else 'rifiutati'] += 1
            for b in set(bad): stats[b] += 1
            peak_all = max(peak_all, peak); slow_all = max(slow_all, secs)
            if bad: kinds[kind] = kinds.get(kind, 0) + 1
        if bad: os.replace(path, os.path.join(keep, '%s-m%d-%s%s' % ('-'.join(sorted(set(bad))), n, kind, ext)))
        else: os.remove(path)
    with ThreadPoolExecutor(jobs) as pool: list(pool.map(one, range(count)))
    print('%s (%s): %d mutanti, letti %d, rifiutati %d, arresti %d, oltre 10 s %d, oltre 500 MB %d; picco %.0f MB, il più lento %.1f s%s'
          % (os.path.basename(src), test, count, stats['letti'], stats['rifiutati'], stats['arresti'], stats['oltre10s'], stats['oltre500MB'],
             peak_all, slow_all, ('; tipi: ' + ', '.join('%s %d' % kv for kv in sorted(kinds.items()))) if kinds else ''))
    sys.stdout.flush()
print('mutanti problematici in', keep)
