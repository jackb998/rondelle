#!/bin/zsh
# The functional tests of Rondelle (documents, subtitles, archives, images, video, spreadsheets, audio), on
# sample files made here from system pictures and synthetic media (DEBUG test build, nothing committed).
#   Tests/functional/run.sh [WORKDIR]      RONDELLE_BIN: another DEBUG binary
# Prints OK/FAIL per command and «N/M»; exit status 1 if any fails.
ROOT=${0:A:h:h:h}
W=${1:-$(mktemp -d "${TMPDIR%/}/rondelle-funzionali.XXXXXX")}
mkdir -p $W/fx && W=${W:A}
M=${RONDELLE_BIN:-$ROOT/.build-test/out/Products/Release/Rondelle}
[[ -x $M ]] || { print "manca $M: swift build -c release --arch arm64 -Xswiftc -DDEBUG --scratch-path .build-test"; exit 2; }

# Sample files, made once per WORKDIR.
cd $W/fx
if [[ ! -f done ]]; then
  WALL=$(ls /System/Library/Desktop\ Pictures/Sonoma.heic(N) /System/Library/Desktop\ Pictures/*.heic(N) | head -1)
  print "Lettera di prova.\n\nSeconda riga, con un po' di testo." > lettera.txt && textutil -convert docx lettera.txt && rm lettera.txt
  print "Una nota di prova." > nota.txt
  print "1\n00:00:01,000 --> 00:00:02,000\nCiao\n\n2\n00:00:03,000 --> 00:00:04,000\nMondo\n" > sub.srt
  mkdir -p cartella && print uno > cartella/uno.txt && print due > cartella/due.txt
  cp $WALL sonoma.heic
  sips -s format heic -z 1600 1600 "/Library/User Pictures/Animals/Parrot.heic" --out foto.heic >/dev/null   # a subject, for «Sfondo»
  sips -s format png -Z 270 $WALL --out qr.png >/dev/null
  sips -s format pdf $WALL --out doc.pdf >/dev/null   # several MB: «Peso… 1» has something to do
  python3 -I -c "
import csv
with open('tabella.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['nome', 'valore'])
    for i in range(200): w.writerow([f'riga {i}', i * 1.5])"
  python3 -I -c "
import wave, math, struct
w = wave.open('voce.wav', 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
w.writeframes(b''.join(struct.pack('<hh', int(6000 * math.sin(2 * math.pi * 330 * i / 44100)), int(3000 * math.sin(2 * math.pi * 440 * i / 44100))) for i in range(44100 * 2)))
w.close()" && afconvert -f AIFF -d BEI16 voce.wav voce.aiff && rm voce.wav
  python3 -I $ROOT/Tests/security/lib/mkdng.py foto.dng 1200 800   # a camera RAW
  python3 -I -c "
import struct, zlib
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
text = b'Description\\0' + (b'riga\\x07\\x1b[31m\\n' * 2000)
png = b'\\x89PNG\\r\\n\\x1a\\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) + chunk(b'tEXt', text)
png += chunk(b'IDAT', zlib.compress(b'\\0' + b'\\0' * 6 + b'\\0' + b'\\0' * 6)) + chunk(b'IEND', b'')
open('lungo.png', 'wb').write(png)"   # metadata 16 KB long, with control characters
  python3 -I -c "
import struct, zipfile, zlib
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
png = b'\\x89PNG\\r\\n\\x1a\\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 4, 4, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress((b'\\0' + b'\\xf0\\x40\\x40' * 4) * 4)) + chunk(b'IEND', b'')
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'; R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
pic = ('<w:r><w:drawing><wp:anchor behindDoc=\\\"1\\\" simplePos=\\\"0\\\" relativeHeight=\\\"1\\\" locked=\\\"0\\\" layoutInCell=\\\"1\\\" allowOverlap=\\\"1\\\">'
  '<wp:simplePos x=\\\"0\\\" y=\\\"0\\\"/><wp:positionH relativeFrom=\\\"page\\\"><wp:posOffset>0</wp:posOffset></wp:positionH>'
  '<wp:positionV relativeFrom=\\\"page\\\"><wp:posOffset>0</wp:posOffset></wp:positionV><wp:extent cx=\\\"7560310\\\" cy=\\\"10692130\\\"/><wp:wrapNone/>'
  '<wp:docPr id=\\\"1\\\" name=\\\"Sfondo\\\"/><a:graphic><a:graphicData uri=\\\"http://schemas.openxmlformats.org/drawingml/2006/picture\\\"><pic:pic>'
  '<pic:blipFill><a:blip r:embed=\\\"rId1\\\"/></pic:blipFill><pic:spPr><a:xfrm><a:off x=\\\"0\\\" y=\\\"0\\\"/><a:ext cx=\\\"7560310\\\" cy=\\\"10692130\\\"/></a:xfrm></pic:spPr>'
  '</pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>')
body = '<w:p>' + pic + '<w:r><w:t>Testo sopra lo sfondo.</w:t></w:r></w:p>' + ''.join('<w:p><w:r><w:t>Paragrafo di prova numero %d.</w:t></w:r></w:p>' % i for i in range(5))
doc = ('<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\" standalone=\\\"yes\\\"?><w:document xmlns:w=\\\"%s\\\" xmlns:r=\\\"%s\\\" '
  'xmlns:wp=\\\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\\\" xmlns:a=\\\"http://schemas.openxmlformats.org/drawingml/2006/main\\\" '
  'xmlns:pic=\\\"http://schemas.openxmlformats.org/drawingml/2006/picture\\\"><w:body>%s<w:sectPr><w:pgSz w:w=\\\"11906\\\" w:h=\\\"16838\\\"/>'
  '<w:pgMar w:top=\\\"1440\\\" w:right=\\\"1440\\\" w:bottom=\\\"1440\\\" w:left=\\\"1440\\\"/></w:sectPr></w:body></w:document>') % (W, R, body)
z = zipfile.ZipFile('sfondo.docx', 'w')
z.writestr('[Content_Types].xml', '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Types xmlns=\\\"http://schemas.openxmlformats.org/package/2006/content-types\\\">'
  '<Default Extension=\\\"rels\\\" ContentType=\\\"application/vnd.openxmlformats-package.relationships+xml\\\"/><Default Extension=\\\"xml\\\" ContentType=\\\"application/xml\\\"/>'
  '<Default Extension=\\\"png\\\" ContentType=\\\"image/png\\\"/><Override PartName=\\\"/word/document.xml\\\" '
  'ContentType=\\\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\\\"/></Types>')
z.writestr('_rels/.rels', '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\">'
  '<Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\\\" Target=\\\"word/document.xml\\\"/></Relationships>')
z.writestr('word/_rels/document.xml.rels', '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\">'
  '<Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\\\" Target=\\\"media/sfondo.png\\\"/></Relationships>')
z.writestr('word/document.xml', doc); z.writestr('word/media/sfondo.png', png); z.close()"   # a page-sized picture behind the text, as letterheads have
  python3 -I -c "
import zipfile, plistlib
CT = 'http://schemas.openxmlformats.org/package/2006/content-types'; PR = 'http://schemas.openxmlformats.org/package/2006/relationships'
OD = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
core = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" '
  'xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">'
  '<dc:title>Titolo di prova</dc:title><dc:creator>Autore di prova</dc:creator><cp:lastModifiedBy>Revisore di prova</cp:lastModifiedBy>'
  '<dcterms:created xsi:type=\"dcterms:W3CDTF\">2020-01-02T03:04:05Z</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">2021-01-02T03:04:05Z</dcterms:modified></cp:coreProperties>')
app = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">'
  '<Application>Programma di prova</Application><Company>Ditta di prova</Company><Manager>Capo di prova</Manager><Template>Modello.dotm</Template><TotalTime>42</TotalTime></Properties>')
custom = ('<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties\" '
  'xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"2\" name=\"Cliente\"><vt:lpwstr>Cliente di prova</vt:lpwstr></property></Properties>')
props = ('<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>'
  '<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>'
  '<Override PartName=\"/docProps/custom.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.custom-properties+xml\"/>')
def rels(main):
  return ('<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"%s\"><Relationship Id=\"rId1\" Type=\"%s/officeDocument\" Target=\"%s\"/>'
    '<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>'
    '<Relationship Id=\"rId3\" Type=\"%s/extended-properties\" Target=\"docProps/app.xml\"/><Relationship Id=\"rId4\" Type=\"%s/custom-properties\" Target=\"docProps/custom.xml\"/></Relationships>') % (PR, OD, main, OD, OD)
def package(name, main, overrides, parts):
  z = zipfile.ZipFile(name, 'w', zipfile.ZIP_DEFLATED)
  z.writestr('[Content_Types].xml', '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"%s\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>'
    '<Default Extension=\"xml\" ContentType=\"application/xml\"/>%s%s</Types>' % (CT, overrides, props))
  z.writestr('_rels/.rels', rels(main))
  for k, v in parts.items(): z.writestr(k, v)
  z.writestr('docProps/core.xml', core); z.writestr('docProps/app.xml', app); z.writestr('docProps/custom.xml', custom); z.close()
package('autore.docx', 'word/document.xml', '<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>',
  {'word/document.xml': '<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>Testo di prova.</w:t></w:r></w:p></w:body></w:document>'})
package('autore.xlsx', 'xl/workbook.xml', '<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>'
  '<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>',
  {'xl/workbook.xml': '<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"%s\"><sheets><sheet name=\"Foglio1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>' % OD,
   'xl/_rels/workbook.xml.rels': '<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"%s\"><Relationship Id=\"rId1\" Type=\"%s/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>' % (PR, OD),
   'xl/worksheets/sheet1.xml': '<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>prova</t></is></c><c r=\"B1\"><v>3</v></c></row></sheetData></worksheet>'})
open('provenienza.hex', 'w').write(plistlib.dumps(['https://example.com/autore.docx', 'https://example.com/'], fmt=plistlib.FMT_BINARY).hex())"
  for f in autore.docx autore.xlsx; do xattr -wx com.apple.metadata:kMDItemWhereFroms $(<provenienza.hex) $f; xattr -w com.apple.quarantine "0083;65000000;Safari;" $f; done; rm provenienza.hex   # downloaded from a site
  swiftc -O $ROOT/Tests/security/lib/genvid.swift -o $W/genvid 2>/dev/null && $W/genvid clip.mov >/dev/null
  touch done
fi

# A fresh copy for each run: some tests use what earlier ones made (sub.vtt, cartella.tar.gz, tabella.xlsx…).
S=$W/run; rm -rf -- "${S:?}" && cp -R $W/fx $S && cd $S
ok=0; ko=0
r() {
  local out
  out=$(perl -e 'alarm shift; exec @ARGV' 90 "$M" "$@" 2>&1); local rc=$?; last=$out
  if (( rc == 0 )); then
    ok=$((ok + 1)); print -r -- "OK   $* -> $(for p in ${(f)out}; do basename "$p"; done | tr '\n' ' ')"
  else
    ko=$((ko + 1)); print -r -- "FAIL $* :: $out"
  fi
}
print "== documenti"; for t in PDF RTF ODT HTML TXT; do r --run $t lettera.docx; done; r --run DOCX nota.txt
# A picture behind the text (letterhead, page background) stays behind it: one page, text on it, the picture under it.
r --run PDF sfondo.docx; r --test-pdf-page sfondo.pdf "Testo sopra lo sfondo"
[[ $last =~ '^pagine=1 testo=si colore=(2[0-9][0-9]),([0-9]+),' ]] && (( match[2] < 120 )) || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL sfondo DOCX -> PDF :: $last" }
# A Pages file made by Rondelle from the empty template of the installed Pages: the document's text is in its body.
if [[ -d /Applications/Pages.app || -d "/Applications/Pages Creator Studio.app" ]]; then
  r --run Pages lettera.docx; r --test-pages-text lettera.pages "Seconda riga"
  [[ $last == testo=si* ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL DOCX -> Pages :: $last" }
  # And back: the Pages file made above is read by Rondelle (text, styles), and converted to every document format.
  r --test-pages-read lettera.pages "Seconda riga"
  [[ $last == testo=si* ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL leggi Pages :: $last" }
  for t in PDF DOCX RTF ODT HTML TXT; do r --run $t lettera.pages; done
fi
# PowerPoint: a made-up deck (master, layout, title and body that inherit, bullets, picture, table, group, notes) to PDF,
# images and text; then a PDF and images into decks of one picture per slide, read back with the same reader.
python3 -I $ROOT/Tests/functional/lib/mkpptx.py prova.pptx; python3 -I $ROOT/Tests/functional/lib/mkpptx.py archiviato.pptx stored
print "== presentazioni"; for t in PDF PNG JPG TXT; do r --run $t prova.pptx; done
r --test-pptx-text prova.pptx "Testo in un gruppo"
[[ $last == 'diapositive=2 testo=si immagini=1 tabelle=1 larghezza=960 libere=2' ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL lettura PPTX :: $last" }
# A hidden slide and a hidden shape are not read; a ZIP with stored (not deflated) parts reads the same.
r --test-pptx-text prova.pptx "Nascosta"
[[ $last == *'diapositive=2 testo=no'* ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL PPTX nascosto :: $last" }
r --test-pptx-text archiviato.pptx "Testo in un gruppo"
[[ $last == 'diapositive=2 testo=si immagini=1 tabelle=1 larghezza=960 libere=2' ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL PPTX archiviato :: $last" }
r --test-pdf-page prova.pdf "Titolo della prova"
[[ $last == pagine=2* && $last == *testo=si* ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL PPTX -> PDF :: $last" }
mv prova.pptx originale.pptx; r --run PPTX prova.pdf; r --test-pptx-text prova.pptx "Titolo"
[[ $last == 'diapositive=2 testo=no immagini=2 tabelle=0 larghezza=960 libere=0' ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL PDF -> PPTX :: $last" }
r --run PPTX foto.heic; r --test-pptx-text foto.pptx "x"
[[ $last == diapositive=1\ testo=no\ immagini=1* ]] || { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL immagine -> PPTX :: $last" }
print "== sottotitoli"; r --run VTT sub.srt; r --run SRT sub.vtt; r --run TXT sub.srt
print "== archivi"; r --run TAR.GZ cartella; r --run Estrai cartella.tar.gz
print "== immagini"; r --run --tools Ruota foto.heic; r --run --tools Specchio foto.heic; r --run --tools Sfondo foto.heic
r --run --tools "A sinistra" foto.heic; r --run --tools "180°" foto.heic; r --run --tools "Specchio verticale" foto.heic; r --test-rotations
mkdir -p lay; r --layouts lay 4:5 foto.heic sonoma.heic qr.png
RONDELLE_VALUE="0,5" r --run --tools "Peso…" sonoma.heic
RONDELLE_VALUE="1" r --run --tools "Peso…" doc.pdf
print "== video"; r --run GIF clip.mov; r --run --tools "2×" clip.mov; r --run --tools Unisci clip.mov "clip (2x).mp4"
print "== fogli di calcolo"; r --run XLSX tabella.csv; r --run ODS tabella.xlsx; r --run CSV tabella.ods; r --run PDF tabella.xlsx
print "== ruota"; r --test-wheel-hit; r --test-wheel-motion foto.heic; r --test-wheel-keys foto.heic; r --test-wheel-switch; r --test-wheel-behind foto.heic; r --test-tutorial; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=en r --test-tutorial; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=fr r --test-tutorial; r --test-sidebar-motion; RONDELLE_RESOURCES=$ROOT/Resources r --test-dock-icon; r --test-wheel-hints; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=fr r --test-wheel-hints; r --test-wheel-labels; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=en r --test-wheel-labels; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=fr r --test-wheel-labels; r --test-support-link; r --test-share-picker foto.heic
print "== metadati"; r --test-metadata foto.heic doc.pdf clip.mov voce.aiff lungo.png
r --test-metadata lettera.docx tabella.xlsx nota.txt sub.srt cartella cartella.tar.gz autore.docx autore.xlsx
r --test-office-metadata autore.docx autore.xlsx; r --run --tools Metadati autore.docx; r --run --tools Metadati autore.xlsx
r --test-metadata-search foto.heic autore.docx nota.txt
# RAW: read like any photo; what keeps the source format comes out as JPG (a RAW can't be written).
rx() { local ext=$1; shift; local before=$ko; r "$@"; (( ko == before )) && [[ ${last:e} != $ext ]] && { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL $* :: ${last:t} non è .$ext" } }
print "== RAW"; rx jpg --run JPG foto.dng; rx jpg --run --tools Ruota foto.dng; rx jpg --run --tools Metadati foto.dng; rx jpg --run --tools 1920px foto.dng
print "== audio"; r --run --tools Normalizza voce.aiff; r --run --tools Mono voce.aiff
print "Test funzionali: $ok/$((ok + ko))"
(( ko == 0 ))
