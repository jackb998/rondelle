#!/usr/bin/python3 -I
# mkdocs.py OUT KIND N: documents built to expand on import, inside Rondelle's size limits. Standard library only.
import os, plistlib, random, struct, sys, zipfile

LINE = 'il gatto dorme sul tavolo mentre la pioggia cade fuori dalla vecchia casa'
MB = 1_000_000

def repeat(unit, limit):
    return unit * (limit // len(unit))

def rtf(body):
    return r'{\rtf1\ansi\ansicpg1252{\fonttbl\f0 Helvetica;}' + '\n' + body + '}'

ODT = ('<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
       'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" office:version="1.2"><office:body><office:text>')
ODT_END = '</office:text></office:body></office:document-content>'

def odt(out, body):
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/vnd.oasis.opendocument.text')
        z.writestr('content.xml', ODT + body + ODT_END)

def docx(out, body):
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                   '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                   '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr('word/document.xml', '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + body + '</w:body></w:document>')

def html(body):
    return '<!doctype html><meta charset="utf-8"><body>' + body + '</body>'

def archive(out, data, frames=()):
    def resource(text):
        return {'WebResourceData': text.encode(), 'WebResourceFrameName': '', 'WebResourceMIMEType': 'text/html',
                'WebResourceTextEncodingName': 'UTF-8', 'WebResourceURL': 'about:blank'}
    plist = {'WebMainResource': resource(data)}
    if frames:
        plist['WebSubframeArchives'] = [{'WebMainResource': resource(f)} for f in frames]
    with open(out, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)

def build(out, kind, n):
    if kind == 'odt-testo':        # N MB of XML of plain paragraphs
        odt(out, repeat('<text:p>' + LINE + '</text:p>', n * MB))
    elif kind == 'odt-stili':      # N MB of one-letter styled runs
        odt(out, '<text:p>' + repeat('<text:span>a</text:span>', n * MB) + '</text:p>')
    elif kind == 'odt-tab':        # N MB of one-cell tables
        odt(out, repeat('<table:table><table:table-row><table:table-cell><text:p>a</text:p></table:table-cell></table:table-row></table:table>', n * MB))
    elif kind == 'odt-bugiardo':   # as odt-testo, but the central directory says the XML is 1 KB
        odt(out, repeat('<text:p>' + LINE + '</text:p>', n * MB))
        data = bytearray(open(out, 'rb').read())
        at = data.find(b'PK\x01\x02')
        while at >= 0:
            data[at + 24:at + 28] = struct.pack('<I', 1000)
            at = data.find(b'PK\x01\x02', at + 4)
        open(out, 'wb').write(data)
    elif kind == 'odt-esatto':     # content.xml unpacks to exactly N bytes
        head = ODT + '<text:p>' + LINE + '</text:p>'
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            z.writestr(zipfile.ZipInfo('mimetype'), 'application/vnd.oasis.opendocument.text')
            z.writestr('content.xml', head + ' ' * (n - len(head) - len(ODT_END)) + ODT_END)
    elif kind == 'odt-foto':       # one line of text and N MB of what doesn't compress
        rng = random.Random(3)
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr(zipfile.ZipInfo('mimetype'), 'application/vnd.oasis.opendocument.text')
            z.writestr('content.xml', ODT + '<text:p>' + LINE + '</text:p>' + ODT_END)
            z.writestr('Pictures/foto.jpg', rng.randbytes(n * MB))
    elif kind == 'docx-testo':     # N MB of XML of plain paragraphs
        docx(out, repeat('<w:p><w:r><w:t>' + LINE + '</w:t></w:r></w:p>', n * MB))
    elif kind in ('web-tab', 'web-stili', 'html-tab'):   # N bytes of one-cell tables or styled letters
        unit = '<b>a</b><i>b</i>' if kind == 'web-stili' else '<table><tr><td>a</td></tr></table>'
        page = html(repeat(unit, n))
        if kind == 'html-tab':
            open(out, 'w').write(page)
        else:
            archive(out, page)
    elif kind == 'web-cornici':    # a small main page and 3 frames of N paragraphs each
        archive(out, html('<p>' + LINE + '</p>'), [html('<p>a</p>' * n)] * 3)
    elif kind == 'web-elementi':   # exactly N elements, in a web archive
        archive(out, '<p>a</p>' * n)
    elif kind == 'html-elementi':  # exactly N elements, in a page
        open(out, 'w').write('<p>a</p>' * n)
    elif kind == 'rtf-nest':       # N bytes of nested tables
        open(out, 'w').write(rtf(repeat(r'\itap2 a\nestcell\nestrow\cell\row\trowd\cellx1000' + '\n', n)))
    elif kind == 'rtf-celle':      # exactly N cells
        open(out, 'w').write(rtf(r'\trowd\cellx1000 ' + r'a\cell ' * n + r'\row'))
    elif kind == 'rtfd-celle':     # exactly N cells, in a package
        os.makedirs(out, exist_ok=True)
        open(os.path.join(out, 'TXT.rtf'), 'w').write(rtf(r'\trowd\cellx1000 ' + r'a\cell ' * n + r'\row'))
    else:
        sys.exit('tipo sconosciuto: ' + kind)

if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2], int(sys.argv[3]))
