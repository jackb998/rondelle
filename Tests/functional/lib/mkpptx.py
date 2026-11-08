"""A small PowerPoint file for the tests: python3 -I mkpptx.py OUT.pptx [stored]
Two slides (and a hidden third) on a 16:9 master. Slide 1: a title and a body that take their place and size from the layout, a bulleted
list, a red rectangle, a picture and speaker notes. Slide 2: a table, a grouped text box and an arrow. Slide 3 is hidden (show=0); slide 1 has a hidden shape. The body placeholder of the layout is
a free-form panel (custGeom with guides and an arc) that the slides' body inherits. All text is made up."""
import struct, sys, zipfile, zlib

A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
NS = f'xmlns:a="{A}" xmlns:r="{R}" xmlns:p="{P}"'
H = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
REL = 'http://schemas.openxmlformats.org/package/2006/relationships'

def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
def png(w, h, rgb):
    raw = b''.join(b'\0' + bytes(rgb) * w for _ in range(h))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

def rels(items): return H + f'<Relationships xmlns="{REL}">' + ''.join(f'<Relationship Id="{i}" Type="{R}/{t}" Target="{g}"/>' for i, t, g in items) + '</Relationships>'
def tree(body): return '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>' + body + '</p:spTree>'
def xfrm(x, y, w, h): return f'<a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm>'
def ph(i, name, kind, idx, frame=None, text=''):
    sp = '<p:spPr>' + (xfrm(*frame) if frame else '') + '</p:spPr>'
    return (f'<p:sp><p:nvSpPr><p:cNvPr id="{i}" name="{name}"/><p:cNvSpPr/><p:nvPr><p:ph type="{kind}" idx="{idx}"/></p:nvPr></p:nvSpPr>{sp}'
            f'<p:txBody><a:bodyPr/><a:lstStyle/>{text}</p:txBody></p:sp>')
def para(t, extra='', rpr=''): return f'<a:p>{extra}<a:r><a:rPr lang="it-IT"{rpr}/><a:t>{t}</a:t></a:r></a:p>'

theme = H + f'<a:theme xmlns:a="{A}" name="Prova"><a:themeElements><a:clrScheme name="Prova"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F3864"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>' + ''.join(f'<a:accent{i}><a:srgbClr val="{c}"/></a:accent{i}>' for i, c in enumerate(['4472C4', 'ED7D31', 'A5A5A5', 'FFC000', '5B9BD5', '70AD47'], 1)) + '<a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Prova"><a:majorFont><a:latin typeface="Helvetica"/></a:majorFont><a:minorFont><a:latin typeface="Helvetica"/></a:minorFont></a:fontScheme><a:fmtScheme name="Prova"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>'

master = H + f'<p:sldMaster {NS}><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="F4F1E8"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>' + tree(
    ph(2, 'Titolo', 'title', 0, (609600, 274638, 10972800, 1143000)) + ph(3, 'Corpo', 'body', 1, (609600, 1600200, 10972800, 4525963))
    + '<p:sp><p:nvSpPr><p:cNvPr id="4" name="Barra"/><p:cNvSpPr/><p:nvPr userDrawn="1"/></p:nvSpPr><p:spPr>' + xfrm(0, 6600000, 12192000, 258000)
    + '<a:solidFill><a:srgbClr val="1F3864"/></a:solidFill></p:spPr></p:sp>') + '</p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="4000" b="1"><a:solidFill><a:schemeClr val="tx2"/></a:solidFill></a:defRPr></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="342900" indent="-342900"><a:buChar char="•"/><a:defRPr sz="2400"/></a:lvl1pPr></p:bodyStyle></p:txStyles></p:sldMaster>'
PANEL = ('<a:xfrm><a:off x="609600" y="1600200"/><a:ext cx="10972800" cy="4525963"/></a:xfrm><a:custGeom><a:avLst/><a:gdLst><a:gd name="x1" fmla="*/ 900000 w 1000000"/></a:gdLst><a:ahLst/><a:cxnLst/><a:rect l="0" t="0" r="r" b="b"/>'
         '<a:pathLst><a:path w="1000000" h="1000000"><a:moveTo><a:pt x="0" y="0"/></a:moveTo><a:lnTo><a:pt x="x1" y="0"/></a:lnTo><a:arcTo wR="100000" hR="100000" stAng="16200000" swAng="5400000"/>'
         '<a:lnTo><a:pt x="1000000" y="1000000"/></a:lnTo><a:lnTo><a:pt x="0" y="1000000"/></a:lnTo><a:close/></a:path></a:pathLst></a:custGeom><a:solidFill><a:srgbClr val="F0EFED"/></a:solidFill>')
panel = ('<p:sp><p:nvSpPr><p:cNvPr id="3" name="Corpo"/><p:cNvSpPr/><p:nvPr><p:ph type="obj" idx="1"/></p:nvPr></p:nvSpPr><p:spPr>' + PANEL
         + '</p:spPr><p:txBody><a:bodyPr lIns="0" tIns="0"/><a:lstStyle/></p:txBody></p:sp>')
layout = H + f'<p:sldLayout {NS} type="obj"><p:cSld name="Titolo e contenuto">' + tree(ph(2, 'Titolo', 'title', 0) + panel) + '</p:cSld></p:sldLayout>'

slide1 = H + f'<p:sld {NS}><p:cSld>' + tree(
    ph(2, 'Titolo', 'title', 0, None, para('Titolo della prova'))
    + ph(3, 'Corpo', 'obj', 1, None, para('Primo punto dell\'elenco') + para('Secondo punto', '', ' b="1"') + para('Terzo punto, in corsivo', '', ' i="1"'))
    + '<p:sp><p:nvSpPr><p:cNvPr id="4" name="Rettangolo"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>' + xfrm(7600000, 4700000, 3000000, 1200000)
    + '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="C00000"/></a:solidFill></p:spPr><p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/>'
    + '<a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="it-IT" sz="2000"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:rPr><a:t>Testo nel rettangolo</a:t></a:r></a:p></p:txBody></p:sp>'
    + '<p:sp><p:nvSpPr><p:cNvPr id="9" name="Guida" hidden="1"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>' + xfrm(0, 0, 9000000, 600000) + '<a:solidFill><a:srgbClr val="00FF00"/></a:solidFill></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>' + para('Nascosta') + '</p:txBody></p:sp>'
    + '<p:pic><p:nvPicPr><p:cNvPr id="5" name="Immagine"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>'
    + xfrm(1000000, 4700000, 2000000, 1200000) + '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>') + '</p:cSld></p:sld>'

SZ = ' sz="1600"'
cells = lambda *t: ''.join('<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>' + para(x, '', SZ) + '</a:txBody><a:tcPr/></a:tc>' for x in t)
slide2 = H + f'<p:sld {NS}><p:cSld>' + tree(
    '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="2" name="Tabella"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>' + '<p:xfrm><a:off x="1000000" y="1000000"/><a:ext cx="6000000" cy="1200000"/></p:xfrm>'
    + '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr/><a:tblGrid><a:gridCol w="3000000"/><a:gridCol w="3000000"/></a:tblGrid>'
    + '<a:tr h="400000">' + cells('Nome', 'Valore') + '</a:tr><a:tr h="400000">' + cells('Alfa', '10') + '</a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>'
    + '<p:sp><p:nvSpPr><p:cNvPr id="7" name="Freccia"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>' + xfrm(7000000, 1000000, 2000000, 800000) + '<a:prstGeom prst="rightArrow"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="000000"/></a:solidFill></p:spPr></p:sp>'
    + '<p:grpSp><p:nvGrpSpPr><p:cNvPr id="3" name="Gruppo"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="1000000" y="3500000"/><a:ext cx="4000000" cy="1000000"/><a:chOff x="0" y="0"/><a:chExt cx="4000000" cy="1000000"/></a:xfrm></p:grpSpPr>'
    + '<p:sp><p:nvSpPr><p:cNvPr id="4" name="Casella"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr>' + xfrm(0, 0, 4000000, 1000000) + '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>'
    + para('Testo in un gruppo', '', ' sz="2800"') + '</p:txBody></p:sp></p:grpSp>') + '</p:cSld></p:sld>'

slide3 = H + f'<p:sld {NS} show="0"><p:cSld>' + tree(ph(2, 'Titolo', 'title', 0, None, para('Slide nascosta'))) + '</p:cSld></p:sld>'
notes = H + f'<p:notes {NS}><p:cSld>' + tree(ph(2, 'Note', 'body', 1, None, para('Nota per chi presenta'))) + '</p:cSld></p:notes>'
pres = H + f'<p:presentation {NS}><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId3"/><p:sldId id="257" r:id="rId4"/><p:sldId id="258" r:id="rId5"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>'

ct = H + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>'
parts = {
    '[Content_Types].xml': ct,
    '_rels/.rels': rels([('rId1', 'officeDocument', 'ppt/presentation.xml')]),
    'ppt/presentation.xml': pres,
    'ppt/_rels/presentation.xml.rels': rels([('rId1', 'slideMaster', 'slideMasters/slideMaster1.xml'), ('rId2', 'theme', 'theme/theme1.xml'), ('rId3', 'slide', 'slides/slide1.xml'), ('rId4', 'slide', 'slides/slide2.xml'), ('rId5', 'slide', 'slides/slide3.xml')]),
    'ppt/slideMasters/slideMaster1.xml': master,
    'ppt/slideMasters/_rels/slideMaster1.xml.rels': rels([('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'), ('rId2', 'theme', '../theme/theme1.xml')]),
    'ppt/slideLayouts/slideLayout1.xml': layout,
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels': rels([('rId1', 'slideMaster', '../slideMasters/slideMaster1.xml')]),
    'ppt/theme/theme1.xml': theme,
    'ppt/slides/slide1.xml': slide1,
    'ppt/slides/_rels/slide1.xml.rels': rels([('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'), ('rId2', 'image', '../media/image1.png'), ('rId3', 'notesSlide', '../notesSlides/notesSlide1.xml')]),
    'ppt/slides/slide2.xml': slide2,
    'ppt/slides/_rels/slide2.xml.rels': rels([('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml')]),
    'ppt/slides/slide3.xml': slide3,
    'ppt/slides/_rels/slide3.xml.rels': rels([('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml')]),
    'ppt/notesSlides/notesSlide1.xml': notes,
    'ppt/media/image1.png': png(40, 24, (30, 120, 200)),
}
z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_STORED if sys.argv[2:] == ['stored'] else zipfile.ZIP_DEFLATED)
for name, data in parts.items(): z.writestr(name, data)
z.close()
