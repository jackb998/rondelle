#!/usr/bin/python3 -I
# mkoffice.py OUT: off.docx, off.xlsx, off.pptx with everything «Rimuovi metadati» touches: core, app and custom
# properties, a thumbnail, Word's list of people, comments, a picture, customXml (an item, its properties and their
# relationship, an Override) and a Word field bound to it. Standard library only.
import os, struct, sys, zipfile, zlib

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PKG = 'http://schemas.openxmlformats.org/package/2006/relationships'
STORE = '{6E4E1D2A-0000-4C1A-9A0B-000000000001}'

def png():
    raw = b''.join(b'\0' + bytes((x * 7 + y) & 255 for x in range(16 * 3)) for y in range(16))
    def ch(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', 16, 16, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b'')

def rels(items):
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="%s">' % PKG
            + ''.join('<Relationship Id="%s" Type="%s" Target="%s"%s/>' % (i, t, g, ' TargetMode="External"' if e else '') for i, t, g, e in items)
            + '</Relationships>')

def types(overrides):
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>'
            '<Default Extension="jpeg" ContentType="image/jpeg"/>'
            + ''.join('<Override PartName="/%s" ContentType="%s"/>' % o for o in overrides) + '</Types>')

COMMON = {
    'docProps/core.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>OFF-CREATOR</dc:creator><cp:lastModifiedBy>OFF-LASTMOD</cp:lastModifiedBy></cp:coreProperties>',
    'docProps/app.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Company>OFF-COMPANY</Company></Properties>',
    'docProps/custom.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="P"><vt:lpwstr>OFF-CUSTOM</vt:lpwstr></property></Properties>',
    'customXml/item1.xml': '<?xml version="1.0"?><root><owner>OFF-CUSTOMXML Mario Rossi</owner></root>',
    'customXml/itemProps1.xml': '<?xml version="1.0" encoding="UTF-8" standalone="no"?><ds:datastoreItem ds:itemID="%s" xmlns:ds="http://schemas.openxmlformats.org/officeDocument/2006/customXml"><ds:schemaRefs/></ds:datastoreItem>' % STORE,
    'customXml/_rels/item1.xml.rels': rels([('rId1', R + '/customXmlProps', 'itemProps1.xml', False)]),
}
COMMON_OVER = [('docProps/core.xml', 'application/vnd.openxmlformats-package.core-properties+xml'),
               ('docProps/app.xml', 'application/vnd.openxmlformats-officedocument.extended-properties+xml'),
               ('docProps/custom.xml', 'application/vnd.openxmlformats-officedocument.custom-properties+xml'),
               ('customXml/itemProps1.xml', 'application/vnd.openxmlformats-officedocument.customXmlProperties+xml')]

def package(name, main, main_type, parts, overrides, main_rels):
    z = zipfile.ZipFile(os.path.join(out, name), 'w', zipfile.ZIP_DEFLATED)
    z.writestr('[Content_Types].xml', types(COMMON_OVER + [(main, main_type)] + overrides))
    z.writestr('_rels/.rels', rels([('rId1', R + '/officeDocument', main, False),
                                    ('rId2', PKG + '/metadata/core-properties', 'docProps/core.xml', False),
                                    ('rId3', R + '/extended-properties', 'docProps/app.xml', False),
                                    ('rId4', R + '/custom-properties', 'docProps/custom.xml', False),
                                    ('rId5', PKG + '/metadata/thumbnail', 'docProps/thumbnail.jpeg', False)]))
    folder, base = main.rsplit('/', 1)
    z.writestr('%s/_rels/%s.rels' % (folder, base), rels(main_rels + [('rIdX', R + '/customXml', '../customXml/item1.xml', False)]))
    for k, v in list(COMMON.items()) + list(parts.items()): z.writestr(k, v)
    z.writestr('docProps/thumbnail.jpeg', b'\xff\xd8\xff\xd9')
    z.close()

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
package('off.docx', 'word/document.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml', {
    'word/document.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="%s" xmlns:r="%s"><w:body>'
        '<w:p><w:r><w:t>Testo del documento OFF</w:t></w:r></w:p>'
        '<w:p><w:commentRangeStart w:id="0"/><w:r><w:t>Commentato</w:t></w:r><w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r></w:p>'
        '<w:sdt><w:sdtPr><w:dataBinding w:storeItemID="%s" w:xpath="/root/owner"/></w:sdtPr><w:sdtContent><w:p><w:r><w:t>Campo collegato OFF</w:t></w:r></w:p></w:sdtContent></w:sdt>'
        '</w:body></w:document>' % (W, R, STORE),
    'word/comments.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:comments xmlns:w="%s"><w:comment w:id="0" w:author="OFF-AUTHOR" w:initials="OA"><w:p><w:r><w:t>nota</w:t></w:r></w:p></w:comment></w:comments>' % W,
    'word/people.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml"><w15:person w15:author="OFF-AUTHOR"/></w15:people>',
    'word/media/image1.png': png(),
}, [('word/comments.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml'),
    ('word/people.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.people+xml')],
    [('rId1', R + '/comments', 'comments.xml', False), ('rId2', 'http://schemas.microsoft.com/office/2011/relationships/people', 'people.xml', False),
     ('rId3', R + '/image', 'media/image1.png', False)])

package('off.xlsx', 'xl/workbook.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml', {
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="%s"><sheets><sheet name="Foglio1" sheetId="1" r:id="rId1"/></sheets></workbook>' % R,
    'xl/worksheets/sheet1.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>OFF uno</t></is></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>',
}, [('xl/worksheets/sheet1.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml')],
    [('rId1', R + '/worksheet', 'worksheets/sheet1.xml', False)])

P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
package('off.pptx', 'ppt/presentation.xml', 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml', {
    'ppt/presentation.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation xmlns:p="%s" xmlns:r="%s"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/></p:presentation>' % (P, R),
    'ppt/slides/slide1.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:p="%s" xmlns:a="%s" xmlns:r="%s"><p:cSld><p:spTree><p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="900000"/></a:xfrm></p:spPr><p:txBody><a:p><a:r><a:rPr sz="4400"/><a:t>Diapositiva OFF</a:t></a:r></a:p></p:txBody></p:sp>'
        '<p:pic><p:blipFill><a:blip r:embed="rId1"/></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="1000000"/><a:ext cx="1000000" cy="1000000"/></a:xfrm></p:spPr></p:pic></p:spTree></p:cSld></p:sld>' % (P, A, R),
    'ppt/slides/_rels/slide1.xml.rels': rels([('rId1', R + '/image', '../media/image1.png', False)]),
    'ppt/media/image1.png': png(),
}, [('ppt/slides/slide1.xml', 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml')],
    [('rId1', R + '/slide', 'slides/slide1.xml', False)])
