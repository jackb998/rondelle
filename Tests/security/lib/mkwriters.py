#!/usr/bin/python3 -I
# mkwriters.py OUT: inputs for the writers at and past their caps (audit 1.0.11.2). Standard library only.
#   w1-38.pptx    300 slides, one picture of 38 MB on every slide (a small JPEG padded to that size: what costs
#                 memory is the bytes, read once per slide before 1.0.11.2)
#   w2-47.pptx    300 slides, one picture of 47 MB (past PptxReader.maxImagePart, 40 MB): left out at once
#   n-cap.csv     the biggest CSV of one column of numbers that NumbersWriter accepts (its estimate, mirrored below)
#   n-over.csv    one row more
#   n-65536.csv   65 536 rows × 91 columns of distinct short texts (6 M cells, under 50 MB), n-50.xlsx 50 sheets × 120 000 cells: refused
import os, struct, subprocess, sys, zipfile, zlib

out = sys.argv[1]; os.makedirs(out, exist_ok=True)

# NumbersWriter.estimatedBytes: per row, per number cell, per text cell, per distinct text; the budget for all sheets.
ROW, NUMBER = 1_100, 52
BUDGET = 32_000_000 - 2_000_000

def jpeg(size):
    # A 64 × 64 JPEG made by sips, then padding after its end up to `size` bytes (decoders stop at EOI).
    raw = b''.join(b'\0' + bytes((x * 4 + y) & 255 for x in range(64 * 3)) for y in range(64))
    def ch(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    png, jpg = os.path.join(out, 'small.png'), os.path.join(out, 'small.jpg')
    open(png, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
    subprocess.run(['/usr/bin/sips', '-s', 'format', 'jpeg', png, '--out', jpg], capture_output=True, check=True)
    data = open(jpg, 'rb').read(); os.remove(png); os.remove(jpg)
    pad = os.urandom(1 << 20)
    rest = size - len(data)
    return data + pad * (rest // len(pad)) + pad[:rest % len(pad)]

def pptx(name, n, image):
    z = zipfile.ZipFile(os.path.join(out, name), 'w', zipfile.ZIP_DEFLATED)
    z.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="jpg" ContentType="image/jpeg"/></Types>')
    z.writestr('ppt/presentation.xml', '<p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst>%s</p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/></p:presentation>'
               % ''.join('<p:sldId id="%d" r:id="rId%d"/>' % (256 + i, i + 1) for i in range(n)))
    z.writestr('ppt/_rels/presentation.xml.rels', '<Relationships>%s</Relationships>'
               % ''.join('<Relationship Id="rId%d" Type="x/slide" Target="slides/slide%d.xml"/>' % (i + 1, i + 1) for i in range(n)))
    z.writestr(zipfile.ZipInfo('ppt/media/image1.jpg'), image, compress_type=zipfile.ZIP_STORED)
    for i in range(n):
        z.writestr('ppt/slides/_rels/slide%d.xml.rels' % (i + 1), '<Relationships><Relationship Id="rIdI" Type="x/image" Target="../media/image1.jpg"/></Relationships>')
        z.writestr('ppt/slides/slide%d.xml' % (i + 1), '<p:sld xmlns:p="p" xmlns:a="a" xmlns:r="r"><p:cSld><p:spTree>'
                   '<p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="900000"/></a:xfrm></p:spPr><p:txBody><a:p><a:r><a:rPr sz="4400"/><a:t>Titolo %d</a:t></a:r></a:p></p:txBody></p:sp>'
                   '<p:pic><p:blipFill><a:blip r:embed="rIdI"/></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="1000000"/><a:ext cx="4572000" cy="3429000"/></a:xfrm></p:spPr></p:pic>'
                   '</p:spTree></p:cSld></p:sld>' % i)
    z.close()

pptx('w1-38.pptx', 300, jpeg(38_000_000))
pptx('w2-47.pptx', 300, jpeg(47_000_000))

rows = BUDGET // (ROW + NUMBER)
for name, count in (('n-cap.csv', rows), ('n-over.csv', rows + 1)):
    with open(os.path.join(out, name), 'w') as f:
        for r in range(count): f.write('%d\n' % r)

with open(os.path.join(out, 'n-65536.csv'), 'w') as f:
    for r in range(65536): f.write(','.join('t%x' % (r * 91 + c) for c in range(91)) + '\n')

z = zipfile.ZipFile(os.path.join(out, 'n-50.xlsx'), 'w', zipfile.ZIP_DEFLATED)
z.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
z.writestr('xl/workbook.xml', '<workbook xmlns:r="r"><sheets>%s</sheets></workbook>' % ''.join('<sheet name="F%d" sheetId="%d" r:id="rId%d"/>' % (i, i + 1, i + 1) for i in range(50)))
z.writestr('xl/_rels/workbook.xml.rels', '<Relationships>%s</Relationships>' % ''.join('<Relationship Id="rId%d" Target="worksheets/sheet%d.xml"/>' % (i + 1, i + 1) for i in range(50)))
for i in range(50):
    body = ''.join('<row r="%d">%s</row>' % (r + 1, ''.join('<c t="inlineStr"><is><t>f%dr%dc%d</t></is></c>' % (i, r, c) for c in range(50))) for r in range(2400))
    z.writestr('xl/worksheets/sheet%d.xml' % (i + 1), '<worksheet><sheetData>%s</sheetData></worksheet>' % body)
z.close()
print(rows)
