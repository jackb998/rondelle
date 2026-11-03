import sys, re, zlib
# Canaries in the raw bytes and in every Flate stream (PDF): prints the distinct ones found, or "0".
pat = re.compile(rb'CNRY[A-Z]+|45,25\.926[0-9]N|12,20\.736[0-9]E')
for p in sys.argv[1:]:
    d = open(p, 'rb').read()
    found = set(pat.findall(d))
    if p.lower().endswith('.pdf'):
        for m in re.finditer(rb'stream\r?\n', d):
            try: found |= set(pat.findall(zlib.decompressobj().decompress(d[m.end():m.end() + 50_000_000])))
            except Exception: pass
    print(len(found), ' '.join(sorted(x.decode() for x in found)))
