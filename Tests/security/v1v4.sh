#!/bin/zsh
# Regression attacks V1-V4 from the second audit, on crafted files only (DEBUG test build).
#   Tests/security/v1v4.sh [WORKDIR]      RONDELLE_BIN: another DEBUG binary
ROOT=${0:A:h:h:h}
A=${1:-$(mktemp -d "${TMPDIR%/}/rondelle-v1v4.XXXXXX")}
rm -rf -- "${A:?}" && mkdir -p $A && A=${A:A} && cd $A
B=${RONDELLE_BIN:-$ROOT/.build-test/out/Products/Release/Rondelle}
ok=0; ko=0
pass() { echo "PASS $1"; ok=$((ok+1)); }
fail() { echo "FAIL $1"; ko=$((ko+1)); }

# V1: a dangling symlink with the output's name must not be written through.
mkdir -p v1/c v1/fuori && sips -s format png -Z 64 "/System/Library/Desktop Pictures/Sonoma.heic" --out v1/c/foto.png >/dev/null
ln -s $A/v1/fuori/X.zip v1/c/foto.zip; ln -s $A/v1/fuori/X.jpg v1/c/foto.jpg
"$B" --run --tools ZIP $A/v1/c/foto.png >/dev/null 2>&1; "$B" --run JPEG $A/v1/c/foto.png >/dev/null 2>&1
[[ $(ls v1/fuori | wc -l) -eq 0 ]] && pass "V1 nessun file scritto attraverso il link" || fail "V1 file scritti fuori: $(ls v1/fuori)"

# V2: zip must store links as links, not copy what they point to.
mkdir -p v2/estratto && echo SEGRETO-V2 > v2/segreto.txt && ln -s $A/v2/segreto.txt v2/estratto/innocuo.txt && echo ciao > v2/altro.txt
"$B" --run --tools ZIP $A/v2/estratto $A/v2/altro.txt >/dev/null 2>&1
unzip -p v2/Archivio.zip estratto/innocuo.txt 2>/dev/null | grep -q SEGRETO-V2 && fail "V2 segreto copiato nello ZIP" || pass "V2 link salvato come link"

# V3: decompression-bomb image (60000x60000 PNG, ~10 MB) refused everywhere.
python3 -I - <<'EOF'
import struct, zlib
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
w = h = 60000; c = zlib.compressobj(9); row = b"\0" * (w * 3 + 1)
data = b"".join(c.compress(row) for _ in range(h)) + c.flush()
open("bomba.png", "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", data) + chunk(b"IEND", b""))
EOF
cp v1/c/foto.png ok.png
for cmd in "--run JPEG $A/bomba.png" "--run PDF $A/bomba.png $A/ok.png" "--assemble $A/u.pdf $A/ok.png $A/bomba.png" "--run --tools Testo $A/bomba.png"; do
  out=$(perl -e 'alarm 40; exec @ARGV' "$B" ${=cmd} 2>&1); [[ $out == *"troppo grande"* ]] && pass "V3 rifiutata: ${cmd%% $A*}" || fail "V3 non rifiutata: ${cmd%% $A*} :: $out"
done

# V4: links in an archive that lead outside are removed; internal ones stay; nothing escapes.
mkdir -p v4/fuori && python3 -I - "$A/v4/fuori" <<'EOF'
import sys, zipfile, stat
out = sys.argv[1]
def link(z, name, target):
    i = zipfile.ZipInfo(name); i.create_system = 3; i.external_attr = (stat.S_IFLNK | 0o777) << 16; z.writestr(i, target)
with zipfile.ZipFile("v4/link-poi-file.zip", "w") as z: link(z, "fuga", out); z.writestr("fuga/PWN.txt", "pwned")
with zipfile.ZipFile("v4/assoluto.zip", "w") as z: z.writestr(out + "/PWN2.txt", "pwned"); z.writestr("ok.txt", "ok")
with zipfile.ZipFile("v4/link.zip", "w") as z:
    link(z, "hosts", "/etc/hosts"); link(z, "su", "../../segreto.txt"); link(z, "interno", "ok.txt"); z.writestr("ok.txt", "ok")
EOF
for f in link-poi-file assoluto link; do "$B" --run Estrai $A/v4/$f.zip >/dev/null 2>&1; done
[[ $(ls v4/fuori | wc -l) -eq 0 ]] && pass "V4 nessun file scritto fuori" || fail "V4 file fuori: $(ls v4/fuori)"
links=$(find v4/link -type l 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
[[ $links == "interno " ]] && pass "V4 restano solo i link interni ($links)" || fail "V4 link rimasti: $links"

echo "V1-V4: $ok PASS, $ko FAIL"
(( ko == 0 ))
