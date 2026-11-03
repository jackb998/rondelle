#!/bin/zsh
# Rondelle security regression suite, for the DEBUG test build only (the release app has no command line).
#
#   Tests/security/run.sh [WORKDIR]
#
# Rebuilds the hostile corpus in WORKDIR (default: a new folder in $TMPDIR; nothing large is ever committed),
# runs the attacks of the 0.8.2 and 0.8.3 reports and prints one PASS/FAIL line per check, then a summary.
# Exit status 1 if any check fails. Thresholds are the ones the reports accepted.
#   SKIP_BUILD=1   use the existing .build-test binary
#   RONDELLE_BIN  another DEBUG binary (e.g. an older version, to see the suite catch its problems)
#   ONLY="A C"     run only these sections:
#     A image location (canaries), B video location, C spreadsheets and caps, D audio tags, E extended attributes,
#     F PDF from JPEG, G redaction (thumbnails, auxiliary images, data after the end, Copri, Sfondo),
#     H V1–V4 (links and decompression bombs, Tests/security/v1v4.sh), I protected ZIPs (unlock, passwords),
#     J password hints (hostile comments too), K translation (needs it/en/fr installed in macOS),
#     L pipes, sockets and devices, M data about this Mac in outputs, invalid documents, translation attempts,
#     N PDFs built to expand on extraction (RAM measured, watchdog at 6 GB),
#     O PDF tools that draw, compressed and encrypted streams, documents that expand on import
#     P PDF → Word and Word → PDF: pages, pictures, what stays out, hostile packages
#     Q jobs at the same time: limit, names, «Annulla tutti»; the line under the wheel
#     S PDF rotation, icons (ICNS, ICO), SHA-256
#     R PDF redaction (markers in every place text hides), video to a size, text to the clipboard, subtitles
# The 26 functional tests are in Tests/functional/run.sh.
zmodload zsh/datetime
setopt extendedglob
ROOT=${0:A:h:h:h}
LIB=${0:A:h}/lib
W=${1:-$(mktemp -d "${TMPDIR%/}/rondelle-security.XXXXXX")}
mkdir -p $W/bin $W/src || exit 2
W=${W:A}
# The temporary folders of the app have fixed names: each run has its own, so two suites can't disturb each other.
mkdir -p $W/tmp; export TMPDIR=$W/tmp/
M=${RONDELLE_BIN:-$ROOT/.build-test/out/Products/Release/Rondelle}
RES=$W/risultati.tsv; : > $RES
rm -rf -- "${W:?}/run"   # outputs of a previous run would be counted as new

# MARK: helpers

wants() { [[ -z $ONLY || " $ONLY " == *" $1 "* ]] }
res() {   # res SECTION CHECK PASS|FAIL DETAIL
  print -r -- "$1	$3	$2	$4" >> $RES
  printf "%-4s %-4s %-58s %s\n" $1 $3 "${2[1,58]}" "${4[1,110]}"
}
check() { if (( $3 )); then res $1 $2 PASS "$4"; else res $1 $2 FAIL "$4"; fi }
# act DIR INPUT... -- ARGS: copies the inputs into a fresh folder, runs Rondelle (120 s at most) and sets
# OUTS (new files, including the share copies it prints), LOG and RC.
n=0
act() {
  local src=$1; shift
  local inputs=(); while [[ $1 != -- ]]; do inputs+=$1; shift; done; shift
  n=$((n + 1)); local d=$W/run/$n; mkdir -p $d
  for i in $inputs; do cp -Rp $src/$i $d/; done
  local args=(); for a in "$@"; do if (( ${inputs[(Ie)$a]} )); then args+=$d/$a; else args+=$a; fi; done
  LOG=$(cd $d && perl -e 'alarm shift; exec @ARGV' 120 $M "${args[@]}" 2>&1); RC=$?
  OUTS=()
  local p; for p in $d/**/*(N.); do [[ ${p:h} == $d ]] && (( ${inputs[(Ie)${p:t}]} )) && continue; [[ $p == $d/(${(j:|:)inputs})/* ]] && continue; OUTS+=$p; done
  for p in ${(f)LOG}; do [[ -f $p && $p != $d/* ]] && OUTS+=$p; done
}

# MARK: build and tools

if [[ -z $SKIP_BUILD && -z $RONDELLE_BIN ]]; then
  print "Build DEBUG di prova…"
  (cd $ROOT && swift build -c release --arch arm64 -Xswiftc -DDEBUG --scratch-path .build-test 2>&1 | grep -E 'error|Build comp') || { print "build non riuscita"; exit 2; }
fi
[[ -x $M ]] || { print "manca $M (togli SKIP_BUILD)"; exit 2; }
if [[ $(defaults read Rondelle removeLocation 2>/dev/null) == 0 ]]; then
  print "Il dominio «Rondelle» ha removeLocation = 0: le prove vanno fatte con il valore di serie."; exit 2
fi
print "Strumenti di prova…"
for t in chk gencan gengps genvid genaux auxchk pixchk pdfcmp; do
  [[ -x $W/bin/$t ]] || swiftc -O $LIB/$t.swift -o $W/bin/$t 2>&1 | grep 'error:'
done
B=$W/bin
PY=(python3 -I)

# MARK: source media (all made here: system wallpapers, a system user picture, synthetic video and audio)

WALL=$(ls /System/Library/Desktop\ Pictures/Sonoma.heic(N) /System/Library/Desktop\ Pictures/*.heic(N) | head -1)
SUBJ=/Library/User\ Pictures/Animals/Parrot.heic
[[ -f $WALL && -f $SUBJ ]] || { print "mancano le immagini di sistema ($WALL, $SUBJ)"; exit 2; }
cd $W/src
[[ -f big.mov ]] || $B/genvid big.mov >/dev/null
[[ -f voce.aiff ]] || { $PY -c "
import wave, math, struct
w = wave.open('voce.wav', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
w.writeframes(b''.join(struct.pack('<h', int(8000 * math.sin(2 * math.pi * 440 * i / 44100))) for i in range(44100 * 2)))
w.close()" && afconvert -f AIFF -d BEI16 voce.wav voce.aiff && rm voce.wav; }
[[ -f voce.mp3 ]] || $M --run MP3 voce.aiff >/dev/null
# the system picture is 512 px: a 1600 px copy, so that covered areas and thumbnails have realistic sizes
[[ -f subj.png ]] || sips -s format png -z 1600 1600 $SUBJ --out subj.png >/dev/null
SUBJ=$W/src/subj.png

# MARK: A — image location

if wants A; then
  print "\n== A · posizione nelle immagini"
  mkdir -p $W/can && cd $W/can
  for t in jpeg heic png tiff; do e=${t/jpeg/jpg}
    [[ -f can.$e ]] || $B/gencan can.$e $WALL 1600 1 1 $t >/dev/null
    [[ -f iim.$e ]] || IIM=1 $B/gencan iim.$e $WALL 1600 1 1 $t >/dev/null
  done
  [[ -f can-nogps.jpg ]] || $B/gencan can-nogps.jpg $WALL 1600 1 0 >/dev/null
  [[ -f iim-nogps.jpg ]] || IIM=1 $B/gencan iim-nogps.jpg $WALL 1600 1 0 >/dev/null
  [[ -f can-nogps.heic ]] || $B/gencan can-nogps.heic $WALL 1600 1 0 heic >/dev/null
  [[ -f sog.jpg ]] || $B/gencan sog.jpg $SUBJ 1600 1 1 >/dev/null
  [[ -f sog.png ]] || $B/gencan sog.png $SUBJ 1600 1 1 png >/dev/null
  total=0
  a_check() {   # a_check LABEL: every output without canaries and GPS; no output only where the file can't give one
    if (( ! ${#OUTS} )); then
      local why=${${LOG##*: }[1,80]}
      [[ $1 == *Sfondo* && $LOG == *soggetto* || $1 == *Peso* && $LOG == *piccolo* ]] && return
      res A "$1" FAIL "nessun file: $why"; return
    fi
    local o; for o in $OUTS; do total=$((total + 1))
      local c=$($PY $LIB/canraw.py $o); local g=$($B/chk $o | grep -c 'EXIF GPS=RESTA')
      check A "$1 → ${o:t}" $(( ${c%% *} == 0 && g == 0 )) "canarini ${c%% *}, GPS $([[ $g == 0 ]] && echo tolto || echo RESTA)"
    done
  }
  for img in can.jpg can.heic can.png can.tiff iim.jpg iim.heic iim.png iim.tiff; do
    for fmt in JPEG PNG HEIC WebP TIFF GIF BMP PDF; do
      [[ ${img:e} == ${fmt:l} || ( ${img:e} == jpg && $fmt == JPEG ) ]] && continue
      act $W/can $img -- --run $fmt $img; a_check "$img → $fmt"
    done
    for tool in Comprimi 50% 1920px 480px Ruota Specchio Sfondo Metadati; do act $W/can $img -- --run --tools $tool $img; a_check "$img · $tool"; done
    RONDELLE_VALUE=0,05 act $W/can $img -- --run --tools "Peso…" $img; a_check "$img · Peso…"
    RONDELLE_VALUE=800 act $W/can $img -- --run --tools "Misura…" $img; a_check "$img · Misura…"
    act $W/can $img -- --test-editor $img; a_check "$img · Modifica (segni)"
    RONDELLE_ADJUST="brightness=0.1" act $W/can $img -- --test-adjust $img; a_check "$img · Modifica (Regola)"
    act $W/can $img -- --test-share-prepare $img; a_check "$img · Condividi"
  done
  for img in can-nogps.jpg iim-nogps.jpg can-nogps.heic; do for tool in Ruota Specchio; do act $W/can $img -- --run --tools $tool $img; a_check "$img · $tool (senza GPS)"; done; done
  act $W/can can.jpg iim.jpg -- --layouts . 4:5 can.jpg iim.jpg; a_check "can+iim · Impagina"
  for img in sog.jpg sog.png; do act $W/can $img -- --run --tools Sfondo $img; a_check "$img · Sfondo (con soggetto)"; done
  check A "uscite immagine controllate" $(( total >= 168 )) "$total (0.8.2: 168 + 2 Sfondo)"
fi

# MARK: B — video location

if wants B; then
  print "\n== B · posizione nei video"
  mkdir -p $W/vid && cd $W/vid
  [[ -f gps.mov ]] || $B/gengps $W/vid $WALL $W/src/big.mov >/dev/null
  # MP4 and M4V with the same QuickTime location atoms (as Android phones write them)
  $PY -c "
import struct
b = bytearray(open('gps.mov', 'rb').read()); n = struct.unpack('>I', b[:4])[0]
for name, brand in [('gps.mp4', b'mp42'), ('gps.m4v', b'M4V ')]:
    c = bytearray(b); c[8:12] = brand; c[16:n] = c[16:n].replace(b'qt  ', b'isom'); open(name, 'wb').write(c)"
  total=0
  b_check() {
    (( ${#OUTS} )) || { res B "$1" FAIL "nessun file: ${${LOG##*: }[1,80]}"; return; }
    local o; for o in $OUTS; do total=$((total + 1)); local line=$($B/chk $o)
      check B "$1 → ${o:t}" $(( ! ${#${(M)line:#*RESTA*}} )) "${line#*	}"
    done
  }
  for v in gps.mov gps.mp4 gps.m4v; do
    for fmt in MP4 M4V MOV GIF M4A; do [[ $v == gps.${fmt:l} ]] && continue; act $W/vid $v -- --run $fmt $v; b_check "$v → $fmt"; done
    for tool in 1080p 720p HEVC "2×" "0,5×" Fotogramma Muto "Solo audio" Metadati; do act $W/vid $v -- --run --tools $tool $v; b_check "$v · $tool"; done
    act $W/vid $v -- --trim $v 0 1; b_check "$v · Taglia"
    act $W/vid $v -- --test-share-prepare $v; b_check "$v · Condividi"
  done
  act $W/vid gps.mov gps.mp4 -- --run --tools Unisci gps.mov gps.mp4; b_check "mov+mp4 · Unisci"
  check B "uscite video controllate" $(( total >= 46 )) "$total (0.8.2: 46)"
fi

# MARK: C — spreadsheets, archives and caps

if wants C; then
  print "\n== C · fogli di calcolo ostili e tetti"
  [[ -f $W/sh/c7_celle_vuote_una_a_una.ods ]] || $PY $LIB/mksheets.py $W/sh >/dev/null
  [[ -f $W/sh/l4_riga_1048576.xlsx ]] || $PY $LIB/mkcaps.py $W/sh $W/src/voce.mp3 >/dev/null
  # expected: OK (converted) or a piece of the refusal message
  typeset -A expect=(
    a1_50fogli_stessa_voce_590MB.xlsx vuoto  a2_tre_voci_590MB.xlsx "in tutto"  a3_voce_700MB.xlsx vuoto
    b0_buono.xlsx OK  b1_troncato.xlsx "non valido"  b2_senza_directory_centrale.xlsx "non valido"
    b3_voci_duplicate.xlsx danneggiato  b4_zip64.xlsx OK  b5_nome_trattino.xlsx vuoto  b5b_nome_trattino_relativo.xlsx OK
    b6_sharedstrings_conteggio.xlsx OK  b6b_sharedstrings_120M_vuote.xlsx celle  b6c_sharedstrings_una_da_590MB.xlsx "cella troppo lunga"
    b6d_cella_v_590MB.xlsx "cella troppo lunga"  b7_XFD1048576.xlsx celle  b7b_ZZZZ9999999.xlsx griglia  b7c_A1_e_XFD1.xlsx celle
    b7d_2M_celle_vuote.xlsx celle  b9_annidamento_profondo.xlsx vuoto  b10_utf8_non_valido.xlsx danneggiato  b11_utf16_bom.xlsx OK
    b11b_utf8_bom.xlsx OK  b12_righe_fuori_ordine.xlsx OK  b13_dimensioni_false.xlsx vuoto  b14_workbook_100M_sheet.xlsx "troppi fogli"
    c1_colonne_ripetute_miliardi.ods celle  c2_righe_ripetute_miliardi.ods "righe ripetute"  c3_entrambe.ods celle
    c4_vuote_poi_valore.ods celle  c5_annidamento.ods OK  c6_negativo.ods OK  c7_celle_vuote_una_a_una.ods celle
    t1_xlsx_51_fogli.xlsx "più di 50 fogli"  t2_ods_51_tabelle.ods "più di 50 fogli"  t3_rels_10001.xlsx "troppi fogli"
    t4_workbook_10001_sheet.xlsx "troppi fogli"  t5_ods_righe_1048577.ods "righe ripetute"  t6_ods_colonne_16385.ods celle
    t7_ods_spazi_1001.ods OK  t8_xlsx_riga_1048577.xlsx griglia  t9_xlsx_colonna_XFE.xlsx griglia  t10_xlsx_12M_piu_1_celle.xlsx celle
    t13_ods_padding_libreoffice.ods OK  t14_ods_spazi_1000001.ods "cella troppo lunga"
    l1_50_fogli.xlsx OK  l2_rels_10000.xlsx OK  l3_righe_1048576.ods OK  l4_riga_1048576.xlsx OK
    t11_zip_200001_voci.zip "più di 200000 file"
  )
  TMPF="${TMPDIR%/}/Fogli in lettura"
  for name in ${(ko)expect}; do
    local f=$W/sh/$name; [[ -f $f ]] || { res C $name FAIL "fixture mancante"; continue; }
    local d=$W/run/sheet-$name; mkdir -p $d; cp $f $d/
    local args=(--run CSV $d/$name); [[ $name == *.zip ]] && args=(--run --tools Estrai $d/$name)
    local t0=$EPOCHREALTIME; $M "${args[@]}" > $d/.log 2>&1 & local pid=$!; local peak=0
    while kill -0 $pid 2>/dev/null; do
      local r=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' '); (( ${r:-0} > peak )) && peak=$r
      (( EPOCHREALTIME - t0 > 120 )) && kill $pid
      sleep 0.2
    done
    wait $pid; local rc=$? secs=$(( EPOCHREALTIME - t0 )) mb=$(( peak / 1024 ))
    local msg=$(tail -1 $d/.log); local e=${expect[$name]}
    local outcome=0
    if [[ $e == OK ]]; then (( rc == 0 )) && outcome=1; else (( rc != 0 )) && [[ $msg == *"$e"* ]] && outcome=1; fi
    local left=$(ls "$TMPF" 2>/dev/null | wc -l | tr -d ' ')
    rm -f -- "${TMPF:?}"/*(N)   # a stopped run must not count against the next file
    check C $name $(( outcome && secs <= 15 && mb <= 300 && left == 0 )) \
      "$(printf '%.1f s, %d MB, lasciati %s; atteso %s: %s' $secs $mb $left "$e" "${${msg##*: }[1,60]}")"
  done
  # the exactly-at-cap files keep their data
  [[ -f $W/run/sheet-l2_rels_10000.xlsx/l2_rels_10000.csv ]] && check C "l2: foglio giusto" $(( $(grep -c VERO $W/run/sheet-l2_rels_10000.xlsx/l2_rels_10000.csv) == 1 )) "contiene VERO"
  [[ -f $W/run/sheet-t7_ods_spazi_1001.ods/t7_ods_spazi_1001.csv ]] && check C "t7: 1001 spazi" $(( $(grep -o ' ' $W/run/sheet-t7_ods_spazi_1001.ods/t7_ods_spazi_1001.csv | wc -l) == 1001 )) "spazi contati"
fi

# MARK: D — audio tags

if wants D; then
  print "\n== D · tag audio"
  mkdir -p $W/au && cd $W/au
  for k in id3 ape 3di v1; do for nt in 64 65 100 1000; do
    local f=t_${k}_$nt.mp3; [[ -f $f ]] || $PY $LIB/mkmp3.py $W/src/voce.mp3 $f $k $nt
    act $W/au $f -- --run --tools Metadati $f
    if (( nt == 64 )); then check D "$f" $(( RC == 0 && ${#OUTS} == 1 )) "$( (( ${#OUTS} )) && cmp -s $OUTS[1] $W/src/voce.mp3 && echo 'audio identico' || echo 'DIVERSO o assente')"
      (( ${#OUTS} )) && ! cmp -s $OUTS[1] $W/src/voce.mp3 && res D "$f identico" FAIL "audio diverso dall'originale"
    else check D "$f" $(( RC != 0 && ${#OUTS} == 0 )) "${${LOG##*: }[1,70]}"; fi
  done; done
  [[ -f $W/sh/t12_mp3_ape_vero_dietro_ape_rotto.mp3 ]] || $PY $LIB/mkcaps.py $W/sh $W/src/voce.mp3 >/dev/null
  act $W/sh t12_mp3_ape_vero_dietro_ape_rotto.mp3 -- --run --tools Metadati t12_mp3_ape_vero_dietro_ape_rotto.mp3
  check D "APE vero dietro APE rotto" $(( RC != 0 && ${#OUTS} == 0 )) "${${LOG##*: }[1,70]}"
fi

# MARK: E — extended attributes and AppleDouble

if wants E; then
  print "\n== E · attributi estesi (X1)"
  mkdir -p $W/xa && cd $W/xa
  tag() { xattr -w com.apple.metadata:kMDItemWhereFroms "https://canarino-wherefrom.example/CANARINOW" "$1"
          xattr -w com.apple.quarantine "0081;5f000000;Safari;CANARINOQ" "$1"; xattr -w user.canarino CANARINOX "$1" }
  if [[ ! -f done ]]; then
    cp $W/can/can-nogps.jpg foto.jpg 2>/dev/null || $B/gencan foto.jpg $WALL 1600 1 0 >/dev/null
    $B/gencan foto.heic $WALL 1600 1 0 heic >/dev/null; cp $W/src/voce.aiff $W/src/big.mov .
    print "uno,due\n1,2" > tabella.csv && $M --run XLSX tabella.csv >/dev/null && rm tabella.csv
    print "Lettera di prova" > lettera.txt && $M --run DOCX lettera.txt >/dev/null && $M --run PDF lettera.txt >/dev/null && mv lettera.pdf doc.pdf && rm lettera.txt
    print "1\n00:00:01,000 --> 00:00:02,000\nciao\n" > sub.srt
    mkdir -p cartella && print testo > cartella/nota.txt && cp foto.jpg cartella/
    for f in foto.jpg foto.heic voce.aiff big.mov tabella.xlsx lettera.docx doc.pdf sub.srt cartella cartella/*; do tag $f; done
    touch done
  fi
  # AppleDouble ._ entries, as the Finder makes them. ditto sometimes can't read a quarantined file here (0.8.2-E1):
  # retry, and only keep an archive that is whole.
  for try in 1 2 3; do
    unzip -tq finder.zip >/dev/null 2>&1 && break
    rm -f finder.zip; ditto -c -k --sequesterRsrc --keepParent cartella finder.zip 2>/dev/null
  done
  unzip -tq finder.zip >/dev/null 2>&1 || res E "fixture finder.zip" FAIL "ditto non è riuscito a crearla (ambiente)"
  e_check() {   # e_check LABEL: no xattr but com.apple.TextEncoding, no AppleDouble or pax xattr, no canary in the bytes
    local tries=0
    while (( ! ${#OUTS} && tries < 2 )) && [[ $LOG != *"più piccol"* ]]; do tries=$((tries + 1)); act $W/xa "${E_ARGS[@]}"; done   # see 0.8.2-E1
    [[ $LOG == *"più piccol"* ]] && return   # nothing written, nothing to check
    (( ${#OUTS} )) || { res E "$1" FAIL "nessun file: ${${LOG##*: }[1,80]}"; return; }
    local o; for o in $OUTS; do
      local x=$(xattr $o 2>/dev/null | grep -v -x -e com.apple.provenance -e com.apple.TextEncoding -e com.apple.quarantine | tr '\n' ' ')
      [[ $(xattr -p com.apple.quarantine $o 2>/dev/null) == *CANARINOQ* ]] && x+="quarantena dell'ingresso "
      local content=$o ad=""
      case $o in
        *.zip) if [[ $o == *protetto* ]]; then bsdtar -xOf $o --passphrase canarino1234567 > $W/.c 2>/dev/null
                 ad=$(bsdtar -tf $o --passphrase canarino1234567 2>/dev/null | grep -E '__MACOSX|(^|/)\._'); unzip -l $W/.c >/dev/null 2>&1 && { ad+=$(unzip -l $W/.c | grep -E '__MACOSX|/\._| \._'); unzip -p $W/.c >> $W/.c 2>/dev/null; }
               else ad=$(unzip -l $o 2>/dev/null | grep -E '__MACOSX|/\._| \._'); unzip -p $o > $W/.c 2>/dev/null; fi; content=$W/.c ;;
        *.tar.gz) gunzip -c $o > $W/.c 2>/dev/null; content=$W/.c; LC_ALL=C grep -a -q LIBARCHIVE.xattr $W/.c && ad="pax xattr" ;;
      esac
      local raw=$(LC_ALL=C grep -a -o -E 'CANARINO[WQX]' $o $content 2>/dev/null | sort -u | tr '\n' ' ')
      check E "$1 → ${o:t}" $(( ! ${#x} && ! ${#ad} && ! ${#raw} )) "xattr [${x:-—}] AppleDouble [${ad:+sì}] canarini [${raw:-—}]"
    done
  }
  e() { local label=$1; shift; E_ARGS=("$@"); act $W/xa "$@"; e_check "$label" }
  # macOS sometimes refuses for a moment a file with kMDItemWhereFroms (EPERM, even to cat): the job tries again
  if [[ ! -f momenti.docx ]]; then print -r -- prova > momenti.txt; $M --run DOCX momenti.txt >/dev/null 2>&1; tag momenti.docx; fi
  n_ko=0; for i in {1..40}; do rm -rf rip; mkdir rip; cp -p momenti.docx rip/ 2>/dev/null || cat momenti.docx > rip/momenti.docx; (cd rip && $M --run PDF momenti.docx >/dev/null 2>&1); [[ -f rip/momenti.pdf ]] || n_ko=$((n_ko + 1)); done
  check E "DOCX → PDF, file scaricato, 40 volte: sempre riuscito" $(( n_ko == 0 )) "$n_ko falliti su 40"; rm -rf rip
  e "Comprimi (foto)" foto.jpg -- --run --tools Comprimi foto.jpg
  e "Converti → PNG" foto.jpg -- --run PNG foto.jpg
  e "Ruota (HEIC)" foto.heic -- --run --tools Ruota foto.heic
  e "PDF da foto" foto.jpg -- --run PDF foto.jpg
  e "Metadati (foto)" foto.jpg -- --run --tools Metadati foto.jpg
  e "Metadati (PDF)" doc.pdf -- --run --tools Metadati doc.pdf
  e "Comprimi (PDF)" doc.pdf -- --run --tools Comprimi doc.pdf
  e "Condividi (foto)" foto.jpg -- --test-share-prepare foto.jpg
  e "Video → MP4" big.mov -- --run MP4 big.mov
  e "Metadati (video)" big.mov -- --run --tools Metadati big.mov
  e "Audio → MP3" voce.aiff -- --run MP3 voce.aiff
  e "Metadati (audio)" voce.aiff -- --run --tools Metadati voce.aiff
  e "Fogli → CSV" tabella.xlsx -- --run CSV tabella.xlsx
  e "DOCX → PDF" lettera.docx -- --run PDF lettera.docx
  e "SRT → VTT" sub.srt -- --run VTT sub.srt
  e "ZIP (file)" foto.jpg -- --run --tools ZIP foto.jpg
  e "ZIP (cartella)" cartella -- --run ZIP cartella
  e "TAR.GZ (cartella)" cartella -- --run TAR.GZ cartella
  RONDELLE_VALUE=canarino1234567 e "ZIP protetto (cartella)" cartella -- --run "ZIP protetto" cartella
  [[ -f finder.zip ]] && e "Estrai (ZIP con ._)" finder.zip -- --run --tools Estrai finder.zip
  rm -f $W/.c
fi

# MARK: F — PDF from JPEG

if wants F; then
  print "\n== F · PDF da JPEG (G1)"
  mkdir -p $W/pdf && cd $W/pdf
  for mp in 12 48; do for o in 1 6 8; do
    local f=p$mp-o$o.jpg side=$(( mp == 12 ? 4000 : 8000 ))
    [[ -f $f ]] || WIDE=1 $B/gencan $f $SUBJ $side $o 1 >/dev/null
    act $W/pdf $f -- --run PDF $f
    (( ${#OUTS} )) || { res F $f FAIL "nessun PDF"; continue; }
    local pdf=$OUTS[1] c=$($PY $LIB/canraw.py $OUTS[1]) g=$($B/chk $OUTS[1] | grep -c 'GPS=RESTA') cmpl=$($B/pdfcmp $OUTS[1] $W/pdf/$f)
    local ratio=$(( $(stat -f %z $pdf) * 1.0 / $(stat -f %z $W/pdf/$f) )) diff=${${cmpl##*differenza media }%%/*}
    check F "$f" $(( ${c%% *} == 0 && g == 0 && ratio <= 1.5 && ${diff/,/.} < 2 )) \
      "$(printf 'canarini %s, GPS %s, PDF/JPEG %.2f×, differenza %s/255' ${c%% *} $([[ $g == 0 ]] && echo tolto || echo RESTA) $ratio $diff)"
    check F "$f dritta" $(( ! ${#${(M)cmpl:#*verso giusto: NO*}} )) "${${cmpl#*verso giusto: }%%  *}"
  done; done
fi

# MARK: G — redaction

if wants G; then
  print "\n== G · redazione e dati incorporati"
  mkdir -p $W/red && cd $W/red
  if [[ ! -f tail.jpg ]]; then
    $B/genaux aux.jpg $SUBJ jpeg >/dev/null; $B/genaux aux.heic $SUBJ heic >/dev/null
    sips -s format jpeg -s formatOptions 90 -Z 1600 $SUBJ --out base.jpg >/dev/null
    sips -s format jpeg -Z 160 $WALL --out thumbsrc.jpg >/dev/null   # the EXIF thumbnail shows another picture
    $PY $LIB/mkred.py $W/red
  fi
  g_check() {   # g_check LABEL INPUT
    (( ${#OUTS} )) || { [[ $1 == *Sfondo* && $LOG == *soggetto* ]] || res G "$1" FAIL "nessun file: ${${LOG##*: }[1,80]}"; return; }
    local o; for o in $OUTS; do
      local a=$($B/auxchk $o)
      local starts=${${a#*inizi JPEG=}%%	*} eoi=${${a#*dopo EOI=}%% B*}
      # 0.8.3-R4: ImageIO adds a 160×160 thumbnail of the same picture when a HEIC becomes a JPEG; it carries nothing else
      local allowed=1; [[ $2 == aux.heic && ( $o == *.jpg || $o == *.pdf ) ]] && allowed=2
      local ok=$(( ${#${(M)a:#*ausiliarie=\[\]*}} && ${#${(M)a:#*canarini=\[\]*}} && eoi == 0 && starts <= allowed ))
      [[ $o != *.jpg && $o != *.pdf ]] && ok=$(( ${#${(M)a:#*ausiliarie=\[\]*}} && ${#${(M)a:#*canarini=\[\]*}} ))
      check G "$1 → ${o:t}" $ok "${a#*	}"
      if [[ $1 == *Copri* ]]; then local p=$($B/pixchk cover $o); check G "$1: area coperta" $(( ${${p##*non opachi: }} == 0 )) "${p#*	}"; fi
      if [[ $1 == *Sfondo* && $o == *.png ]]; then local q=$($PY $LIB/pngalpha.py $o); check G "$1: RGB sotto alpha 0" $(( ${q##* } == 0 )) "${q#* }"; fi
    done
  }
  for img in thumb.jpg tail.jpg aux.jpg aux.heic; do
    for fmt in JPEG PNG HEIC TIFF; do [[ ${img:e} == ${fmt:l} || ( ${img:e} == jpg && $fmt == JPEG ) ]] && continue; act $W/red $img -- --run $fmt $img; g_check "$img → $fmt" $img; done
    for tool in Comprimi 50% Ruota Specchio Sfondo Metadati; do act $W/red $img -- --run --tools $tool $img; g_check "$img · $tool" $img; done; act $W/red $img -- --run PDF $img; g_check "$img · PDF" $img
    act $W/red $img -- --test-editor $img; g_check "$img · Modifica (Copri, segni)" $img
    act $W/red $img -- --test-share-prepare $img; g_check "$img · Condividi" $img
  done
  # a clean JPEG still rotates without re-encoding
  act $W/red base.jpg -- --run --tools Ruota base.jpg
  if (( ${#OUTS} )); then
    local same=$($PY -c "import sys; a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read(); print(int(a[a.find(b'\xff\xda'):]==b[b.find(b'\xff\xda'):]))" $W/red/base.jpg $OUTS[1])
    check G "JPEG pulito: Ruota senza perdita" $(( same )) "dati compressi identici: $([[ $same == 1 ]] && echo sì || echo no)"
  else res G "JPEG pulito: Ruota senza perdita" FAIL "nessun file"; fi
fi

# MARK: H — V1–V4 (links, archives, decompression bombs: second audit)

if wants H; then
  print "\n== H · V1–V4"
  hn=0
  RONDELLE_BIN=$M ${LIB:h}/v1v4.sh $W/v1v4 | while IFS= read -r line; do
    [[ $line == (PASS|FAIL)\ * ]] && { res H "${line#* }" ${line%% *} ""; hn=$((hn + 1)); }
  done
  check H "controlli V1–V4 eseguiti" $(( hn == 8 )) "$hn di 8"
fi

# MARK: I — protected ZIPs: unlock and extract, passwords

if wants I; then
  print "\n== I · ZIP protetti"
  mkdir -p $W/pz && cd $W/pz
  rm -rf -- "${W:?}/pz"/*(N)
  print segreto > nota.txt
  RONDELLE_VALUE=password1234 $M --run --tools "ZIP protetto" nota.txt >/dev/null 2>&1
  print "zipcrypt9" | bsdtar --format zip --options zip:encryption=zipcrypt -cf zipcrypto.zip nota.txt 2>/dev/null
  zip -q chiaro.zip nota.txt
  check I "ZIP protetto (12 caratteri) creato" $(( ${#$(print -l *protetto*.zip(N))} > 0 )) "$(print *protetto*.zip(N))"
  lst=$($M --list --tools "nota (protetto).zip" | tr '\n' ' ')
  check I "ZIP cifrato: «Sblocca ed estrai», niente «Estrai» né ZIP semplice" $(( ${#${(M)lst:#*Sblocca ed estrai*}} && ! ${#${(M)lst:#*Estrai\ *}} && ! ${#${(M)lst:#*ZIP\ \[*}} )) "$lst"
  lst=$($M --list --tools chiaro.zip | tr '\n' ' ')
  check I "ZIP in chiaro: «Estrai» e «ZIP protetto»" $(( ${#${(M)lst:#Estrai*}} && ${#${(M)lst:#*ZIP protetto*}} )) "$lst"
  RONDELLE_VALUE=password1234 act $W/pz "nota (protetto).zip" -- --run --tools "Sblocca ed estrai" "nota (protetto).zip"
  found=(${(M)OUTS:#*/nota.txt})
  check I "password giusta: file in chiaro estratto (ZIP interno aperto)" $(( RC == 0 && ${#found} == 1 )) "${(j: :)${OUTS:t}}"
  RONDELLE_VALUE=sbagliata act $W/pz "nota (protetto).zip" -- --run --tools "Sblocca ed estrai" "nota (protetto).zip"
  check I "password sbagliata: errore e nessun file" $(( RC != 0 && ${#OUTS} == 0 )) "${${LOG##*: }[1,60]}"
  RONDELLE_VALUE=zipcrypt9 act $W/pz zipcrypto.zip -- --run --tools "Sblocca ed estrai" zipcrypto.zip
  found=(${(M)OUTS:#*/nota.txt})
  check I "ZIP di terzi (ZipCrypto) estratto" $(( RC == 0 && ${#found} == 1 )) "rc $RC: ${(j: :)${OUTS:t}} ${${LOG##*: }[1,40]}"
  for pw in abc12 abcdefghij; do
    rm -f "nota (protetto) 2.zip" "nota (protetto).zip"
    out=$(RONDELLE_VALUE=$pw $M --run --tools "ZIP protetto" nota.txt 2>&1)
    check I "password di ${#pw} caratteri senza conferma: nessun file" $(( ! ${#$(print -l *protetto*.zip(N))} )) "${${out##*: }[1,50]}"
  done
  out=$(RONDELLE_VALUE="" $M --run --tools "ZIP protetto" nota.txt 2>&1)
  check I "password vuota: rifiutata" $(( ${#${(M)out:#*vuota*}} )) "${${out##*: }[1,50]}"
fi

# MARK: J — password hints (in clear next to the encrypted data, so what is read back is hostile)

if wants J; then
  print "\n== J · Suggerimenti delle password"
  mkdir -p $W/hint && cd $W/hint
  rm -rf -- "${W:?}/hint"/*(N)
  sep=$'\x1f'
  pw=lunga-password-di-prova-77
  print segreto-del-canarino > nota.txt
  print "Pagina di prova" > pag.txt && textutil -convert rtf pag.txt -output pag.rtf && $M --run PDF pag.rtf >/dev/null 2>&1
  RONDELLE_VALUE="$pw${sep}il cane di Luca" $M --run --tools "ZIP protetto" nota.txt >/dev/null 2>&1
  z="nota (protetto).zip"
  check J "ZIP: il suggerimento torna uguale" $(( $($M --read-hint "$z" | grep -c '^il cane di Luca$') == 1 )) "$($M --read-hint "$z")"
  c=$(python3 -I -c "import zipfile,sys;print(zipfile.ZipFile(sys.argv[1]).comment.decode())" "$z" 2>&1)
  check J "ZIP: commento valido per altre app" $(( ${#${(M)c:#*Rondelle hint: il cane di Luca*}} )) "${c[1,60]}"
  RONDELLE_VALUE=$pw act $W/hint "$z" -- --run --tools "Sblocca ed estrai" "$z"
  found=(${(M)OUTS:#*/nota.txt})
  check J "ZIP con suggerimento: si estrae con la password" $(( RC == 0 && ${#found} == 1 )) "${(j: :)${OUTS:t}}"
  check J "ZIP: password e contenuto non sono nel file" $(( ! $(strings -a "$z" | grep -c -e "$pw" -e segreto-del-canarino) )) ""
  rm -f "$z"
  RONDELLE_VALUE="$pw${sep}è ${(U)pw} davvero" $M --run --tools "ZIP protetto" nota.txt >/dev/null 2>&1; rc=$?
  check J "ZIP: suggerimento con dentro la password rifiutato, nessun file" $(( rc != 0 && ! ${#$(print -l *protetto*.zip(N))} )) "rc $rc"
  RONDELLE_VALUE="$pw" $M --run --tools "ZIP protetto" nota.txt >/dev/null 2>&1
  check J "ZIP senza suggerimento: nessun commento" $(( ! ${#$($M --read-hint "$z")} )) ""
  rm -f "$z"
  RONDELLE_VALUE="$pw${sep}nel  mezzo"$'‮\x07'" 🐶" $M --run --tools "ZIP protetto" nota.txt >/dev/null 2>&1
  h=$($M --read-hint "$z")
  check J "scrittura: caratteri di controllo e invisibili tolti" $(( ! $(print -rn -- "$h" | LC_ALL=C grep -c $'\x07\|\xe2\x80\xae') && ${#h} > 0 )) "$h"
  innm=$'\x1e'
  rm -f "$z"
  RONDELLE_VALUE="$pw${sep}${innm}il gatto/di: casa" $M --run --tools "ZIP protetto" nota.txt >/dev/null 2>&1
  zn=(*suggerimento*.zip(N))
  check J "ZIP con «Mostralo nel nome»: suggerimento nel nome, senza / né :" $(( ${#zn} == 1 && ${#${(M)zn[1]:#*il gatto-di- casa*}} )) "${zn[1]}"
  check J "ZIP con «Mostralo nel nome»: il suggerimento resta anche nel file" $(( ${#zn} == 1 && $($M --read-hint "$zn[1]" | grep -c '^il gatto/di: casa$') == 1 )) "$($M --read-hint "$zn[1]" 2>&1)"
  rm -f -- $zn
  RONDELLE_VALUE="$pw${sep}${innm}" $M --run --tools "ZIP protetto" nota.txt >/dev/null 2>&1
  zs=(*.zip(N)); plain=0; [[ ${#zs} == 1 && $zs[1] == "nota (protetto).zip" ]] && plain=1
  check J "«Mostralo nel nome» senza suggerimento: nome normale" $plain "$zs"
  rm -f "nota (protetto).zip"
  RONDELLE_VALUE="$pw${sep}${innm}la mia data" $M --run --tools Password pag.pdf >/dev/null 2>&1
  dn=(pag*suggerimento*la\ mia\ data*.pdf(N))
  check J "PDF con «Mostralo nel nome»: suggerimento nel nome" $(( ${#dn} == 1 )) "$(print *.pdf(N))"
  rm -f -- $dn
  RONDELLE_VALUE="$pw${sep}data di nascita" $M --run --tools Password pag.pdf >/dev/null 2>&1
  d="pag (protetto).pdf"
  check J "PDF: il suggerimento torna uguale" $(( $($M --read-hint "$d" | grep -c '^data di nascita$') == 1 )) "$($M --read-hint "$d")"
  RONDELLE_VALUE=$pw act $W/hint "$d" -- --run --tools Sblocca "$d"
  check J "PDF con suggerimento: si sblocca con la password" $(( RC == 0 && ${#OUTS} == 1 )) "${(j: :)${OUTS:t}}"
  check J "PDF sbloccato: il suggerimento non resta" $(( ${#OUTS} == 1 && ! $(strings -a "$OUTS[1]" | grep -c RondelleHint) )) ""
  RONDELLE_VALUE="sbagliatissima" act $W/hint "$d" -- --run --tools Sblocca "$d"
  check J "PDF: password sbagliata resta rifiutata" $(( RC != 0 && ${#OUTS} == 0 )) "${${LOG##*: }[1,50]}"
  python3 -I - <<'P'
import zipfile, base64
def z(name, comment):
    f = zipfile.ZipFile(name, 'w'); f.writestr('x', 'y'); f.comment = comment; f.close()
z('rtl.zip', 'Rondelle hint: ‮evil\x07\nseconda'.encode() + b'A' * 500)
z('altro.zip', b'commento di un altro programma')
z('nonutf.zip', b'Rondelle hint: \xff\xfe\xfd')
z('firma.zip', b'Rondelle hint: PK\x05\x06 finta')
z('enorme.zip', b'Rondelle hint: ' + b'B' * 65000)
open('corto.zip', 'wb').write(b'PK\x05\x06')
open('vuoto.zip', 'wb').write(b'')
open('nonb64.pdf', 'wb').write(b'%PDF-1.4\n%RondelleHint:!!!non-base64\n')
open('lungo.pdf', 'wb').write(b'%PDF-1.4\n%RondelleHint:' + base64.b64encode(b'C' * 600) + b'\n')
P
  h=$($M --read-hint rtl.zip)
  check J "ostile: ZIP con controlli e testo enorme → una riga, 100 caratteri" $(( ${#h} <= 100 && $(print -r -- "$h" | wc -l) == 1 && ! $(print -rn -- "$h" | LC_ALL=C grep -c $'\xe2\x80\xae') )) "${h[1,40]}"
  check J "ostile: commento di altri programmi ignorato" $(( ! ${#$($M --read-hint altro.zip)} )) ""
  for f in nonutf.zip corto.zip vuoto.zip nonb64.pdf; do
    h=$($M --read-hint $f 2>&1); rc=$?
    check J "ostile: $f → nessun suggerimento, nessun crash" $(( rc == 0 && ! ${#h} )) "rc $rc"
  done
  for f in firma.zip enorme.zip lungo.pdf; do
    h=$($M --read-hint $f 2>&1); rc=$?
    check J "ostile: $f → al più 100 caratteri" $(( rc == 0 && ${#h} <= 100 )) "rc $rc, ${#h} caratteri"
  done
fi

# MARK: K — translation (needs it, en and fr installed on this Mac: they are checked by the system's translator)

if wants K; then
  print "\n== K · Traduzione"
  mkdir -p $W/tra && cd $W/tra
  rm -rf -- "${W:?}/tra"/*(N)
  print "The cat sleeps on the table while the rain falls outside the old house." > en.txt
  print -l "# Le voyage en montagne" "" "Nous sommes partis tôt le matin pour voir le lever du soleil." "" '```' "code ne pas traduire" '```' > fr.md
  print -l 1 "00:00:01,000 --> 00:00:03,500" "Domani pioverà per tutta la giornata," "dicono le previsioni del tempo." "" 2 "00:01:04,250 --> 00:01:06,000" "Porta con te un ombrello nuovo." > it.srt
  print -l WEBVTT "" "00:00.000 --> 00:02.000" "Where are you going this evening with your friends?" > en.vtt
  print '<html><body><h1>The garden</h1><p>The flowers are very beautiful in spring, and the birds sing all day long.</p><img src="http://127.0.0.1:9/spia.png"></body></html>' > en.html
  textutil -convert docx en.html -output en.docx 2>/dev/null
  textutil -convert rtf en.html -output en.rtf 2>/dev/null
  $M --run PDF en.rtf >/dev/null 2>&1
  print "El gato duerme sobre la mesa mientras la lluvia cae fuera de la vieja casa y los niños juegan." > es.txt
  print "Il gatto dorme sul tavolo mentre la pioggia cade fuori dalla vecchia casa." > it.txt
  print "Ciao" > corto.txt
  print "12345 67890" > numeri.txt
  : > vuoto.txt
  python3 -I -c "open('enorme.txt','w').write('The cat sleeps on the table. ' * 80000)"
  act $W/tra en.txt -- --run --tools "In italiano" en.txt
  check K "TXT inglese → italiano" $(( RC == 0 && ${#OUTS} == 1 && $(grep -ci gatto "$OUTS[1]") )) "${OUTS[1]:t}"
  act $W/tra fr.md -- --run --tools "In italiano" fr.md
  check K "MD: titolo tradotto, blocco di codice intatto" $(( RC == 0 && $(grep -c '^# .*montagna' "$OUTS[1]") && $(grep -c '^code ne pas traduire$' "$OUTS[1]") )) "${OUTS[1]:t}"
  act $W/tra it.srt -- --run --tools "In inglese" it.srt
  check K "SRT: tempi uguali, testo tradotto" $(( RC == 0 && $(grep -c -e '^00:00:01,000 --> 00:00:03,500$' -e '^00:01:04,250 --> 00:01:06,000$' "$OUTS[1]") == 2 && $(grep -ci umbrella "$OUTS[1]") )) "${OUTS[1]:t}"
  act $W/tra en.vtt -- --run --tools "In francese" en.vtt
  check K "VTT → francese, stessa estensione" $(( RC == 0 && $(head -1 "$OUTS[1]" | grep -c WEBVTT) && ${#${(M)OUTS[1]:#*.vtt}} )) "${OUTS[1]:t}"
  for f in en.html en.docx en.rtf; do
    act $W/tra $f -- --run --tools "In italiano" $f
    check K "$f: stesso formato, testo tradotto" $(( RC == 0 && ${#${(M)OUTS[1]:#*.${f:e}}} && $(textutil -convert txt -stdout "$OUTS[1]" 2>/dev/null | grep -ci giardino) )) "${OUTS[1]:t}"
  done
  act $W/tra en.pdf -- --run --tools "In francese" en.pdf
  check K "PDF: esce un PDF" $(( RC == 0 && ${#${(M)OUTS[1]:#*.pdf}} )) "${OUTS[1]:t}"
  check K "PDF: il testo originale non resta nel file" $(( ! $(strings -a "$OUTS[1]" | grep -c 'The garden') )) ""
  act $W/tra es.txt -- --run --tools "In inglese" es.txt
  check K "spagnolo: rifiutato, nessun file" $(( RC != 0 && ! ${#OUTS} )) "${${LOG##*: }[1,70]}"
  act $W/tra it.txt -- --run --tools "In italiano" it.txt
  check K "già nella lingua chiesta: nessun file" $(( RC != 0 && ! ${#OUTS} )) "${${LOG##*: }[1,60]}"
  act $W/tra corto.txt -- --run --tools "In inglese" corto.txt
  check K "lingua incerta senza nessuno a cui chiedere: errore chiaro" $(( RC != 0 && ! ${#OUTS} && ${#${(M)LOG:#*riconoscere*}} )) "${${LOG##*: }[1,60]}"
  for f in numeri.txt vuoto.txt; do
    act $W/tra $f -- --run --tools "In inglese" $f
    check K "$f: nessun testo, nessun file" $(( RC != 0 && ! ${#OUTS} )) "${${LOG##*: }[1,50]}"
  done
  t0=$EPOCHREALTIME
  act $W/tra enorme.txt -- --run --tools "In italiano" enorme.txt
  check K "oltre 2 milioni di caratteri: rifiutato subito" $(( RC != 0 && ! ${#OUTS} && EPOCHREALTIME - t0 < 3 )) "$(printf '%.1f s' $(( EPOCHREALTIME - t0 )))"
  print "riservato" > lock.txt && textutil -convert rtf lock.txt -output lock.rtf && $M --run PDF lock.rtf >/dev/null 2>&1
  RONDELLE_VALUE=password-lunga-1 $M --run --tools Password lock.pdf >/dev/null 2>&1
  act $W/tra "lock (protetto).pdf" -- --run --tools "In inglese" "lock (protetto).pdf"
  check K "PDF con password: rifiutato" $(( RC != 0 && ! ${#OUTS} )) "${${LOG##*: }[1,50]}"
  print -n "non un pdf" > finto.pdf
  act $W/tra finto.pdf -- --run --tools "In inglese" finto.pdf
  check K "PDF finto: errore, nessun file" $(( RC != 0 && ! ${#OUTS} )) "${${LOG##*: }[1,50]}"
  lst=$($M --list --tools a.pages 2>/dev/null | tr '\n' ' ')
  check K "Pages: niente «Traduci» sulla ruota" $(( ! ${#${(M)lst:#*Traduci*}} )) "$lst"
fi

# MARK: K2 — the language is read from the whole text, not from its first lines

if wants K; then
  print "\n== K · Lingua riconosciuta su tutto il testo"
  mkdir -p $W/lingua && cd $W/lingua
  python3 -I -c "
it = 'Il progetto trae ispirazione da un altro prodotto, ma deve costruire una identita autonoma e riconoscibile, adatta alla pubblicazione e a una possibile evoluzione futura.'
en = 'The garden is very beautiful in spring, the birds sing all day long and the children play outside until the sun goes down behind the hills.'
fr = 'Nous sommes partis tot le matin pour voir le lever du soleil sur la montagne, et nous sommes rentres a la maison avant la tombee de la nuit.'
titolo = '# Rebranding Brief\n**Brand identity, visual system and open-source presentation**\n> Every file has a way out.\n\n'
open('titolo-en.md', 'w').write(titolo + (it + '\n\n') * 20)
open('titolo-it.md', 'w').write('# Il progetto e la sua storia\n**Identita visiva e presentazione del lavoro**\n\n' + (en + '\n\n') * 20)
open('titolo-fr.txt', 'w').write('Rebranding Brief. Every file has a way out of the roundabout, always and for everyone in town.\n\n' + (fr + '\n\n') * 20)
open('meta.txt', 'w').write((it + '\n\n') * 10 + (en + '\n\n') * 10)
open('coda-en.txt', 'w').write((it + '\n\n') * 20 + (en + '\n\n') * 2)"
  cp titolo-en.md documento-italiano.md
  out=$($M --run --tools "In inglese" titolo-en.md 2>&1); rc=$?
  check K "italiano con titolo inglese: si traduce in inglese" $(( rc == 0 && ${$(grep -c 'project' "titolo-en (inglese).md" 2>/dev/null):-0} > 10 )) "rc $rc, ${${out##*/}[1,60]}"
  out=$($M --run --tools "In italiano" titolo-en.md 2>&1); rc=$?
  check K "italiano con titolo inglese: «è già in italiano»" $(( rc == 1 && ${#${(M)out:#*già in italiano*}} )) "rc $rc, ${${out##*: }[1,60]}"
  out=$($M --run --tools "In italiano" documento-italiano.md 2>&1); rc=$?
  check K "il nome del file non conta" $(( rc == 1 && ${#${(M)out:#*già in italiano*}} )) "rc $rc"
  out=$($M --run --tools "In inglese" titolo-it.md 2>&1); rc=$?
  check K "inglese con titolo italiano: «è già in inglese»" $(( rc == 1 && ${#${(M)out:#*già in inglese*}} )) "rc $rc, ${${out##*: }[1,60]}"
  out=$($M --run --tools "In francese" titolo-fr.txt 2>&1); rc=$?
  check K "francese con titolo inglese: «è già in francese»" $(( rc == 1 && ${#${(M)out:#*già in francese*}} )) "rc $rc, ${${out##*: }[1,60]}"
  out=$($M --run --tools "In francese" meta.txt 2>&1); rc=$?
  check K "metà italiano e metà inglese: chiede la lingua" $(( rc == 1 && ${#${(M)out:#*non riesco a riconoscere*}} )) "rc $rc, ${${out##*: }[1,60]}"
  out=$($M --run --tools "In italiano" coda-en.txt 2>&1); rc=$?
  check K "citazioni inglesi in coda: resta italiano" $(( rc == 1 && ${#${(M)out:#*già in italiano*}} )) "rc $rc, ${${out##*: }[1,60]}"
fi

# MARK: L — pipes, sockets and devices (B1): refused at once, nothing waits on them

if wants L; then
  print "\n== L · File speciali"
  mkdir -p $W/spec/cart $W/spec/cart2 && cd $W/spec
  for e in pdf zip txt docx html; do
    [[ -p f.$e ]] || mkfifo f.$e
    ln -sf $W/spec/f.$e lf.$e
  done
  for e in txt pdf zip docx; do ln -sf /dev/zero z.$e; done
  [[ -S s.txt ]] || python3 -I -c "import socket;socket.socket(socket.AF_UNIX).bind('s.txt')"
  [[ -p cart/dentro.txt ]] || mkfifo cart/dentro.txt
  print ciao > cart/ok.txt; ln -sf /dev/zero cart2/zero.txt; print ciao > cart2/ok.txt
  print "The cat sleeps on the table while the rain falls outside the old house." > vero.txt; ln -sf $W/spec/vero.txt lvero.txt
  fermo() { perl -e 'alarm 8; exec @ARGV' $M "$@" 2>&1 }
  for f in f.pdf f.zip f.txt f.docx f.html lf.pdf lf.zip lf.txt z.txt z.pdf z.zip z.docx s.txt; do
    out=$(fermo --test-main-block $f); rc=$?
    ms=${${out%% ms*}%%.*}
    check L "$f: thread principale libero (< 100 ms), rifiutato" $(( rc == 0 && ms < 100 && ${#${(M)out:#*rifiutato*}} )) "rc $rc, $out"
  done
  for f in f.pdf f.txt f.docx lf.pdf z.txt z.pdf s.txt; do
    out=$(fermo --run --tools "In inglese" $f); rc=$?
    check L "$f: «Traduci» rifiuta con un messaggio chiaro" $(( rc == 1 && ${#${(M)out:#*non è un file normale*}} )) "rc $rc, ${out[1,60]}"
  done
  for a in "--run TXT f.pdf" "--run PDF f.docx" "--run --tools ZIP f.txt" "--run --tools Dividi lf.pdf"; do
    out=$(fermo ${=a}); rc=$?
    check L "$a: rifiutato" $(( rc == 1 && ${#${(M)out:#*non è un file normale*}} )) "rc $rc"
  done
  out=$(fermo --run ZIP cart); rc=$?
  check L "cartella con un FIFO, ZIP: rifiuto che dice quale file" $(( rc == 1 && ${#${(M)out:#*dentro.txt*}} )) "rc $rc, ${out[1,60]}"
  out=$(RONDELLE_VALUE=password-lunga-1 fermo --run --tools "ZIP protetto" cart); rc=$?
  check L "cartella con un FIFO, ZIP protetto: rifiuto" $(( rc == 1 && ${#${(M)out:#*dentro.txt*}} )) "rc $rc"
  out=$(fermo --run ZIP cart2); rc=$?
  check L "cartella con un link a /dev/zero: il link resta un link" $(( rc == 0 && $(stat -f %z cart2.zip) < 100000 )) "rc $rc, $(stat -f %z cart2.zip) byte"
  out=$(fermo --test-main-block lvero.txt); rc=$?
  check L "link a un file normale: accettato" $(( rc == 0 && ${#${(M)out:#*accettato*}} )) "$out"
  out=$(fermo --run --tools "In francese" lvero.txt); rc=$?
  check L "link a un file normale: tradotto" $(( rc == 0 && ${#${(M)out:#*francese*}} )) "${out:t}"
fi

# MARK: M — data about this Mac in outputs (C2), invalid documents (D2), the words on translation (C1), attempts

if wants M; then
  print "\n== M · Dati del Mac, documenti non validi, tentativi"
  mkdir -p $W/mac/in $W/mac/out && cd $W/mac/in
  print "The garden is very beautiful in spring and the birds sing all day long." > src.txt
  for e in rtf docx html odt; do textutil -convert $e src.txt -output src.$e; done
  cp src.txt src.md; print -l 1 "00:00:01,000 --> 00:00:02,000" "The garden is very beautiful in spring and the birds sing." > src.srt
  $M --run PDF src.rtf >/dev/null; mv src.pdf srcpdf.pdf
  python3 -I -c "
import csv
w = csv.writer(open('foglio.csv', 'w', newline='')); w.writerow(['nome', 'valore']); w.writerow(['uno', 1])"
  sips -s format png -z 64 64 "/Library/User Pictures/Animals/Parrot.heic" --out foto.png >/dev/null 2>&1
  raccogli() { local tag=$1 o; while read -r o; do [[ -f $o ]] && mv "$o" "../out/$tag-${o:t}"; done }
  for f in src.txt src.md src.rtf src.docx src.html src.odt src.srt srcpdf.pdf; do $M --run --tools "In italiano" $f 2>&1 | raccogli T; done
  for f in src.docx src.rtf; do for a in PDF DOCX RTF ODT HTML TXT; do
    [[ ${f:e} == ${(L)a} ]] && continue
    $M --run $a $f 2>&1 | raccogli C-${f:e}
  done; done
  for a in TXT DOCX RTF; do $M --run $a srcpdf.pdf 2>&1 | raccogli C-pdf; done
  for a in PDF HTML; do $M --run $a foglio.csv 2>&1 | raccogli C-csv; done
  $M --run PDF foto.png 2>&1 | raccogli C-img
  cd ../out
  outs=(*(N.))
  hits=$(python3 -I $LIB/macdata.py $outs 2>&1)
  check M "${#outs} uscite: nessun dato del Mac (byte, ZIP, flussi PDF, XMP)" $(( ${#outs} >= 20 && ! ${#hits} )) "${${hits//$'\n'/ | }[1,100]}"
  for f in *.docx(N) *.odt(N); do
    unzip -tqq "$f" >/dev/null 2>&1; rc=$?
    t=$(textutil -convert txt -stdout "$f" 2>/dev/null)
    check M "$f: archivio integro e testo leggibile" $(( rc == 0 && ${#t} > 10 )) "rc $rc"
  done
  for f in *.rtf(N) *.html(N); do
    t=$(textutil -convert txt -stdout "$f" 2>/dev/null)
    check M "$f: si rilegge" $(( ${#t} > 10 )) "${${t//$'\n'/ }[1,30]}"
  done
  for f in *.pdf(N); do check M "$f: PDF con Producer neutro" $(( $(grep -ac 'Producer (Rondelle' "$f") || ! $(grep -ac Producer "$f") )) ""; done

  # The PDFs of the tools too (a PDF with a password has its Producer encrypted with the rest).
  mkdir -p $W/mac/tool && cd $W/mac/tool
  cp $W/mac/out/C-img-foto.pdf a.pdf
  for a in Comprimi Dividi OCR Numeri Metadati; do $M --run --tools $a a.pdf >/dev/null 2>&1; done
  RONDELLE_VALUE=RISERVATO $M --run --tools Filigrana a.pdf >/dev/null 2>&1
  RONDELLE_VALUE=password-lunga-1 $M --run --tools Password a.pdf >/dev/null 2>&1
  RONDELLE_VALUE=password-lunga-1 $M --run --tools Sblocca "a (protetto).pdf" >/dev/null 2>&1
  rm -f -- "a (protetto).pdf" a.pdf
  outs=(**/*.pdf(N.))
  hits=$(python3 -I $LIB/macdata.py $outs 2>&1)
  check M "${#outs} PDF degli strumenti: nessun dato del Mac" $(( ${#outs} >= 5 && ! ${#hits} )) "${${hits//$'\n'/ | }[1,100]}"

  cd $W/mac/in
  print -n "non è affatto un documento Word, ma testo qualsiasi con parole italiane dentro" > finto.doc
  cp finto.doc finto.docx; cp finto.doc finto.odt; cp finto.doc finto.rtf
  for f in finto.doc finto.rtf; do
    for a in "--tools In inglese" "TXT" "PDF"; do
      azione=${a#--tools }; act $W/mac/in $f -- --run ${${(M)a:#--tools*}:+--tools} "$azione" $f
      check M "$f, $azione: rifiuto, nessun file" $(( RC != 0 && ! ${#OUTS} )) "${${LOG##*: }[1,60]}"
    done
  done
  for f in finto.docx finto.odt; do
    act $W/mac/in $f -- --run --tools "In inglese" $f
    check M "$f: rifiuto, nessun file" $(( RC != 0 && ! ${#OUTS} )) "${${LOG##*: }[1,60]}"
  done
  print "The cat sleeps on the table while the rain falls outside the old house." > w.txt; textutil -convert doc w.txt -output vero.doc
  act $W/mac/in vero.doc -- --run --tools "In italiano" vero.doc
  check M "un vero .doc si traduce ancora" $(( RC == 0 && ${#OUTS} == 1 )) "${OUTS[1]:t}"
  print "El gato duerme sobre la mesa mientras la lluvia cae fuera de la vieja casa y los niños juegan." > es.txt
  for pair in "it spagnolo" "en Spanish" "fr espagnol"; do
    l=${pair% *}; w=${pair#* }
    out=$(RONDELLE_RESOURCES=$ROOT/Resources RONDELLE_LANG=$l $M --run --tools "In inglese" es.txt 2>&1)
    check M "lingua dell'interfaccia $l: il messaggio dice «$w»" $(( ${#${(M)out:#*$w*}} )) "${out[1,80]}"
  done

  for frase in "secondo Apple" ; do
    check M "tutorial e README dicono «$frase»" $(( $(grep -c "$frase" $ROOT/Sources/Rondelle/Tutorial.swift) >= 2 && $(grep -c 'according to Apple' $ROOT/README.md) >= 2 )) ""
  done
  check M "nessuna frase «traduce sul Mac» né «Tutto in locale»" $(( ! $(cat $ROOT/Sources/Rondelle/*.swift $ROOT/README.md $ROOT/distribution/README.txt | grep -c -e 'traduce sul Mac' -e 'Tutto in locale' -e 'Tutto avviene sul Mac' -e 'Everything runs on your Mac' -e 'Everything happens on your Mac') )) ""
  check M "avviso sul testo nascosto in it, en, fr" $(( $(grep -c 'testo nascosto, bianco o coperto' $ROOT/Sources/Rondelle/Tutorial.swift) && $(grep -c 'hidden, white or covered' $ROOT/Resources/en.lproj/Localizable.strings) && $(grep -c 'masqué, blanc ou recouvert' $ROOT/Resources/fr.lproj/Localizable.strings) )) ""

  # The way the warning says: the page as an image, where nothing under the box exists any more.
  python3 -I $LIB/mkhidden.py nascosto.pdf
  $M --run PNG nascosto.pdf >/dev/null 2>&1
  png=(nascosto*.png(N) nascosto*/*.png(N))
  $M --run --tools Testo "$png[1]" >/dev/null 2>&1
  t=$(cat nascosto*.txt(N) "${png[1]:r}".txt(N) 2>/dev/null | sort -u)
  check M "PDF con testo coperto → immagine: il testo coperto e quello bianco spariscono" $(( ${#png} && ${#${(M)t:#*giardino*}} && ! ${#${(M)t:#*CANARINO*}} )) "${${t//$'\n'/ }[1,70]}"

  print "The cat sleeps on the table while the rain falls outside the old house." > t.txt
  out=$(RONDELLE_TRANSLATION_FAIL=1 RONDELLE_TRANSLATION_TRACE=1 $M --run --tools "In italiano" t.txt 2>&1); rc=$?
  check M "primo tentativo fallito: il secondo riesce" $(( rc == 0 && $(print -r -- "$out" | grep -c 'secondo tentativo') == 1 )) "rc $rc"
  out=$(RONDELLE_TRANSLATION_FAIL=9 RONDELLE_TRANSLATION_TRACE=1 $M --run --tools "In italiano" t.txt 2>&1); rc=$?
  check M "sempre fallito: 2 tentativi, errore mostrato" $(( rc == 1 && $(print -r -- "$out" | grep -c 'secondo tentativo') == 1 && ${#${(M)out:#*errore simulato*}} )) "${${out##*: }[1,70]}"
  scatti=0; riusciti=0
  for i in {1..20}; do
    out=$(RONDELLE_TRANSLATION_TRACE=1 $M --run --tools "In italiano" t.txt 2>&1) && riusciti=$((riusciti + 1))
    scatti=$(( scatti + $(print -r -- "$out" | grep -c 'secondo tentativo') ))
  done
  check M "20 traduzioni: tutte riuscite; secondi tentativi $scatti" $(( riusciti == 20 )) "riuscite $riusciti, secondi tentativi $scatti"
fi

# MARK: N — PDFs built to expand when their text is read

if wants N; then
  print "\n== N · PDF che si espandono alla lettura del testo"
  mkdir -p $W/pdftext && cd $W/pdftext
  crea() { [[ -f $1.pdf ]] || python3 -I $LIB/mkpdftext.py $1.pdf $2 $3 $4; }
  # misura SECONDS ARGS: sets PEAK (MB), SECS, MRC, STATE and LAST.
  misura() {
    local t=$1; shift
    local r=$(python3 -I $LIB/ram.py --timeout $t -- $M "$@" 2>&1)
    PEAK=${r%% *}; r=${r#* }; SECS=${r%% *}; r=${r#* }; MRC=${r%% *}; r=${r#* }; STATE=${r%% *}; LAST=${r#* }
  }
  float_lt() { python3 -I -c "import sys; sys.exit(0 if float('$1') < $2 else 1)" }
  rifiuto() { [[ $MRC == 1 && $LAST == *"troppo "* ]] }
  uscite() { local o=(*.(txt|docx|rtf)(N) *\(inglese\)*(N) *ricercabile*(N)); print ${#o}; rm -f -- $o }
  # A refusal: at once, with little memory, and nothing written.
  rifiutato() {   # NAME ACTION…
    local f=$1; shift
    misura 60 "$@" $f.pdf
    local left=$(uscite)
    check N "$f, ${*[-1]}: rifiuto in < 2 s, < 500 MB, nessun file" $(( $(rifiuto && float_lt $SECS 2 && echo 1 || echo 0) && PEAK < 500 && left == 0 )) "$PEAK MB, $SECS s, ${LAST[1,50]}"
  }

  # The four PDFs of the audit, every way of reading them
  for c in "p4k 10000" "p18k 50000" "p71k 200000" "p530k 1500000"; do
    a=(${=c}); crea $a[1] righe $a[2]
    rifiutato $a[1] --run TXT; rifiutato $a[1] --run DOCX; rifiutato $a[1] --run RTF
    rifiutato $a[1] --run --tools "In inglese"; rifiutato $a[1] --run --tools OCR
  done

  # «Annulla» while scanning: 20 million operators and no text
  crea tuttiop qq 9999999
  misura 60 --test-cancel 0.2 TXT tuttiop.pdf
  check N "Annulla a 0,2 s durante la scansione: < 1 s, nessun file" $(( $([[ $LAST == annullata* ]] && float_lt $SECS 1.2 && echo 1 || echo 0) )) "$SECS s, ${LAST[1,50]}"
  uscite >/dev/null

  # The limits: exactly at each one passes, one over is refused
  limite() {   # NAME-OK NAME-NO KIND N-OK N-NO [M]
    crea $1 $3 $4 $6; crea $2 $3 $5 $6
    misura 60 --run TXT $1.pdf
    check N "$3 al tetto ($4): non rifiutato, < 500 MB" $(( $(rifiuto && echo 0 || echo 1) && PEAK < 500 && $([[ $STATE == ok ]] && echo 1 || echo 0) )) "$PEAK MB, $SECS s"
    uscite >/dev/null
    rifiutato $2 --run TXT
  }
  limite cpag cpag1 caratteri 500000 500001
  limite som som1 somma 2000000 2000001 4
  limite som300 som3001 somma 2000000 2000001 300
  limite topag topag1 vuoti 500000 500001
  limite tjpag tjpag1 tj 500000 500001 1
  limite fc fc1 formavuota 200000 200001
  limite prof prof1 annidata 8 9 1
  limite ops ops1 qq 9999999 10000001

  # The variants
  crea tj1 tj 1000 2000;            rifiutato tj1 --run TXT       # many short strings in TJ arrays
  crea str stringa 20000000;        rifiutato str --run TXT       # one huge string
  crea inv invisibile 200000;       rifiutato inv --run TXT       # invisible text (Tr 3)
  crea api apici 200000;            rifiutato api --run TXT       # the ' and " operators
  crea flu flussi 200 1000;         rifiutato flu --run TXT       # the same stream many times on a page
  crea for forma 1000 200;          rifiutato for --run TXT       # a form drawn many times
  crea nid annidata 6 10;           rifiutato nid --run TXT       # nested forms
  crea cic ciclo 1;                 rifiutato cic --run TXT       # a form that draws itself
  crea pag pagine 50 1369;          rifiutato pag --run TXT       # moderate pages adding up
  crea t3 type3 20000 200;          rifiutato t3 --run TXT        # Type 3 font with dear glyphs
  crea tou tounicode 100 200;       rifiutato tou --run TXT       # ToUnicode: one byte, 200 characters
  crea pes toupesante 500;          rifiutato pes --run TXT       # a ToUnicode map of 500 MB

  # Ordinary PDFs: not refused, and their text is all there
  python3 -I -c "
for i in range(14000): print(f'riga{i:06d} il gatto dorme sul tavolo mentre la pioggia cade fuori dalla vecchia casa')" > lungo.txt
  textutil -convert rtf lungo.txt -output lungo.rtf; rm -f lungo.txt
  $M --run PDF lungo.rtf >/dev/null
  misura 120 --run TXT lungo.pdf
  check N "PDF normale di molte pagine: letto per intero" $(( ${$(grep -c '^riga' lungo.txt 2>/dev/null):-0} == 14000 && PEAK < 500 )) "${$(grep -c '^riga' lungo.txt 2>/dev/null):-0} righe su 14000, $PEAK MB"
  uscite >/dev/null
  python3 -I -c "
for i in range(30): print('Il giardino e molto bello in primavera e gli uccelli cantano tutto il giorno.')" > scan.txt
  textutil -convert rtf scan.txt -output scan.rtf; rm -f scan.txt
  $M --run PDF scan.rtf >/dev/null; mkdir -p sc; $M --run PNG scan.pdf >/dev/null; mv scan.png sc/s.png; rm -f scan.pdf
  (cd sc && $M --run PDF s.png >/dev/null && $M --run --tools OCR s.pdf >/dev/null && $M --run TXT "s (ricercabile).pdf" >/dev/null)
  check N "PDF con livello OCR invisibile: testo letto" $(( ${$(grep -c 'giardino' "sc/s (ricercabile).txt" 2>/dev/null):-0} > 20 )) "$(grep -c 'giardino' "sc/s (ricercabile).txt" 2>/dev/null) righe su 30"

  # OCR: «Annulla» during the only page leaves nothing behind
  crea unapag corti 500000
  misura 60 --test-cancel --tools 1 OCR unapag.pdf
  check N "OCR, Annulla durante l'unica pagina: nessun file" $(( $([[ $LAST == annullata*rimasti:* && $LAST != *ricercabile* ]] && echo 1 || echo 0) )) "$SECS s, ${LAST[1,60]}"
  rm -f -- *ricercabile*(N)
fi

# MARK: O — tools that draw, compressed streams, documents that expand

if wants O; then
  print "\n== O · Strumenti che disegnano, flussi compressi, documenti che si espandono"
  mkdir -p $W/espansi && cd $W/espansi
  crea() { [[ -f $1.pdf ]] || python3 -I $LIB/mkpdftext.py $1.pdf $2 $3 $4; }
  doc() { [[ -e $1 ]] || python3 -I $LIB/mkdocs.py $1 $2 $3; }
  misura() {
    local t=$1; shift
    local r=$(python3 -I $LIB/ram.py --timeout $t -- $M "$@" 2>&1)
    PEAK=${r%% *}; r=${r#* }; SECS=${r%% *}; r=${r#* }; MRC=${r%% *}; r=${r#* }; STATE=${r%% *}; LAST=${r#* }
  }
  float_lt() { python3 -I -c "import sys; sys.exit(0 if float('$1') < $2 else 1)" }
  pulisci() { find . -mindepth 1 -maxdepth 1 -newer $W/espansi/.inizio ! -name .inizio -exec rm -rf {} + 2>/dev/null; }
  : > .inizio
  # Refused at once, little memory, nothing written. The file itself stays: it was made before .inizio is touched.
  rifiuta() {   # FILE ARGS…
    local f=$1; shift
    touch .inizio; sleep 1
    misura 90 "$@" $f
    local left=$(find . -mindepth 1 -maxdepth 1 -newer .inizio | wc -l | tr -d ' ')
    local ok=0
    [[ $MRC == 1 && $LAST == *troppo* ]] && float_lt $SECS ${ENTRO:-2} && ok=1
    check O "$f, ${*[-1]}: rifiuto in < ${ENTRO:-2} s, < 500 MB, nessun file" $(( ok && PEAK < 500 && left == 0 )) "$PEAK MB, $SECS s, $STATE, ${LAST[1,50]}"
    pulisci
  }
  passa() {   # FILE LIMIT_SECONDS ARGS…
    local f=$1 lim=$2; shift 2
    touch .inizio; sleep 1
    misura 120 "$@" $f
    local ok=0
    [[ $MRC == 0 && $LAST != *troppo* && $STATE == ok ]] && float_lt $SECS $lim && ok=1
    check O "$f, ${*[-1]}: non rifiutato, < 500 MB, < $lim s" $(( ok && PEAK < 500 )) "$PEAK MB, $SECS s, ${LAST[1,50]}"
    pulisci
  }

  # N1: every tool that draws
  crea b5 righe 15000000   # 5 MB that unpack to 1.6 GB: 1 GB of it is read before the refusal
  ENTRO=4
  rifiuta b5.pdf --run PNG; rifiuta b5.pdf --run --tools Comprimi; rifiuta b5.pdf --run --tools Numeri; rifiuta b5.pdf --run --tools OCR
  RONDELLE_VALUE=RISERVATO rifiuta b5.pdf --run --tools Filigrana
  ENTRO=2
  crea qqa qq 9999999
  touch .inizio; sleep 1
  misura 60 --test-cancel --tools 0.2 Comprimi qqa.pdf
  check O "Comprimi, Annulla a 0,2 s durante la scansione: < 1 s" $(( $([[ $LAST == annullata* ]] && float_lt $SECS 1.2 && echo 1 || echo 0) )) "$SECS s, ${LAST[1,50]}"
  pulisci
  crea corti corti 500000
  touch .inizio; sleep 1
  misura 60 --test-cancel --tools 0.5 Comprimi corti.pdf
  check O "Comprimi, Annulla sull'unica pagina al tetto: nessun file" $(( $([[ $LAST == annullata*rimasti:* && $LAST != *compresso* ]] && echo 1 || echo 0) )) "$SECS s, ${LAST[1,60]}"
  pulisci
  # A long document is fine when drawn page by page, over the limits for reading its text
  crea lungo somma 3000000 20
  rifiuta lungo.pdf --run TXT
  passa lungo.pdf 30 --run --tools Numeri
  crea pag1 caratteri 500000; passa pag1.pdf 30 --run --tools Numeri
  crea pag2 caratteri 500001; rifiuta pag2.pdf --run --tools Numeri

  # N2: compressed streams
  crea num numeri 50000000;         rifiuta num.pdf --run TXT; rifiuta num.pdf --run PNG
  crea numx numerix 25000000;       rifiuta numx.pdf --run TXT
  crea dop doppio 50000000;         rifiuta dop.pdf --run TXT
  # N2 residual: filters in front of the compression, names with #xx, a filter held in another object
  for k in a85 ahx hash indiretto; do crea f$k $k 50000000; rifiuta f$k.pdf --run TXT; done
  for k in lzw lzwa85; do crea f$k $k 12000000; rifiuta f$k.pdf --run TXT; done
  for k in a85normale lzwnormale; do crea f$k $k 2000; passa f$k.pdf 30 --run TXT; done
  # N2 residual: encrypted, with no password to type or with the owner's; the same numbers inside
  for k in rc4-40 rc4-128 aes-128 aes-256; do
    python3 -I $LIB/mkpdfenc.py c$k.pdf $k numeri 50000000; rifiuta c$k.pdf --run TXT; rifiuta c$k.pdf --run --tools Dividi
    python3 -I $LIB/mkpdfenc.py d$k.pdf $k righe 2000; passa d$k.pdf 30 --run TXT
    python3 -I $LIB/mkpdfenc.py e$k.pdf $k numeri 50000000 segreta123; RONDELLE_VALUE=proprietario rifiuta e$k.pdf --run --tools Sblocca
  done
  crea strs stringhevuote 20000000; rifiuta strs.pdf --run TXT
  crea numb numeribinari 20000000;  rifiuta numb.pdf --run TXT
  crea numok numeri 1000000;        passa numok.pdf 30 --run --tools Numeri
  crea num1 numeri 1000001;         rifiuta num1.pdf --run --tools Numeri
  crea bug toubugiarda 3000;        rifiuta bug.pdf --run TXT
  # A large blank image: not refused for drawing, nor for reading its one line of text
  crea img immagine 200;            passa img.pdf 30 --run TXT; passa img.pdf 60 --run --tools Numeri

  # N6: what PDFKit rewrites, with nothing that stops it (N7: and the thumbnails of the Merge window)
  ENTRO=4
  chiuso() { [[ -f $1.pdf ]] || { RONDELLE_VALUE=password-lunga-1 $M --run --tools Password $2 >/dev/null 2>&1; mv ${2:r}*protetto*.pdf $1.pdf; } }
  chiuso b5p b5.pdf
  rifiuta b5.pdf --run --tools Dividi; rifiuta b5.pdf --run --tools Metadati; rifiuta b5.pdf --test-merge-open
  rifiuta "b5.pdf#1" --assemble fuori.pdf
  RONDELLE_VALUE=password-lunga-1 rifiuta b5p.pdf --run --tools Sblocca
  ENTRO=2
  rifiuta num.pdf --run --tools Dividi; rifiuta num.pdf --run --tools Metadati; rifiuta num.pdf --test-merge-open
  rifiuta "num.pdf#1" --assemble fuori.pdf
  # At the limits on the whole file. Over them only for what can't be stopped: «Dividi» goes page by page.
  crea tj2 cortipagine 4 500000;    passa tj2.pdf 40 --run --tools Metadati
  crea tj3 cortipagine 5 400001;    rifiuta tj3.pdf --run --tools Metadati; rifiuta tj3.pdf --test-merge-open
  passa tj3.pdf 60 --run --tools Dividi
  crea car somma 100000000 200;     passa car.pdf 40 --run --tools Metadati
  crea car1 somma 100000001 201;    rifiuta car1.pdf --run --tools Metadati
  passa pag1.pdf 30 --test-merge-open; passa pag1.pdf 30 --run --tools Metadati; passa lungo.pdf 30 --run --tools Dividi
  rifiuta pag2.pdf --test-merge-open
  # «Password» doesn't read the pages: 2 GB of numbers cost it nothing, so nothing is refused
  RONDELLE_VALUE=password-lunga-1 passa num.pdf 5 --run --tools Password

  # N3: documents that unpack
  doc odt-testo.odt odt-testo 300; rifiuta odt-testo.odt --run TXT; rifiuta odt-testo.odt --run --tools "In inglese"
  doc odt-stili.odt odt-stili 200; rifiuta odt-stili.odt --run TXT
  doc odt-tab.odt odt-tab 200;     rifiuta odt-tab.odt --run TXT
  doc bugiardo.odt odt-bugiardo 300; rifiuta bugiardo.odt --run TXT
  doc bomba.docx docx-testo 300;   rifiuta bomba.docx --run TXT
  doc tetto.odt odt-esatto 30000000;   passa tetto.odt 15 --run TXT
  doc oltre.odt odt-esatto 30000001;   rifiuta oltre.odt --run TXT
  doc foto.odt odt-foto 9;             passa foto.odt 15 --run TXT

  # N4: web archives
  doc web-tab.webarchive web-tab 1950000;     rifiuta web-tab.webarchive --run TXT
  doc web-stili.webarchive web-stili 1950000; rifiuta web-stili.webarchive --run TXT
  doc web-cornici.webarchive web-cornici 100000; rifiuta web-cornici.webarchive --run TXT
  doc web-ok.webarchive web-elementi 25000;   passa web-ok.webarchive 15 --run TXT
  doc web-no.webarchive web-elementi 25001;   rifiuta web-no.webarchive --run TXT

  # N5: HTML and RTF
  doc tab.html html-tab 1950000;       rifiuta tab.html --run TXT
  doc h-ok.html html-elementi 100000;  passa h-ok.html 5 --run TXT
  doc h-no.html html-elementi 100001;  rifiuta h-no.html --run TXT
  cp h-no.html h-no.doc;               rifiuta h-no.doc --run TXT
  doc r-nest.rtf rtf-nest 45000000;    rifiuta r-nest.rtf --run TXT; rifiuta r-nest.rtf --run --tools "In inglese"
  doc r-ok.rtf rtf-celle 500000;       passa r-ok.rtf 15 --run TXT
  doc r-no.rtf rtf-celle 500001;       rifiuta r-no.rtf --run TXT
  doc r-pkg.rtfd rtfd-celle 500001;    rifiuta r-pkg.rtfd --run TXT
fi

# MARK: P — documents that keep their pages

if wants P; then
  print "\n== P · PDF → Word e Word → PDF"
  mkdir -p $W/pagine && cd $W/pagine
  crea() { [[ -f $1.pdf ]] || python3 -I $LIB/mkpdfword.py $1.pdf $2 ${3:-}; }
  # docx FILE: what a DOCX holds, as one line of key=value; an error if it isn't a valid package
  docx() { python3 -I $LIB/mkpdfword.py --leggi $1; }
  # Converts (old results first removed); RC, ESITO (the line above) and LOG
  a_docx() { local f=$1; rm -f ${f:r}.docx; LOG=$($M --run DOCX $f 2>&1); RC=$?; ESITO=$(docx ${f:r}.docx 2>&1); }
  ha() { [[ " $ESITO " == *" $1 "* ]]; }
  sips -s format jpeg --setProperty formatOptions 80 $W/src/foto.jpg --out luogo.jpg >/dev/null 2>&1

  crea due normale 2; a_docx due.pdf
  check P "PDF di 2 pagine → DOCX di 2 pagine" $(( RC == 0 && $(ha pagine=2 && echo 1 || echo 0) )) "$ESITO"
  check P "A4 mantenuto" $(( $(ha pgsz=11900x16840 && echo 1 || echo 0) )) "$ESITO"
  check P "Paragrafi veri, non una riga per paragrafo" $(( $(ha righe=20/paragrafi=4 && echo 1 || echo 0) )) "$ESITO"
  check P "Immagine e disegni presenti" $(( $(ha immagini=1 && ha disegni=2 && echo 1 || echo 0) )) "$ESITO"
  check P "Nessun metadato del sistema né XML non valido" $(( $(ha xml=ok && ha docprops=0 && echo 1 || echo 0) )) "$ESITO"
  crea orizz orizzontale; a_docx orizz.pdf
  check P "Pagina orizzontale: larghezza > altezza" $(( $(ha pgsz=16840x11900 && echo 1 || echo 0) )) "$ESITO"
  crea ruota ruotata; a_docx ruota.pdf
  check P "Pagina con /Rotate 90: orizzontale, testo presente" $(( $(ha pgsz=16840x11900 && echo 1 || echo 0) && $(ha testo=si && echo 1 || echo 0) )) "$ESITO"
  crea col colonne; a_docx col.pdf
  check P "Tabella o colonne: tabulazioni" $(( $(ha tab=4 && echo 1 || echo 0) )) "$ESITO"
  crea idx indicizzata; a_docx idx.pdf
  check P "Immagine a colori indicizzati letta" $(( RC == 0 && $(ha immagini=1 && echo 1 || echo 0) )) "$ESITO"
  crea trasp trasparente; a_docx trasp.pdf
  check P "Immagine con trasparenza letta" $(( RC == 0 && $(ha immagini=1 && echo 1 || echo 0) )) "$ESITO"
  crea ocr scansione; a_docx ocr.pdf
  check P "Scansione con testo nascosto: testo sì, immagine di copertura no" $(( $(ha testo=si && ha immagini=0 && echo 1 || echo 0) )) "$ESITO"
  crea xmlc caratteri; a_docx xmlc.pdf
  check P "Testo con & < > e virgolette: XML valido" $(( RC == 0 && $(ha xml=ok && echo 1 || echo 0) )) "$ESITO"
  crea vuoto senzatesto; rm -f vuoto.docx; LOG=$($M --run DOCX vuoto.pdf 2>&1); RC=$?
  check P "Senza testo: errore come prima, nessun file" $(( RC != 0 )) "${LOG[1,70]}"
  check P "… e nessun file lasciato" $(( ! $(print -l vuoto*.docx(N) .rondelle*(N) | grep -c .) )) ""
  if [[ -f $W/src/foto.jpg ]]; then
    crea gps conjpeg $W/src/foto.jpg; a_docx gps.pdf
    check P "Foto con posizione nel PDF: nel DOCX senza GPS né EXIF" $(( RC == 0 && $(ha immagini=1 && ha exif=0 && echo 1 || echo 0) )) "$ESITO"
  fi
  rm -f due.rtf; LOG=$($M --run RTF due.pdf 2>&1); RC=$?
  check P "RTF da PDF: testo unito in paragrafi" $(( RC == 0 && $(grep -c 'il gatto dorme' due.rtf) >= 1 )) "${LOG[1,60]}"

  rm -f due.docx; LOG=$($M --run "Senza formattazione" due.pdf 2>&1); RC=$?
  x=$(unzip -p due.docx word/document.xml 2>/dev/null)
  check P "Senza formattazione: testo, nessuna immagine né pagina forzata" $(( RC == 0 && ${#x} > 500 && ! $(unzip -l due.docx | grep -c media/) && ! $(print -r -- $x | grep -c pageBreakBefore) && $(print -r -- $x | grep -c 'il gatto dorme') )) "${LOG[1,60]}"

  # Word → PDF
  w() { python3 -I $LIB/mkpdfword.py --word $1 $2; }
  w lett.docx normale; rm -f lett.pdf; $M --run PDF lett.docx >/dev/null 2>&1
  check P "DOCX → PDF: A5 mantenuto, 2 pagine, immagine" $(( $(python3 -I $LIB/mkpdfword.py --pdf lett.pdf) == 1 )) "$(python3 -I $LIB/mkpdfword.py --pdf-info lett.pdf)"
  w od.odt odt; rm -f od.pdf; $M --run PDF od.odt >/dev/null 2>&1
  check P "ODT → PDF: immagine e pagina A5" $(( $(python3 -I $LIB/mkpdfword.py --pdf od.pdf 1) == 1 )) "$(python3 -I $LIB/mkpdfword.py --pdf-info od.pdf)"
  for k in fuori web bomba enorme finto molte; do
    w o$k.docx $k; rm -f o$k.pdf
    r=$(python3 -I $LIB/ram.py --timeout 30 -- $M --run PDF o$k.docx 2>&1)
    picco=${r%% *}
    check P "DOCX ostile ($k): non legge fuori, < 500 MB, testo salvo" $(( picco < 500 && $(python3 -I $LIB/mkpdfword.py --testo o$k.pdf) == 1 )) "$picco MB, ${r[1,70]}"
  done
  check P "Nessuna immagine presa da fuori del pacchetto" $(( ! $(python3 -I $LIB/mkpdfword.py --pdf-immagini ofuori.pdf) )) ""

  # The limits still hold, and memory stays bounded at them
  python3 -I $LIB/mkpdftext.py cor.pdf corti 500000
  r=$(python3 -I $LIB/ram.py --timeout 60 -- $M --run DOCX cor.pdf 2>&1); picco=${r%% *}; rm -f cor.docx
  check P "Pagina al tetto (500.000 Tj) → DOCX: < 1,5 GB, < 60 s" $(( picco < 1500 && $(print -r -- $r | cut -d' ' -f4 | grep -c ok) )) "${r[1,40]}"
  python3 -I $LIB/mkpdftext.py num.pdf numeri 50000000
  r=$(python3 -I $LIB/ram.py --timeout 30 -- $M --run DOCX num.pdf 2>&1); picco=${r%% *}
  check P "Numeri compressi → DOCX: rifiuto, < 500 MB" $(( picco < 500 && $(print -r -- $r | grep -c troppo) )) "${r[1,60]}"
  python3 -I $LIB/mkpdftext.py lun.pdf pagine 300 40
  r=$(python3 -I $LIB/ram.py --timeout 60 --  $M --run DOCX lun.pdf 2>&1); s=${${r#* }%% *}; ESITO=$(docx lun.docx 2>&1)
  check P "300 pagine → 300 pagine, < 30 s" $(( $(ha pagine=300 && echo 1 || echo 0) && $(python3 -I -c "print(int(float('$s') < 30))") )) "$s s, ${ESITO[1,50]}"
  python3 -I $LIB/mkpdftext.py cicl.pdf ciclo 1
  r=$(python3 -I $LIB/ram.py --timeout 20 -- $M --run DOCX cicl.pdf 2>&1); picco=${r%% *}
  check P "Forma che disegna se stessa → DOCX: rifiuto" $(( picco < 500 && $(print -r -- $r | grep -c troppo) )) "${r[1,60]}"
fi

# MARK: Q — jobs at the same time

if wants Q; then
  print "\n== Q · Lavori contemporanei"
  mkdir -p $W/insieme && cd $W/insieme
  for i in 1 2 3 4 5 6; do [[ -f d$i.pdf ]] || python3 -I $LIB/mkpdftext.py d$i.pdf pagine 200 100; done
  files=(d1.pdf d2.pdf d3.pdf d4.pdf d5.pdf d6.pdf)
  r=$(perl -e 'alarm shift; exec @ARGV' 120 $M --test-parallel "Con formattazione" 0 $files 2>/dev/null | tail -1)
  n=$(print -l *.docx(N) | grep -c .)
  check Q "6 lavori lanciati insieme: 6 risultati, mai oltre il limite" $(( n == 6 && $(print -r -- $r | grep -cE 'insieme ([2-4]) su \1|insieme [2-4] su [2-4]') )) "$n file, ${r[1,50]}"
  rm -f d?.docx
  r=$(perl -e 'alarm shift; exec @ARGV' 60 $M --test-parallel "Con formattazione" 0.3 $files 2>/dev/null | tail -1)
  n=$(print -l *.docx(N) .rondelle*(N) | grep -c .)
  s=${${r#*, }%% *}
  check Q "Annulla tutti a 0,3 s: fermi in meno di 10 s, nessun file" $(( n == 0 && $(python3 -I -c "print(int(float('${s:-99}') < 10))") )) "$n file, ${r[1,50]}"
  r=$(perl -e 'alarm shift; exec @ARGV' 60 $M --test-parallel --tools Dividi 0 d1.pdf d1.pdf d1.pdf 2>/dev/null | tail -1)
  n=$(print -l "d1 "*(N/) | grep -c .)
  check Q "Stesso file 3 volte insieme: 3 cartelle distinte" $(( n == 3 )) "$n cartelle, ${r[1,50]}"
  mkdir -p grande
  for i in 1 2 3; do [[ -f grande/f$i ]] || dd if=/dev/urandom of=grande/f$i bs=1m count=300 2>/dev/null; done
  r=$(perl -e 'alarm shift; exec @ARGV' 60 $M --test-parallel --tools ZIP 0.3 grande 2>/dev/null | tail -1)
  n=$(print -l *.zip(N) .rondelle*(N) | grep -c .)
  s=${${r#*, }%% *}
  check Q "ZIP di 900 MB, Annulla a 0,3 s: fermo in meno di 5 s, nessun file" $(( n == 0 && $(python3 -I -c "print(int(float('${s:-99}') < 5))") )) "$n file, ${r[1,50]}"
  rm -f grande/f1 grande/f2 grande/f3
  # Names on the wheels
  check Q "Strumenti di un PDF: «Organizza e dividi», «Numera pagine»" $(( $($M --list --tools d1.pdf 2>/dev/null | grep -c 'Organizza e dividi') && $($M --list --tools d1.pdf 2>/dev/null | grep -c 'Numera pagine') )) ""
  check Q "Strumenti di 2 PDF: «Unisci e dividi»" $(( $($M --list --tools d1.pdf d2.pdf 2>/dev/null | grep -c 'Unisci e dividi') )) ""
  check Q "Ruota Condividi: «Copia percorso»" $(( $($M --list --share d1.pdf 2>/dev/null | grep -c 'Copia percorso') )) ""
  print -n x > "nome con 'apice' e spazi.txt"
  r=$($M --test-paths "$PWD/nome con 'apice' e spazi.txt" d1.pdf 2>/dev/null)
  check Q "Copia percorso: percorsi interi, uno per riga, senza virgolette" $(( ${#${(f)r}} == 2 && $([[ ${${(f)r}[1]} == "$PWD/nome con 'apice' e spazi.txt" ]] && echo 1 || echo 0) )) "$r"
  rm -f "nome con 'apice' e spazi.txt"
  # One name for one format
  r=$($M --list /tmp/a.png 2>/dev/null)
  check Q "Ruota foto: «JPG» e «WebP», mai «JPEG»" $(( $(print -r -- $r | grep -cx JPG) && $(print -r -- $r | grep -cx WebP) && ! $(print -r -- $r | grep -cx JPEG) )) ""
  check Q "Ruota PDF: «JPG»" $(( $($M --list /tmp/a.pdf 2>/dev/null | grep -cx JPG) )) ""
  python3 -I $LIB/mkpdftext.py n.pdf caratteri 300
  $M --run JPEG n.pdf >/dev/null 2>&1; rc=$?
  check Q "Il vecchio nome «JPEG» funziona ancora per Comandi rapidi e script" $(( rc == 0 && $(print -l n*.jpg(N) | grep -c .) )) ""
  # Settings: resizable from the edges, between limits, with no full screen
  r=$(perl -e 'alarm shift; exec @ARGV' 25 $M --test-settings-window 2>/dev/null)
  check Q "Impostazioni: ridimensionabile entro i limiti, niente tutto schermo" $(( $(print -r -- $r | grep -c 'ridimensionabile true, a tutto schermo false, verde false') && $(print -r -- $r | grep -c 'finestra 1180×') && $(print -r -- $r | grep -c 'finestra 720×') && $(print -r -- $r | grep -c 'finestra 1050×700') )) "${r[1,60]}"
  # The line under the wheel reads a file nobody has dropped yet
  check Q "Riga sotto la ruota: PDF con nome, peso, pagine" $(( $($M --file-card d1.pdf 2>/dev/null | grep -c '200 pagine') )) ""
  mkfifo tubo.jpg 2>/dev/null
  r=$(perl -e 'alarm shift; exec @ARGV' 5 $M --file-card tubo.jpg 2>/dev/null); rc=$?
  check Q "Riga sotto la ruota: una pipe non la blocca" $(( rc == 0 )) "$r"
  rm -f tubo.jpg
  python3 -I $LIB/mkpdftext.py num.pdf numeri 50000000
  r=$(python3 -I $LIB/ram.py --timeout 20 -- $M --file-card num.pdf 2>&1)
  check Q "Riga sotto la ruota: PDF ostile, < 100 MB, non legge i flussi" $(( ${r%% *} < 100 )) "${r[1,40]}"
fi

# MARK: R — redaction, video to a size, text on the clipboard, subtitles

if wants R; then
  print "\n== R · Oscura, Peso video, Copia testo, Sottotitoli"
  mkdir -p $W/nuove && cd $W/nuove
  python3 -I $LIB/mkpdfword.py seg.pdf segreti
  # The whole of page 1: the words themselves are found by the search below
  LOG=$($M --test-redact seg.pdf 1:0,0,595,120 2>&1); RC=$?
  OUT=$(print -r -- "$LOG" | tail -1)
  check R "Oscura: crea la copia, l'originale resta" $(( RC == 0 && $(python3 -I $LIB/mkpdfword.py --canarino seg.pdf SEGRETOTESTO) )) "${LOG[1,70]}"
  for c in SEGRETOTESTO SEGRETONASCOSTO SEGRETOFORMA SEGRETOIMMAGINE SEGRETONOTA SEGRETOMETADATI SEGRETOTITOLO SEGRETOAUTORE; do
    check R "Oscura: «$c» non c'è più in nessun byte" $(( ! $(python3 -I $LIB/mkpdfword.py --canarino "$OUT" $c) )) ""
  done
  check R "Oscura: la pagina non oscurata resta testo" $(( $(python3 -I $LIB/mkpdfword.py --canarino "$OUT" PAROLA) )) ""
  check R "Oscura: l'area è nera nei pixel, non un rettangolo" $(( $($M --test-pixel "$OUT" 1 300 780) == 0.00 || $($M --test-pixel "$OUT" 1 300 780) == 0.01 )) "$($M --test-pixel "$OUT" 1 300 780)"
  rm -f "$OUT"
  # By word: the page with it is rebuilt and only that one
  LOG=$($M --test-redact seg.pdf SEGRETOTESTO 2>&1); RC=$?; OUT=$(print -r -- "$LOG" | tail -1)
  check R "Oscura per parola: la parola non c'è più" $(( RC == 0 && ! $(python3 -I $LIB/mkpdfword.py --canarino "$OUT" SEGRETOTESTO) )) "${LOG[1,70]}"
  rm -f "$OUT"
  LOG=$($M --test-redact seg.pdf NONCE 2>&1); RC=$?
  check R "Oscura per parola assente: errore, nessun file" $(( RC != 0 && ! $(print -l *oscurato*(N) | grep -c .) )) "${LOG[1,60]}"
  python3 -I $LIB/mkpdfword.py ruo.pdf ruotata2
  LOG=$($M --test-redact ruo.pdf "1:0,0,595,842" 2>&1); OUT=$(print -r -- "$LOG" | tail -1)
  check R "Oscura su pagina ruotata: pagina orizzontale, area nera" $(( $($M --test-pixel "$OUT" 1 400 300) == 0.00 )) "$($M --test-pixel "$OUT" 1 400 300) ${LOG[1,50]}"
  rm -f "$OUT"
  python3 -I $LIB/mkpdftext.py gr.pdf righe 15000000
  r=$(python3 -I $LIB/ram.py --timeout 30 -- $M --test-redact gr.pdf 1:0,0,100,100 2>&1)
  check R "Oscura su PDF ostile: rifiuto, < 500 MB, < 5 s" $(( ${r%% *} < 500 && $(print -r -- $r | grep -c troppo) )) "${r[1,60]}"
  rm -f gr.pdf

  # Video to a size
  cp $W/src/big.mov clip.mov 2>/dev/null || $B/genvid clip.mov >/dev/null
  for mb in 1 8; do
    rm -f clip\ \(*.mp4(N)
    LOG=$(RONDELLE_VALUE=$mb perl -e 'alarm shift; exec @ARGV' 150 $M --run --tools "Peso…" clip.mov 2>&1); RC=$?
    f=$(print -r -- "$LOG" | tail -1); size=$(stat -f %z "$f" 2>/dev/null || print 0)
    check R "Video sotto $mb MB: file valido entro il peso" $(( RC == 0 && size > 0 && size <= mb * 1000000 )) "$size byte"
  done
  check R "Video: nessun metadato con la posizione" $(( ! $(grep -ac 'com.apple.quicktime.location' "$f") )) ""
  LOG=$(RONDELLE_VALUE=1000 $M --run --tools "Peso…" clip.mov 2>&1); RC=$?
  check R "Video già sotto il peso: lo dice, nessun file" $(( RC != 0 )) "${LOG[1,70]}"
  LOG=$(RONDELLE_VALUE=0,001 $M --run --tools "Peso…" clip.mov 2>&1); RC=$?
  check R "Video, peso impossibile: lo dice, nessun file in più" $(( RC != 0 )) "${LOG[1,70]}"
  rm -f clip.mov clip\ \(*.mp4(N)

  # Text on the clipboard: the test build prints it instead of relying on the clipboard's contents
  python3 -I $LIB/mkpdftext.py img.pdf caratteri 300
  $M --run PNG img.pdf >/dev/null 2>&1
  r=$(RONDELLE_PRINT_TEXT=1 $M --run --tools "Copia testo" img.png 2>/dev/null)
  check R "Copia testo: riconosce il testo e non crea file" $(( $(print -r -- $r | grep -c gatto) && ! $(print -l img*.txt(N) | grep -c .) )) "${r[1,50]}"

  # Subtitles: needs macOS 26 and the Italian model, present or downloaded by macOS
  if $M --list --tools img.mov 2>/dev/null | grep -q 'Sottotitoli'; then
    say -v Alice -o voce.aiff "Buongiorno a tutti. Oggi parliamo del gatto che dorme sul tavolo, mentre fuori piove. Il fiume sta salendo piano verso la piazza del paese." 2>/dev/null
    LOG=$(perl -e 'alarm shift; exec @ARGV' 200 $M --run --tools "SRT italiano" voce.aiff 2>&1); RC=$?
    check R "Sottotitoli: SRT con tempi e testo" $(( RC == 0 && $(grep -c -- '-->' voce.srt 2>/dev/null || print 0) >= 1 && $(grep -ci gatto voce.srt 2>/dev/null || print 0) >= 1 )) "${LOG[1,70]}"
    afconvert -f AIFF -d BEI16 -c 1 /dev/null silenzio.aiff 2>/dev/null
    python3 -I -c "import wave; w=wave.open('sil.wav','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(16000*4)); w.close()"
    LOG=$(perl -e 'alarm shift; exec @ARGV' 120 $M --run --tools "SRT italiano" sil.wav 2>&1); RC=$?
    check R "Sottotitoli su silenzio: lo dice, nessun file" $(( RC != 0 && ! $(print -l sil.srt(N) | grep -c .) )) "${LOG[1,70]}"
    print -n "non e audio" > finto.mp3
    LOG=$(perl -e 'alarm shift; exec @ARGV' 60 $M --run --tools "SRT italiano" finto.mp3 2>&1); RC=$?
    check R "Sottotitoli su file finto: errore, nessun file" $(( RC != 0 && ! $(print -l finto.srt(N) | grep -c .) )) "${LOG[1,70]}"
  fi
fi

# MARK: S — rotation, icons, SHA-256

if wants S; then
  print "\n== S · Ruota PDF, icone, SHA-256"
  mkdir -p $W/piccole && cd $W/piccole
  python3 -I $LIB/mkpdfword.py nat.pdf segreti   # A4, 2 pages, with information and metadata
  for t in "Ruota a destra:90" "Ruota a sinistra:270" "Capovolgi:180"; do
    a=${t%:*} g=${t#*:}
    LOG=$($M --run --tools "$a" nat.pdf 2>&1); RC=$?; f=$(print -r -- "$LOG" | tail -1)
    r=$(python3 -I $LIB/mkpdfword.py --pdf-info "$f" 2>&1)
    check S "$a: 2 pagine, /Rotate $g, originale intatto" $(( RC == 0 && $(grep -ac "/Rotate $g" "$f") >= 1 && $(print -r -- $r | grep -c '^(2,') && ! $(grep -ac '/Rotate' nat.pdf) )) "$r"
    check S "$a: niente titolo né autore del documento" $(( ! $(python3 -I $LIB/mkpdfword.py --canarino "$f" SEGRETOTITOLO) && ! $(python3 -I $LIB/mkpdfword.py --canarino "$f" SEGRETOAUTORE) )) ""
    rm -f "$f"
  done
  python3 -I $LIB/mkpdftext.py gr.pdf righe 15000000
  r=$(python3 -I $LIB/ram.py --timeout 30 -- $M --run --tools "Ruota a destra" gr.pdf 2>&1)
  check S "Ruota su PDF ostile: rifiuto, < 500 MB" $(( ${r%% *} < 500 && $(print -r -- $r | grep -c troppo) )) "${r[1,60]}"
  rm -f gr.pdf

  # Icons, from a wide picture with a position in it
  cp $W/can/can.jpg foto.jpg 2>/dev/null || sips -s format jpeg -z 800 1600 "/Library/User Pictures/Animals/Parrot.heic" --out foto.jpg >/dev/null 2>&1
  $M --run ICNS foto.jpg >/dev/null 2>&1; RC=$?
  mkdir -p ic; r=$(iconutil -c iconset -o ic/x.iconset foto.icns 2>&1; ls ic/x.iconset 2>/dev/null | wc -l | tr -d ' ')
  check S "ICNS: letto da iconutil, più misure" $(( RC == 0 && ${r##*[^0-9]} >= 5 )) "$r"
  check S "ICNS: senza GPS né EXIF" $(( ! $(grep -ac 'GPS\|Exif' foto.icns) )) ""
  $M --run ICO foto.jpg >/dev/null 2>&1; RC=$?
  r=$(python3 -I -c "
import struct
d=open('foto.ico','rb').read(); a,t,n=struct.unpack('<HHH',d[:6]); ok=(a,t)==(0,1)
for i in range(n):
    w,h,_,_,p,b,s,o=struct.unpack('<BBBBHHII',d[6+16*i:22+16*i]); ok=ok and w==h and d[o:o+8]==b'\\x89PNG\\r\\n\\x1a\\n' and o+s<=len(d)
print(int(ok), n)")
  check S "ICO: struttura valida, 7 misure in PNG" $(( RC == 0 && $([[ $r == "1 7" ]] && echo 1 || echo 0) )) "$r"
  check S "ICO: letto da macOS" $(( $(sips -g pixelWidth foto.ico 2>/dev/null | grep -c pixelWidth) )) ""
  check S "ICO: senza GPS né EXIF" $(( ! $(grep -ac 'GPS\|Exif' foto.ico) )) ""
  sips -s format png -z 10 10 foto.jpg --out mini.png >/dev/null 2>&1
  LOG=$($M --run ICNS mini.png 2>&1); RC=$?
  check S "Immagine di 10 px: lo dice, nessun file" $(( RC != 0 && ! $(print -l mini.icns(N) | grep -c .) )) "${LOG[1,70]}"
  sips -s format png -z 20 20 foto.jpg --out pic.png >/dev/null 2>&1
  $M --run ICO pic.png >/dev/null 2>&1; RC=$?
  check S "Immagine di 20 px: solo le misure che può fare" $(( RC == 0 && $(python3 -I -c "import struct; print(struct.unpack('<H',open('pic.ico','rb').read()[4:6])[0])") == 1 )) ""

  # SHA-256, against the system's own
  print -n "contenuto di prova" > "file con spazi.txt"
  : > vuoto.bin
  dd if=/dev/zero of=grande.bin bs=1m count=300 2>/dev/null
  for f in "file con spazi.txt" vuoto.bin grande.bin; do
    check S "SHA-256 di «$f» uguale a shasum" $(( $([[ $($M --test-sha256 "$f" 2>/dev/null) == ${$(shasum -a 256 "$f")[1]} ]] && echo 1 || echo 0) )) ""
  done
  r=$($M --test-sha256 vuoto.bin "file con spazi.txt" 2>/dev/null); s=$(shasum -a 256 "file con spazi.txt" vuoto.bin)
  check S "SHA-256 di più file: righe come shasum" $(( $([[ $r == $s ]] && echo 1 || echo 0) )) "${r[1,40]}"
  r=$(python3 -I $LIB/ram.py --timeout 20 -- $M --test-sha256 grande.bin 2>&1)
  check S "SHA-256 di 300 MB: < 100 MB di RAM" $(( ${r%% *} < 100 )) "${r[1,20]}"
  mkfifo tubo; r=$(perl -e 'alarm shift; exec @ARGV' 5 $M --test-sha256 tubo 2>&1); rc=$?
  check S "SHA-256 di una pipe: rifiuto, non si blocca" $(( rc == 1 )) "${r[1,60]}"
  rm -f tubo grande.bin
  mkdir -p cart; r=$($M --test-sha256 cart 2>&1); rc=$?
  check S "SHA-256 di una cartella: rifiuto" $(( rc == 1 )) "${r[1,60]}"
fi

# MARK: T — after the audit of 0.9.7.5

if wants T; then
  print "\n== T · Audit 0.9.7.5: aggiornamenti, modulo, PDF cifrati"
  mkdir -p $W/t && cd $W/t
  # U1: tags from GitHub and the comparison of versions
  ver() { check T "versione «$1» > «$2»: $3" $(( $([[ $($M --test-version "$1" "$2" 2>&1) == $3 ]] && echo 1 || echo 0) )) "" }
  ver v0.9.7.6 0.9.7.5 si; ver v0.9.7.10 0.9.7.9 si; ver v99999999999999999999.0 0.9.7.5 si
  ver v0.9.7.5 99999999999999999999.0 no; ver v1.2.3.4.5 0.1 no; ver v1.0-beta 0.1 no; ver "" 0.1 no
  ver 1.0 0.1 no; ver $'v1.0\n' 0.1 no; ver "$(python3 -I -c "print('v\u0661.\u0662', end='')")" 0.1 no; ver v1 0.1 no; ver v00001.0 0.9 si
  # T3: the form's window, in characters and in bytes
  fb() { check T "modulo: $1" $(( $([[ $($M --test-feedback "$2" "$3" 2>&1) == "$4" ]] && echo 1 || echo 0) )) "" }
  acc() { python3 -I -c "print('e' + '\u0301'*$1, end='')" }
  fb "19.999 byte" "$(acc 9999)" "" "messaggio si email si"
  fb "20.001 byte in un carattere" "$(acc 10000)" "" "messaggio no email si"
  fb "email con a capo" x $'a@b.it\n' "messaggio si email no"
  fb "email di 255 byte" x "$(python3 -I -c "print('a'*64 + '@' + 'b'*185 + '.cccc', end='')")" "messaggio si email no"

  # T1: the /ID of an encrypted PDF (R2–R4) is read from a few candidates, not at every «/ID[»
  python3 -I $LIB/mkpdfenc.py base.pdf rc4-128 righe 10
  for mb in 0.5 2 20; do
    python3 -I $LIB/mkpdfid.py idpad base.pdf id$mb.pdf $mb
    t0=$EPOCHREALTIME; LOG=$(perl -e 'alarm shift; exec @ARGV' 120 $M --run TXT id$mb.pdf 2>&1); RC=$?; t=$(( EPOCHREALTIME - t0 ))
    check T "/ID ripetuto, $mb MB: testo estratto in < 1 s" $(( RC == 0 && t < 1 )) "$(printf %.2f $t) s"
  done
  t0=$EPOCHREALTIME; LOG=$(perl -e 'alarm shift; exec @ARGV' 120 $M --test-cancel 0.3 TXT id20.pdf 2>&1); t=$(( EPOCHREALTIME - t0 ))
  check T "/ID ripetuto, 20 MB: «Annulla» < 1 s" $(( t < 1.3 )) "$(printf %.2f $t) s: ${LOG[1,40]}"
  rm -f id*.pdf id*.txt
  # The right key stays the right one: normal trailer, incremental update, a false /ID after %%EOF
  for k in rc4-40 rc4-128 aes-128 aes-256; do
    python3 -I $LIB/mkpdfenc.py $k.pdf $k righe 30
    $M --run TXT $k.pdf >/dev/null 2>&1
    check T "$k: testo estratto" $(( $(grep -ao 'il gatto dorme sul tavolo' $k.txt 2>/dev/null | wc -l) == 30 )) ""
    for v in incr fakeid; do
      python3 -I $LIB/mkpdfid.py $v $k.pdf $k-$v.pdf
      LOG=$($M --run TXT $k-$v.pdf 2>&1)
      check T "$k $v: stesso testo, byte per byte" $(( $(cmp -s $k.txt $k-$v.txt && echo 1 || echo 0) )) "${LOG[1,60]}"
    done
  done

  # P1: ciphers a reader may know or not, each with a bomb of ≈ 100 KB (50 million numbers, no operator) inside
  for v in v4-none v4-v2 v4-aesv2 identity nometa cryptname objstm xrefstm nocfm cryptother cryptelse; do
    python3 -I $LIB/mkpdfvar.py b-$v.pdf $v numeri 50000000
    r=$(python3 -I $LIB/ram.py --timeout 60 -- $M --run TXT b-$v.pdf 2>&1)
    check T "cifratura $v, bomba: TXT rifiuta, < 300 MB" $(( ${r%% *} < 300 && $(print -r -- $r | grep -c 'troppo\|cifratura') )) "${r[1,60]}"
    r=$(RONDELLE_VALUE=proprietario python3 -I $LIB/ram.py --timeout 60 -- $M --run --tools Sblocca b-$v.pdf 2>&1)
    check T "cifratura $v, bomba, password del proprietario: rifiuta, < 300 MB" $(( ${r%% *} < 300 && $(print -r -- $r | grep -c 'troppo\|cifratura\|non ha una password') )) "${r[1,60]}"
    rm -f b-$v.pdf
  done
  # P1: a /Crypt filter of its own for one stream, with another cipher: refused with a message
  python3 -I $LIB/mkpdfvar.py b-else.pdf cryptelse numeri 50000000
  r=$(python3 -I $LIB/ram.py --timeout 60 -- $M --run TXT b-else.pdf 2>&1)
  check T "cifratura per un solo flusso, bomba: rifiuto con messaggio, < 300 MB" $(( ${r%% *} < 300 && $(print -r -- $r | grep -c 'cifratura') )) "${r[1,60]}"
  for v in v4-none v4-v2 v4-aesv2 identity nometa cryptname objstm xrefstm nocfm cryptother; do
    python3 -I $LIB/mkpdfvar.py t-$v.pdf $v righe 30; $M --run TXT t-$v.pdf >/dev/null 2>&1
    check T "cifratura $v: il testo vero si legge" $(( $(grep -ao 'il gatto dorme sul tavolo' t-$v.txt 2>/dev/null | wc -l) == 30 )) ""
  done
  rm -f t-*.pdf t-*.txt

  # T2: big encrypted streams. Without a filter or as an image they aren't decrypted (before: 563 MB at 256 MB,
  # 2.2 GB at 1 GB); the rest of the peak, ≈ 1.1 times the file, comes with any PDF of that size, encrypted or not.
  big() { python3 -I $LIB/mkpdfbig.py g.pdf $1 $2; r=$(python3 -I $LIB/ram.py --timeout 120 -- $M --run TXT g.pdf 2>&1); rm -f g.pdf g.txt }
  big raw 268435456;  check T "flusso cifrato senza filtro, 256 MB: non decifrato, < 400 MB" $(( ${r%% *} < 400 && $(print -r -- $r | grep -c ' ok ') )) "${r[1,40]}"
  big raw 1073741824; check T "flusso cifrato senza filtro, 1 GB: non decifrato, < 1300 MB" $(( ${r%% *} < 1300 )) "${r[1,40]}"
  big dct 1073741824; check T "immagine cifrata, 1 GB: non decifrata, < 1300 MB" $(( ${r%% *} < 1300 )) "${r[1,40]}"
  big flate 268435456; check T "flusso cifrato compresso, esattamente 256 MB: passa" $(( $(print -r -- $r | grep -c ' 0 ok ') && ! $(print -r -- $r | grep -c 'troppo grande') )) "${r[1,60]}"
  big flate 268435472; check T "flusso cifrato compresso, 256 MB + 16 byte: rifiuto con messaggio" $(( $(print -r -- $r | grep -c 'flusso cifrato troppo grande') && ${r%% *} < 400 )) "${r[1,60]}"
fi

# MARK: summary

print "\n== Riepilogo"
for s in A B C D E F G H I J K L M N O P Q R S T; do
  local p=$(awk -F'\t' -v s=$s '$1==s && $2=="PASS"' $RES | wc -l | tr -d ' ') f=$(awk -F'\t' -v s=$s '$1==s && $2=="FAIL"' $RES | wc -l | tr -d ' ')
  (( p + f )) && printf "%s  %4d PASS  %3d FAIL\n" $s $p $f
done
fails=$(grep -c '	FAIL	' $RES)
print "Risultati: $RES"
(( fails == 0 )) && { print "TUTTO PASS"; exit 0 } || { print "$fails FAIL:"; grep '	FAIL	' $RES | cut -f1,3,4; exit 1 }
