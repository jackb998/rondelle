import sys, zipfile, zlib, struct, os, io
# Hostile and damaged XLSX/ODS files for the spreadsheet reader. Usage: mksheets.py OUTDIR
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
CT = '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'
def wb(n=1, target=None):
    sheets = ''.join(f'<sheet name="S{i}" sheetId="{i+1}" r:id="rId{i+1}"/>' for i in range(n))
    rels = ''.join(f'<Relationship Id="rId{i+1}" Target="{target or f"worksheets/sheet{i+1}.xml"}"/>' for i in range(n))
    return (f'<workbook xmlns:r="r"><sheets>{sheets}</sheets></workbook>', f'<Relationships>{rels}</Relationships>')
def sheet(rows):
    return '<worksheet><sheetData>' + rows + '</sheetData></worksheet>'
SMALL = sheet('<row r="1"><c r="A1" t="inlineStr"><is><t>ciao</t></is></c><c r="B1"><v>1</v></c></row>')

class Stream(io.RawIOBase):
    """A big entry made of a repeated block, generated on the fly."""
def big_entry(z, name, head, block, total, tail):
    zi = zipfile.ZipInfo(name); zi.compress_type = zipfile.ZIP_DEFLATED
    with z.open(zi, 'w', force_zip64=True) as f:
        f.write(head.encode())
        b = block.encode() * max(1, (1 << 20) // len(block))
        n = 0
        while n < total:
            f.write(b); n += len(b)
        f.write(tail.encode())

def xlsx(name, entries, big=None, mode=zipfile.ZIP_DEFLATED, zip64=False):
    p = os.path.join(out, name)
    with zipfile.ZipFile(p, 'w', mode, allowZip64=True) as z:
        z.writestr('[Content_Types].xml', CT)
        for k, v in entries:
            zi = zipfile.ZipInfo(k); zi.compress_type = mode
            if zip64:
                with z.open(zi, 'w', force_zip64=True) as f: f.write(v.encode() if isinstance(v, str) else v)
            else:
                z.writestr(zi, v)
        for b in big or []:
            big_entry(z, *b)
    return p

w1, r1 = wb(1)
MB = 1 << 20
# a. size and number of entries
w50, r50 = wb(50, target='worksheets/sheet1.xml')
xlsx('a1_50fogli_stessa_voce_590MB.xlsx', [('xl/workbook.xml', w50), ('xl/_rels/workbook.xml.rels', r50)],
     big=[('xl/worksheets/sheet1.xml', '<worksheet><sheetData>', '<!-- riempitivo riempitivo riempitivo -->', 550 * MB, '</sheetData></worksheet>')])
xlsx('a2_tre_voci_590MB.xlsx', [],
     big=[('xl/workbook.xml', '<workbook xmlns:r="r"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets>', '<!-- x -->', 550 * MB, '</workbook>'),
          ('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/>', '<!-- x -->', 550 * MB, '</Relationships>'),
          ('xl/worksheets/sheet1.xml', '<worksheet><sheetData>', '<!-- x -->', 550 * MB, '</sheetData></worksheet>')])
xlsx('a3_voce_700MB.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1)],
     big=[('xl/worksheets/sheet1.xml', '<worksheet><sheetData>', '<!-- x -->', 700 * MB, '</sheetData></worksheet>')])
# b. damaged packages
good = xlsx('b0_buono.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', SMALL)])
data = open(good, 'rb').read()
open(os.path.join(out, 'b1_troncato.xlsx'), 'wb').write(data[:len(data) // 2])
cd = data.rfind(b'PK\x01\x02'); first_cd = data.find(b'PK\x01\x02')
open(os.path.join(out, 'b2_senza_directory_centrale.xlsx'), 'wb').write(data[:first_cd])
with zipfile.ZipFile(os.path.join(out, 'b3_voci_duplicate.xlsx'), 'w', zipfile.ZIP_DEFLATED) as z:
    import warnings; warnings.simplefilter('ignore')
    z.writestr('xl/workbook.xml', w1); z.writestr('xl/_rels/workbook.xml.rels', r1)
    z.writestr('xl/worksheets/sheet1.xml', SMALL)
    z.writestr('xl/worksheets/sheet1.xml', sheet('<row r="1"><c r="A1" t="inlineStr"><is><t>SECONDA</t></is></c></row>'))
xlsx('b4_zip64.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', SMALL)], zip64=True)
wm, rm_ = wb(1, target='/-x.xml')
xlsx('b5_nome_trattino.xlsx', [('xl/workbook.xml', wm), ('xl/_rels/workbook.xml.rels', rm_), ('-x.xml', SMALL)])
wm2, rm2 = wb(1, target='-d')
xlsx('b5b_nome_trattino_relativo.xlsx', [('xl/workbook.xml', wm2), ('xl/_rels/workbook.xml.rels', rm2), ('xl/-d', SMALL)])
# shared strings: a huge declared count, then 120 M empty strings (~600 MB of "<si/>")
xlsx('b6_sharedstrings_conteggio.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', SMALL),
     ('xl/sharedStrings.xml', '<sst count="999999999999999" uniqueCount="999999999999999"><si><t>a</t></si></sst>')])
xlsx('b6b_sharedstrings_120M_vuote.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', SMALL)],
     big=[('xl/sharedStrings.xml', '<sst>', '<si/>', 550 * MB, '</sst>')])
xlsx('b6c_sharedstrings_una_da_590MB.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', SMALL)],
     big=[('xl/sharedStrings.xml', '<sst><si><t>', 'abcdefghij', 550 * MB, '</t></si></sst>')])
xlsx('b6d_cella_v_590MB.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1)],
     big=[('xl/worksheets/sheet1.xml', '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>', 'abcdefghij', 550 * MB, '</t></is></c></row></sheetData></worksheet>')])
for tag, ref in [('b7_XFD1048576', 'XFD1048576'), ('b7b_ZZZZ9999999', 'ZZZZ9999999'), ('b7c_A1_e_XFD1', None)]:
    rows = (f'<row r="1"><c r="A1"><v>1</v></c></row><row><c r="{ref}"><v>2</v></c></row>' if ref else
            '<row r="1"><c r="A1"><v>1</v></c><c r="XFD1"><v>2</v></c></row><row r="1048576"><c r="A1048576"><v>3</v></c></row>')
    xlsx(tag + '.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', sheet(rows))])
# 6 M distinct cells without text? cells with value spread over many rows: budget check
xlsx('b7d_2M_celle_vuote.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1)],
     big=[('xl/worksheets/sheet1.xml', '<worksheet><sheetData>', '<row><c/><c/><c/><c/><c/><c/><c/><c/></row>', 400 * MB, '<row r="1048576"><c r="XFD1048576"><v>1</v></c></row></sheetData></worksheet>')])
xlsx('b9_annidamento_profondo.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1),
     ('xl/worksheets/sheet1.xml', '<worksheet><sheetData>' + '<a>' * 2_000_000 + '</a>' * 2_000_000 + '</sheetData></worksheet>')])
xlsx('b10_utf8_non_valido.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1),
     ('xl/worksheets/sheet1.xml', b'<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>\xff\xfe\xc3\x28 x</t></is></c></row></sheetData></worksheet>')])
xlsx('b11_utf16_bom.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1),
     ('xl/worksheets/sheet1.xml', '﻿<?xml version="1.0" encoding="UTF-16"?>'.encode('utf-16-le') + SMALL.encode('utf-16-le'))])
xlsx('b11b_utf8_bom.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', '﻿' + SMALL)])
xlsx('b12_righe_fuori_ordine.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml',
     sheet('<row r="5"><c r="A5"><v>5</v></c></row><row r="2"><c r="B2"><v>2</v></c></row><row r="5"><c r="A5"><v>doppia</v></c></row><row r="1"><c r="C1"><v>1</v></c></row>'))])
# sizes in the headers lie: the central directory says 10 bytes, the data is 700 MB
liar = xlsx('b13_dimensioni_false.xlsx', [('xl/workbook.xml', w1), ('xl/_rels/workbook.xml.rels', r1)],
     big=[('xl/worksheets/sheet1.xml', '<worksheet><sheetData>', '<!-- x -->', 700 * MB, '</sheetData></worksheet>')])
d = bytearray(open(liar, 'rb').read())
i = 0
while True:
    i = d.find(b'PK\x01\x02', i)
    if i < 0: break
    nl = struct.unpack('<H', d[i+28:i+30])[0]; name = bytes(d[i+46:i+46+nl])
    if name == b'xl/worksheets/sheet1.xml':
        # zip64 extra field holds the real sizes: rewrite them too
        el = struct.unpack('<H', d[i+30:i+32])[0]; ex = i + 46 + nl
        j = ex
        while j < ex + el:
            hid, hl = struct.unpack('<HH', d[j:j+4])
            if hid == 1: d[j+4:j+12] = struct.pack('<Q', 10)
            j += 4 + hl
        if struct.unpack('<I', d[i+24:i+28])[0] != 0xFFFFFFFF: d[i+24:i+28] = struct.pack('<I', 10)
    i += 4
open(liar, 'wb').write(d)

# c. ODS
def ods(name, content):
    with zipfile.ZipFile(os.path.join(out, name), 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('mimetype', 'application/vnd.oasis.opendocument.spreadsheet')
        z.writestr('content.xml', content)
T = '<office:document-content xmlns:office="o" xmlns:table="t" xmlns:text="x"><office:body><office:spreadsheet><table:table table:name="T">'
E = '</table:table></office:spreadsheet></office:body></office:document-content>'
ods('c1_colonne_ripetute_miliardi.ods', T + '<table:table-row><table:table-cell table:number-columns-repeated="4000000000"><text:p>x</text:p></table:table-cell></table:table-row>' + E)
ods('c2_righe_ripetute_miliardi.ods', T + '<table:table-row table:number-rows-repeated="4000000000"><table:table-cell><text:p>x</text:p></table:table-cell></table:table-row>' + E)
ods('c3_entrambe.ods', T + '<table:table-row table:number-rows-repeated="99999999999"><table:table-cell table:number-columns-repeated="99999999999"><text:p>x</text:p></table:table-cell></table:table-row>' + E)
ods('c4_vuote_poi_valore.ods', T + '<table:table-row table:number-rows-repeated="1048575"><table:table-cell table:number-columns-repeated="16384"/></table:table-row><table:table-row><table:table-cell table:number-columns-repeated="16383"/><table:table-cell><text:p>fine</text:p></table:table-cell></table:table-row>' + E)
ods('c5_annidamento.ods', T + '<table:table-row><table:table-cell><text:p>' + '<text:span>' * 2_000_000 + 'x' + '</text:span>' * 2_000_000 + '</text:p></table:table-cell></table:table-row>' + E)
ods('c6_negativo.ods', T + '<table:table-row table:number-rows-repeated="-5"><table:table-cell table:number-columns-repeated="-1"><text:p>x</text:p></table:table-cell></table:table-row>' + E)
# 100 M <sheet> elements in the workbook (attributes kept in memory before the 50-sheet cut)
xlsx('b14_workbook_100M_sheet.xlsx', [('xl/_rels/workbook.xml.rels', r1), ('xl/worksheets/sheet1.xml', SMALL)],
     big=[('xl/workbook.xml', '<workbook xmlns:r="r"><sheets>', '<sheet name="S" sheetId="1" r:id="rId1"/>', 500 * MB, '</sheets></workbook>')])
# ODS: 400 MB of empty cells one element at a time, then a value (0.8.2-S3)
with zipfile.ZipFile(os.path.join(out, 'c7_celle_vuote_una_a_una.ods'), 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('mimetype', 'application/vnd.oasis.opendocument.spreadsheet')
    zi = zipfile.ZipInfo('content.xml'); zi.compress_type = zipfile.ZIP_DEFLATED
    with z.open(zi, 'w', force_zip64=True) as f:
        f.write((T).encode())
        blk = b'<table:table-row>' + b'<table:table-cell/>' * 50 + b'</table:table-row>'
        b = blk * ((1 << 20) // len(blk)); n = 0
        while n < 400 * MB: f.write(b); n += len(b)
        f.write(('<table:table-row><table:table-cell><text:p>x</text:p></table:table-cell></table:table-row>' + E).encode())
print('ok')
