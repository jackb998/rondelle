#!/usr/bin/python3 -I
# opcchk.py FILE: the integrity of an Office package (OPC). Prints «ok» or the problems, one per line:
# a relationship to a part that doesn't exist, a part without a content type, an Override for a missing part,
# a customXml part left, XML that doesn't parse. Standard library only.
import posixpath, sys, zipfile
import xml.etree.ElementTree as ET

z = zipfile.ZipFile(sys.argv[1])
names = {n for n in z.namelist() if not n.endswith('/')}
lower = {n.lower(): n for n in names}
problems = []
try:
    types = ET.fromstring(z.read('[Content_Types].xml'))
except Exception as e:
    print('[Content_Types].xml illeggibile: %s' % e); sys.exit(1)
defaults = {e.get('Extension', '').lower() for e in types if e.tag.endswith('Default')}
overrides = {e.get('PartName', '').lstrip('/').lower() for e in types if e.tag.endswith('Override')}
for o in sorted(overrides):
    if o not in lower: problems.append('Override orfano: /%s' % o)
for n in sorted(names):
    if n == '[Content_Types].xml': continue
    ext = n.rsplit('.', 1)[-1].lower() if '.' in n.rsplit('/', 1)[-1] else ''
    if n.lower() not in overrides and ext not in defaults: problems.append('parte senza tipo: %s' % n)
    if n.lower().startswith('customxml/'): problems.append('customXml rimasto: %s' % n)
    if ext in ('xml', 'rels'):
        try: ET.fromstring(z.read(n))
        except Exception as e: problems.append('XML illeggibile: %s (%s)' % (n, e))
for n in sorted(names):
    if not n.endswith('.rels'): continue
    folder = posixpath.dirname(posixpath.dirname(n))   # word/_rels/document.xml.rels → word
    try: root = ET.fromstring(z.read(n))
    except Exception: continue
    for r in root:
        if r.get('TargetMode') == 'External': continue
        t = r.get('Target', '')
        path = t.lstrip('/') if t.startswith('/') else posixpath.normpath(posixpath.join(folder, t))
        if path.lower() not in lower: problems.append('relazione verso una parte assente: %s → %s' % (n, t))
print('\n'.join(problems) if problems else 'ok')
sys.exit(1 if problems else 0)
