#!/usr/bin/python3 -I
# mkpdfword.py OUT KIND [ARG]: PDFs for the PDF → Word conversion. --word OUT KIND: DOCX and ODT for Word → PDF, some hostile.
# --leggi FILE.docx prints what a DOCX holds as key=value; --pdf, --pdf-info, --testo, --pdf-immagini check a resulting PDF.
# Standard library only.
import os, re, struct, sys, zipfile, zlib
from xml.dom import minidom
import importlib.util
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('mkpdftext', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mkpdftext.py'))
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
PDF, FONT = base.PDF, base.FONT

LINE = 'il gatto dorme sul tavolo mentre la pioggia cade fuori dalla vecchia casa, e nessuno in paese se ne accorge'
A4 = (595, 842)

def page_doc(pdf, out, pages, size=A4, rotate=None):
    tree = pdf.reserve(); kids = []
    for contents, res in pages:
        r = b' /Rotate %d' % rotate if rotate else b''
        kids.append(pdf.add(b'<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R /Resources %s%s >>' % (tree, size[0], size[1], contents, res, r)))
    pdf.objects[tree - 1] = b'<< /Type /Pages /Count %d /Kids [%s] >>' % (len(kids), b' '.join(b'%d 0 R' % k for k in kids))
    pdf.write(out, pdf.add(b'<< /Type /Catalog /Pages %d 0 R >>' % tree))

def lines(text, n, x=56, y=780, size=11, leading=14):
    body = b'BT /F1 %d Tf %d TL %d %d Td\n' % (size, leading, x, y)
    for _ in range(n):
        body += b'(' + text + b") '\n"
    return body + b'ET\n'

def rgb_image(pdf, w=64, h=64, extra=b''):
    return pdf.stream(bytes((x * 4 % 256, y * 4 % 256, 128)[c] for y in range(h) for x in range(w) for c in range(3)),
                      b'/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 %s' % (w, h, extra))

def wrapped(n):
    """N lines cut from one long text, as a paragraph is."""
    words = (LINE + ' ') * 8
    return [words[i * 85:(i + 1) * 85].encode() for i in range(n)]

def paragraph_page(pdf, res_extra=b'', after=b''):
    font = pdf.add(FONT)
    body = b'BT /F1 11 Tf 14 TL 56 780 Td\n'
    for l in wrapped(10):
        body += b'(' + l + b") '\n"
    return font, body + b'ET\n' + after

def build(out, kind, arg):
    pdf = PDF()
    if kind == 'normale':
        pages = []
        font = pdf.add(FONT)
        image = rgb_image(pdf)
        for i in range(int(arg or 2)):
            body = b'BT /F1 11 Tf 14 TL 56 780 Td\n' + b''.join(b'(' + l + b") '\n" for l in wrapped(10)) + b'ET\n'
            body += b'q 120 0 0 120 200 300 cm /I Do Q\n0.8 0.1 0.1 rg 56 200 300 20 re f\n'
            pages.append((pdf.stream(body), b'<< /Font << /F1 %d 0 R >> /XObject << /I %d 0 R >> >>' % (font, image)))
        return page_doc(pdf, out, pages)
    font = pdf.add(FONT)
    res = b'<< /Font << /F1 %d 0 R >> >>' % font
    if kind == 'orizzontale':
        return page_doc(pdf, out, [(pdf.stream(lines(LINE[:60].encode(), 3, y=500)), res)], size=(842, 595))
    if kind == 'ruotata':
        return page_doc(pdf, out, [(pdf.stream(lines(LINE[:60].encode(), 3)), res)], rotate=90)
    if kind == 'colonne':
        body = b''
        for i, y in enumerate((700, 680)):
            body += b'BT /F1 11 Tf 56 %d Td (Voce%d) Tj ET BT /F1 11 Tf 250 %d Td (100) Tj ET BT /F1 11 Tf 400 %d Td (200) Tj ET\n' % (y, i, y, y)
        return page_doc(pdf, out, [(pdf.stream(body), res)])
    if kind == 'indicizzata':
        table = bytes([255, 0, 0, 0, 0, 255])
        image = pdf.stream(bytes((x + y) % 2 for y in range(32) for x in range(32)),
                           b'/Type /XObject /Subtype /Image /Width 32 /Height 32 /BitsPerComponent 8 /ColorSpace [/Indexed /DeviceRGB 1 <%s>]' % table.hex().encode())
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /I %d 0 R >> >>' % (font, image)
        return page_doc(pdf, out, [(pdf.stream(lines(b'testo', 1) + b'q 100 0 0 100 200 300 cm /I Do Q\n'), res)])
    if kind == 'trasparente':
        mask = pdf.stream(bytes(x * 8 % 256 for y in range(32) for x in range(32)),
                          b'/Type /XObject /Subtype /Image /Width 32 /Height 32 /ColorSpace /DeviceGray /BitsPerComponent 8')
        image = rgb_image(pdf, 32, 32, b'/SMask %d 0 R' % mask)
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /I %d 0 R >> >>' % (font, image)
        return page_doc(pdf, out, [(pdf.stream(lines(b'testo', 1) + b'q 100 0 0 100 200 300 cm /I Do Q\n'), res)])
    if kind == 'scansione':
        image = rgb_image(pdf, 64, 64)
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /I %d 0 R >> >>' % (font, image)
        return page_doc(pdf, out, [(pdf.stream(b'q 595 0 0 842 0 0 cm /I Do Q\n3 Tr\n' + lines(b'testo riconosciuto', 2)), res)])
    if kind == 'caratteri':
        return page_doc(pdf, out, [(pdf.stream(lines(b'a & b < c > d " e \' \\) f', 2)), res)])
    if kind == 'senzatesto':
        image = rgb_image(pdf)
        res = b'<< /XObject << /I %d 0 R >> >>' % image
        return page_doc(pdf, out, [(pdf.stream(b'q 100 0 0 100 200 300 cm /I Do Q\n'), res)])
    if kind == 'conjpeg':
        jpeg = open(arg, 'rb').read()
        w, h = 0, 0
        i = 2
        while i < len(jpeg):
            size = struct.unpack('>H', jpeg[i + 2:i + 4])[0]
            if jpeg[i + 1] in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack('>HH', jpeg[i + 5:i + 9])
                break
            i += 2 + size
        # EXIF with a position, placed right after the JPEG's start
        app1 = b'Exif\0\0MM\0*\0\0\0\x08\0\0' + b'CANARINO-POSIZIONE-GPS' * 4
        jpeg = jpeg[:2] + b'\xff\xe1' + struct.pack('>H', len(app1) + 2) + app1 + jpeg[2:]
        image = pdf.add(b'<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n' % (w, h, len(jpeg)) + jpeg + b'\nendstream')
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /I %d 0 R >> >>' % (font, image)
        return page_doc(pdf, out, [(pdf.stream(lines(b'testo', 1) + b'q 300 0 0 200 100 300 cm /I Do Q\n'), res)])
    if kind == 'segreti':
        # What a redaction must take away, on page 1, each with its own marker; page 2 stays. In every place text hides:
        # shown, hidden, in a form, in a picture's bytes, in a note. In the document: its information and metadata.
        form = pdf.stream(b'BT /F1 11 Tf 56 600 Td (SEGRETOFORMA) Tj ET\n', b'/Type /XObject /Subtype /Form /BBox [0 0 595 842] /Resources << /Font << /F1 %d 0 R >> >>' % font)
        image = pdf.stream(b'SEGRETOIMMAGINE' + bytes(64 * 64 * 3 - 15), b'/Type /XObject /Subtype /Image /Width 64 /Height 64 /ColorSpace /DeviceRGB /BitsPerComponent 8')
        note = pdf.add(b'<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (SEGRETONOTA) >>')
        res1 = b'<< /Font << /F1 %d 0 R >> /XObject << /X %d 0 R /I %d 0 R >> >>' % (font, form, image)
        body = b'BT /F1 11 Tf 56 700 Td (visibile SEGRETOTESTO visibile) Tj ET\n3 Tr BT /F1 11 Tf 56 680 Td (SEGRETONASCOSTO) Tj ET 0 Tr\n/X Do\nq 64 0 0 64 56 400 cm /I Do Q\n'
        c1 = pdf.stream(body)
        c2 = pdf.stream(lines(b'pagina due PAROLA intatta', 1, y=700))
        meta = pdf.add(b'<< /Type /Metadata /Subtype /XML /Length 15 >>\nstream\nSEGRETOMETADATI\nendstream')
        info = pdf.add(b'<< /Title (SEGRETOTITOLO) /Author (SEGRETOAUTORE) >>')
        tree = pdf.reserve()
        p1 = pdf.add(b'<< /Type /Page /Parent %d 0 R /MediaBox [0 0 595 842] /Contents %d 0 R /Resources %s /Annots [%d 0 R] >>' % (tree, c1, res1, note))
        p2 = pdf.add(b'<< /Type /Page /Parent %d 0 R /MediaBox [0 0 595 842] /Contents %d 0 R /Resources %s >>' % (tree, c2, res))
        pdf.objects[tree - 1] = b'<< /Type /Pages /Count 2 /Kids [%d 0 R %d 0 R] >>' % (p1, p2)
        root = pdf.add(b'<< /Type /Catalog /Pages %d 0 R /Metadata %d 0 R >>' % (tree, meta))
        pdf.write(out, root)
        data = open(out, 'rb').read().replace(b'/Root %d 0 R' % root, b'/Root %d 0 R /Info %d 0 R' % (root, info))
        open(out, 'wb').write(data)
        return
    if kind == 'ruotata2':
        return page_doc(pdf, out, [(pdf.stream(lines(b'testo sulla pagina ruotata', 1, y=700)), res)], rotate=90)
    sys.exit('tipo sconosciuto: ' + kind)

def canary(path, word):
    # In the raw bytes, or in any Flate stream: where a word survives even if no reader shows it.
    data = open(path, 'rb').read()
    word = word.encode()
    if word in data: return 1
    for m in re.finditer(rb'stream\r?\n', data):
        try:
            if word in zlib.decompressobj().decompress(data[m.end():]): return 1
        except zlib.error:
            pass
    return 0

# MARK: reading a DOCX

def leggi(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    xml = z.read('word/document.xml').decode()
    minidom.parseString(xml)
    size = re.findall(r'w:pgSz w:w="(\d+)" w:h="(\d+)"', xml)
    media = [n for n in names if n.startswith('word/media/') and not n.endswith('/')]
    blob = b''.join(z.read(n) for n in media)
    text = ''.join(re.findall(r'<w:t [^>]*>([^<]*)</w:t>', xml))
    out = ['xml=ok', 'pagine=%d' % (xml.count('pageBreakBefore') + 1), 'pgsz=%sx%s' % size[-1] if size else 'pgsz=?',
           'righe=20/paragrafi=%d' % xml.count('<w:p>') if xml.count('<w:p>') else 'paragrafi=0',
           'immagini=%d' % len([n for n in media if 'immagine' in n]), 'disegni=%d' % len([n for n in media if 'disegni' in n]),
           'docprops=%d' % len([n for n in names if n.startswith('docProps')]), 'tab=%d' % xml.count('<w:tab/>'),
           'testo=%s' % ('si' if text.strip() else 'no'), 'exif=%d' % (blob.count(b'Exif') + blob.count(b'CANARINO'))]
    print(' '.join(out))

# MARK: Word and ODT

PNG = None
def png():
    w = h = 40
    raw = b''.join(b'\0' + bytes((200, 30, 30)) * w for _ in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

def bomb_png(side=30000):
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    z = zlib.compressobj(9)
    row = b'\0' + bytes(side * 3)
    data = b''.join(z.compress(row) for _ in range(side)) + z.flush()
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', side, side, 8, 2, 0, 0, 0)) + chunk(b'IDAT', data) + chunk(b'IEND', b'')

W_NS = ('xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"')
def pict(rid):
    return ('<w:r><w:drawing><wp:inline><wp:extent cx="1270000" cy="1270000"/><wp:docPr id="1" name="f"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>'
            '<pic:nvPicPr><pic:cNvPr id="1" name="f"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="%s"/></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>' % rid)

def word(out, kind):
    if kind == 'odt':
        content = ('<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
                   'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" office:version="1.2"><office:body><office:text>'
                   '<text:p>Testo prima</text:p><text:p><draw:frame svg:width="4cm" svg:height="4cm"><draw:image xlink:href="Pictures/f.png"/></draw:frame></text:p><text:p>Testo dopo</text:p></office:text></office:body></office:document-content>')
        styles = ('<?xml version="1.0" encoding="UTF-8"?><office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.2">'
                  '<office:automatic-styles><style:page-layout style:name="p"><style:page-layout-properties fo:page-width="14.8cm" fo:page-height="21cm" fo:margin-top="1cm" fo:margin-bottom="1cm" fo:margin-left="1cm" fo:margin-right="1cm"/></style:page-layout></office:automatic-styles></office:document-styles>')
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr(zipfile.ZipInfo('mimetype'), 'application/vnd.oasis.opendocument.text')
            z.writestr('content.xml', content); z.writestr('styles.xml', styles); z.writestr('Pictures/f.png', png())
        return
    section = '<w:sectPr><w:pgSz w:w="8391" w:h="11906"/><w:pgMar w:top="567" w:right="567" w:bottom="567" w:left="567"/></w:sectPr>'
    target = 'media/f.png'
    mode = ''
    data = png()
    body = '<w:p><w:r><w:t>Testo salvo</w:t></w:r></w:p>'
    if kind == 'normale':
        body += '<w:p>%s</w:p><w:p><w:r><w:br w:type="page"/><w:t>Seconda pagina</w:t></w:r></w:p>' % pict('rId9')
    elif kind == 'fuori':       # a picture outside the package
        target = '../../../../../../etc/hosts'
        body += '<w:p>%s</w:p>' % pict('rId9')
    elif kind == 'web':         # a picture on the web
        target = 'http://127.0.0.1:9/spia.png'; mode = ' TargetMode="External"'
        body += '<w:p>%s</w:p>' % pict('rId9')
    elif kind == 'bomba':       # a small file that claims a huge picture
        data = bomb_png()
        body += '<w:p>%s</w:p>' % pict('rId9')
    elif kind == 'enorme':      # a page no paper has, and margins wider than it
        section = '<w:sectPr><w:pgSz w:w="99999999" w:h="99999999"/><w:pgMar w:top="-5" w:right="99999" w:bottom="0" w:left="0"/></w:sectPr>'
    elif kind == 'finto':       # not a picture, and the marks in the text itself
        data = b'non sono una foto'
        body += '<w:p>%s</w:p><w:p><w:r><w:t>7  </w:t></w:r></w:p>' % pict('rId9')
    elif kind == 'molte':       # far more pictures than a document holds
        body += '<w:p>%s</w:p>' % (pict('rId9') * 5000)
    doc = '<?xml version="1.0" encoding="UTF-8"?><w:document %s><w:body>%s%s</w:body></w:document>' % (W_NS, body, section)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr('word/_rels/document.xml.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="%s"%s/></Relationships>' % (target, mode))
        z.writestr('word/document.xml', doc)
        z.writestr('word/media/f.png', data)

# MARK: reading a resulting PDF: raw bytes only

def info(path):
    data = open(path, 'rb').read()
    pages = len(re.findall(rb'/Type\s*/Page\b', data))
    box = re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)', data)
    images = len(re.findall(rb'/Subtype\s*/Image', data))
    return pages, (float(box[1]), float(box[2])) if box else (0, 0), images

if __name__ == '__main__':
    a = sys.argv[1:]
    if a[0] == '--leggi': leggi(a[1])
    elif a[0] == '--word': word(a[1], a[2])
    elif a[0] == '--pdf':
        p, box, n = info(a[1]); want = int(a[2]) if len(a) > 2 else 2
        print(int(p == want and n >= 1 and abs(box[0] - (420 if want == 2 else 419.5)) < 2))
    elif a[0] == '--pdf-info': print(info(a[1]))
    elif a[0] == '--testo':
        print(int(os.path.exists(a[1]) and info(a[1])[0] >= 1))
    elif a[0] == '--pdf-immagini': print(info(a[1])[2])
    elif a[0] == '--canarino': print(canary(a[1], a[2]))
    else: build(a[0], a[1], a[2] if len(a) > 2 else None)
