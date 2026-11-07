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
print "== sottotitoli"; r --run VTT sub.srt; r --run SRT sub.vtt; r --run TXT sub.srt
print "== archivi"; r --run TAR.GZ cartella; r --run Estrai cartella.tar.gz
print "== immagini"; r --run --tools Ruota foto.heic; r --run --tools Specchio foto.heic; r --run --tools Sfondo foto.heic
mkdir -p lay; r --layouts lay 4:5 foto.heic sonoma.heic qr.png
RONDELLE_VALUE="0,5" r --run --tools "Peso…" sonoma.heic
RONDELLE_VALUE="1" r --run --tools "Peso…" doc.pdf
print "== video"; r --run GIF clip.mov; r --run --tools "2×" clip.mov; r --run --tools Unisci clip.mov "clip (2x).mp4"
print "== fogli di calcolo"; r --run XLSX tabella.csv; r --run ODS tabella.xlsx; r --run CSV tabella.ods; r --run PDF tabella.xlsx
print "== ruota"; r --test-wheel-hit; r --test-wheel-motion foto.heic; r --test-wheel-keys foto.heic; r --test-wheel-switch; r --test-wheel-behind foto.heic; r --test-tutorial; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=en r --test-tutorial; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=fr r --test-tutorial; r --test-sidebar-motion; RONDELLE_RESOURCES=$ROOT/Resources r --test-dock-icon; r --test-wheel-hints; RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=fr r --test-wheel-hints; r --test-support-link; r --test-share-picker foto.heic
print "== metadati"; r --test-metadata foto.heic doc.pdf clip.mov voce.aiff lungo.png
# RAW: read like any photo; what keeps the source format comes out as JPG (a RAW can't be written).
rx() { local ext=$1; shift; local before=$ko; r "$@"; (( ko == before )) && [[ ${last:e} != $ext ]] && { ok=$((ok - 1)); ko=$((ko + 1)); print -r -- "FAIL $* :: ${last:t} non è .$ext" } }
print "== RAW"; rx jpg --run JPG foto.dng; rx jpg --run --tools Ruota foto.dng; rx jpg --run --tools Metadati foto.dng; rx jpg --run --tools 1920px foto.dng
print "== audio"; r --run --tools Normalizza voce.aiff; r --run --tools Mono voce.aiff
print "Test funzionali: $ok/$((ok + ko))"
(( ko == 0 ))
