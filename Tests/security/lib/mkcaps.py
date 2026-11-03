import sys, os, zipfile, struct
# One file just past each cap of the readers (0.8.3 phase 0, point 2). Usage: mkcaps.py OUTDIR BASE.mp3
out, mp3 = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
CT = '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'
def xlsx(name, sheets, rels=None, workbook=None):
    with zipfile.ZipFile(os.path.join(out, name), 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', CT)
        n = len(sheets)
        z.writestr('xl/workbook.xml', workbook or '<workbook xmlns:r="r"><sheets>' + ''.join(
            f'<sheet name="S{i+1}" sheetId="{i+1}" r:id="rId{i+1}"/>' for i in range(n)) + '</sheets></workbook>')
        z.writestr('xl/_rels/workbook.xml.rels', rels or '<Relationships>' + ''.join(
            f'<Relationship Id="rId{i+1}" Target="worksheets/sheet{i+1}.xml"/>' for i in range(n)) + '</Relationships>')
        for i, body in enumerate(sheets):
            z.writestr(f'xl/worksheets/sheet{i+1}.xml', '<worksheet><sheetData>' + body + '</sheetData></worksheet>')
def cell(ref, v): return f'<c r="{ref}" t="inlineStr"><is><t>{v}</t></is></c>'
def ods(name, tables):
    with zipfile.ZipFile(os.path.join(out, name), 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('mimetype', 'application/vnd.oasis.opendocument.spreadsheet')
        z.writestr('content.xml', '<office:document-content xmlns:office="o" xmlns:table="t" xmlns:text="x"><office:body><office:spreadsheet>'
                   + ''.join(f'<table:table table:name="T{i+1}">{t}</table:table>' for i, t in enumerate(tables))
                   + '</office:spreadsheet></office:body></office:document-content>')
row = lambda v: f'<table:table-row><table:table-cell><text:p>{v}</text:p></table:table-cell></table:table-row>'
# 50 sheets / tables: the 51st is the one past the cap
xlsx('t1_xlsx_51_fogli.xlsx', [f'<row r="1">{cell("A1", f"foglio{i+1}")}</row>' for i in range(51)])
ods('t2_ods_51_tabelle.ods', [row(f'tabella{i+1}') for i in range(51)])
# 10 000 relationships before the one the sheet needs
rels = '<Relationships>' + ''.join(f'<Relationship Id="x{i}" Target="altro{i}.xml"/>' for i in range(10_000)) \
       + '<Relationship Id="rId1" Target="worksheets/vero.xml"/></Relationships>'
with zipfile.ZipFile(os.path.join(out, 't3_rels_10001.xlsx'), 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', CT)
    z.writestr('xl/workbook.xml', '<workbook xmlns:r="r"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', rels)
    z.writestr('xl/worksheets/vero.xml', '<worksheet><sheetData><row r="1">' + cell('A1', 'VERO') + '</row></sheetData></worksheet>')
    z.writestr('xl/worksheets/sheet1.xml', '<worksheet><sheetData><row r="1">' + cell('A1', 'SBAGLIATO') + '</row></sheetData></worksheet>')
# 10 001 sheet elements in the workbook
xlsx('t4_workbook_10001_sheet.xlsx', [f'<row r="1">{cell("A1", "uno")}</row>'],
     workbook='<workbook xmlns:r="r"><sheets>' + '<sheet name="S" sheetId="1" r:id="rId1"/>' * 10_001 + '</sheets></workbook>')
# ODS repeats one past the grid
ods('t5_ods_righe_1048577.ods', ['<table:table-row table:number-rows-repeated="1048577"><table:table-cell><text:p>r</text:p></table:table-cell></table:table-row>'])
ods('t6_ods_colonne_16385.ods', ['<table:table-row><table:table-cell table:number-columns-repeated="16385"><text:p>c</text:p></table:table-cell></table:table-row>'])
ods('t7_ods_spazi_1001.ods', ['<table:table-row><table:table-cell><text:p>a<text:s text:c="1001"/>b</text:p></table:table-cell></table:table-row>'])
# XLSX positions one past the grid
xlsx('t8_xlsx_riga_1048577.xlsx', ['<row r="1">' + cell('A1', 'prima') + '</row><row r="1048577">' + cell('A1048577', 'oltre') + '</row>'])
xlsx('t9_xlsx_colonna_XFE.xlsx', ['<row r="1">' + cell('A1', 'prima') + cell('XFE1', 'oltre') + '</row>'])
# 12 M + 1 cell elements (empty)
with zipfile.ZipFile(os.path.join(out, 't10_xlsx_12M_piu_1_celle.xlsx'), 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', CT)
    z.writestr('xl/workbook.xml', '<workbook xmlns:r="r"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
    zi = zipfile.ZipInfo('xl/worksheets/sheet1.xml'); zi.compress_type = zipfile.ZIP_DEFLATED
    with z.open(zi, 'w', force_zip64=True) as f:
        f.write(b'<worksheet><sheetData><row r="1"><c r="A1"><v>1</v></c></row>')
        block = b'<row>' + b'<c/>' * 1000 + b'</row>'
        for _ in range(12_000): f.write(block)
        f.write(b'<row><c/></row></sheetData></worksheet>')
# ZIP with 200 001 entries (the extraction cap is 200 000)
with zipfile.ZipFile(os.path.join(out, 't11_zip_200001_voci.zip'), 'w', zipfile.ZIP_STORED) as z:
    for i in range(200_001): z.writestr(f'd{i // 1000}/f{i}.txt', b'')
# MP3: a real APE tag hidden behind a damaged APE footer (size < 32)
audio = open(mp3, 'rb').read()
v = b'SegretoAPE'; item = struct.pack('<II', len(v), 0) + b'Title\x00' + v
real = item + b'APETAGEX' + struct.pack('<IIII', 2000, len(item) + 32, 1, 0) + b'\x00' * 8
damaged = b'APETAGEX' + struct.pack('<IIII', 2000, 8, 0, 0) + b'\x00' * 8
open(os.path.join(out, 't12_mp3_ape_vero_dietro_ape_rotto.mp3'), 'wb').write(audio + real + damaged)
# legit LibreOffice padding after real content: must still convert
ods('t13_ods_padding_libreoffice.ods', ['<table:table-row><table:table-cell><text:p>dato</text:p></table:table-cell></table:table-row><table:table-row table:number-rows-repeated="1048575"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>'])
ods('t14_ods_spazi_1000001.ods', ['<table:table-row><table:table-cell><text:p>a<text:s text:c="1000001"/>b</text:p></table:table-cell></table:table-row>'])
# exactly at the caps: must still convert
xlsx('l1_50_fogli.xlsx', [f'<row r="1">{cell("A1", f"f{i}")}</row>' for i in range(50)])
with zipfile.ZipFile(os.path.join(out, 'l2_rels_10000.xlsx'), 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', CT)
    z.writestr('xl/workbook.xml', '<workbook xmlns:r="r"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', '<Relationships>' + ''.join(f'<Relationship Id="x{i}" Target="a{i}.xml"/>' for i in range(9_999))
               + '<Relationship Id="rId1" Target="worksheets/vero.xml"/></Relationships>')
    z.writestr('xl/worksheets/vero.xml', '<worksheet><sheetData><row r="1">' + cell('A1', 'VERO') + '</row></sheetData></worksheet>')
ods('l3_righe_1048576.ods', ['<table:table-row table:number-rows-repeated="1048576"><table:table-cell><text:p>r</text:p></table:table-cell></table:table-row>'])
xlsx('l4_riga_1048576.xlsx', ['<row r="1048576">' + cell('B1048576', 'ultima') + '</row>'])
print('ok')
