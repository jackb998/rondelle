#!/usr/bin/python3 -I
# mkvarint.py OUT: Pages, Keynote, Numbers and PPTX files whose length fields hold 2^31, 2^32, 2^63 and 2^64 − 1 (Snappy
# block size, archive info, message size, protobuf length) and PPTX arcs with a huge, very big or NaN angle: before
# 1.0.11.1 most of them stopped the app. Standard library only.
import os, sys, zipfile
out = sys.argv[1]
def varint(v):
    b = bytearray()
    while True:
        x = v & 0x7f; v >>= 7
        if v: b.append(x | 0x80)
        else: b.append(x); return bytes(b)
def lit(data):
    n = len(data) - 1
    if n < 60: return bytes([n << 2]) + data
    if n < 256: return bytes([60 << 2, n]) + data
    return bytes([61 << 2, n & 255, n >> 8]) + data
def snappy(payload, expected=None): return varint(len(payload) if expected is None else expected) + lit(payload)
def chunk(s): return bytes([0, len(s) & 255, len(s) >> 8 & 255, len(s) >> 16 & 255]) + s
def pkg(name, iwa):
    d = os.path.join(out, name, 'Index'); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'Document.iwa'), 'wb').write(iwa)
for label, v in [('2p31', 1 << 31), ('2p32', 1 << 32), ('2p63', 1 << 63), ('max', (1 << 64) - 1)]:
    pkg(f'snap_{label}.pages', chunk(snappy(b'\0', v)))                                   # Snappy expected
    pkg(f'arch_{label}.pages', chunk(snappy(varint(v) + b'\0')))                           # Archive info length
    info = b'\x08\x01' + b'\x12' + varint(len(b'\x18' + varint(v))) + b'\x18' + varint(v)    # id 1, MessageInfo.length = v
    pkg(f'msg_{label}.pages', chunk(snappy(varint(len(info)) + info)))                     # message size
    pb = b'\x0a' + varint(v) + b'\0'
    pkg(f'pb_{label}.pages', chunk(snappy(varint(len(pb)) + pb)))                          # protobuf length
    for ext in ('key', 'numbers'):
        z = zipfile.ZipFile(os.path.join(out, f'snap_{label}.{ext}'), 'w')
        z.writestr('Index/Document.iwa', chunk(snappy(b'\0', v))); z.close()
ct = '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'
pres = '<p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/></p:presentation>'
rels = '<Relationships><Relationship Id="rId1" Type="x/slide" Target="slides/slide1.xml"/></Relationships>'
for label, ang in [('huge', '1e300'), ('big', '600000000000'), ('nan', 'NaN')]:
    sp = ('<p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm><a:custGeom><a:pathLst><a:path w="100" h="100">'
          '<a:moveTo><a:pt x="0" y="0"/></a:moveTo><a:arcTo wR="50" hR="50" stAng="0" swAng="%s"/></a:path></a:pathLst></a:custGeom>'
          '<a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></p:spPr></p:sp>') % ang
    z = zipfile.ZipFile(os.path.join(out, f'arc_{label}.pptx'), 'w', zipfile.ZIP_DEFLATED)
    z.writestr('[Content_Types].xml', ct); z.writestr('ppt/presentation.xml', pres)
    z.writestr('ppt/_rels/presentation.xml.rels', rels)
    z.writestr('ppt/slides/slide1.xml', '<p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>' + sp + '</p:spTree></p:cSld></p:sld>'); z.close()
