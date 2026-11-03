#!/bin/zsh
# Tests of the update check. Prints one PASS/FAIL line per check; exit status 1 if any fails.
#
#   Tests/updates/run.sh
#
# Builds a test app (UPDATE_TEST: asks a public repository with releases, runs one check and exits, without
# the wheel) in a temporary folder and runs it in its real sandbox. Needs the network. Nothing is installed.
# Then builds the release app with build.sh and checks what it contains.
setopt extendedglob
ROOT=${0:A:h:h:h}
W=$(mktemp -d "${TMPDIR%/}/rondelle-updates.XXXXXX")
fails=0
check() { if [[ $2 == $3 ]]; then print "PASS $1"; else print "FAIL $1: atteso «$3», ottenuto «$2»"; fails=$((fails + 1)); fi }
cd $ROOT || exit 2

# MARK: what the service accepts from GitHub
swift build -c debug --product UpdateCheck --scratch-path $W/debug -q || exit 2
UC=$W/debug/debug/UpdateCheck
parse() { print -rn -- $2 > $W/a.json; check "risposta: $1" "$($UC --parse $W/a.json)" $3 }
parse "versione" '{"tag_name":"v1.2.3"}' v1.2.3
parse "senza v" '{"tag_name":"0.9.1"}' rifiutato
parse "un solo numero" '{"tag_name":"v1"}' rifiutato
parse "cinque numeri" '{"tag_name":"v1.2.3.4.5"}' rifiutato
parse "a capo in fondo" '{"tag_name":"v1.2.3\n"}' rifiutato
parse "cifre arabe" '{"tag_name":"v\u0661.\u0662"}' rifiutato
parse "cifre larghe" '{"tag_name":"v\uff11.\uff12"}' rifiutato
parse "vuoto" '{"tag_name":""}' rifiutato
parse "numero enorme" '{"tag_name":"v99999999999999999999.0"}' v99999999999999999999.0
parse "punto in fondo" '{"tag_name":"v1.2."}' rifiutato
parse "beta" '{"tag_name":"v1.0-beta"}' rifiutato
parse "percorso" '{"tag_name":"../../evil"}' rifiutato
parse "indirizzo" '{"tag_name":"v1.0/../../x"}' rifiutato
parse "a capo" '{"tag_name":"v1.0\nx"}' rifiutato
parse "non testo" '{"tag_name":12}' rifiutato
parse "manca" '{"name":"v1.0"}' rifiutato
parse "non JSON" 'html' rifiutato
python3 -I -c 'print("{\"tag_name\":\"v1.0\",\"x\":\"" + "a"*1000001 + "\"}")' > $W/big.json
st() { check "stato $1" "$($UC --status $1 '{"tag_name":"v1.2.3"}')" $2 }
st 200 v1.2.3; st 404 none; st 403 busy; st 429 busy; st 500 failed; st 502 failed; st 301 failed
check "stato 200 senza JSON" "$($UC --status 200 'html')" failed
check "risposta: oltre 1 MB" "$($UC --parse $W/big.json)" rifiutato

# MARK: test app in the sandbox
swift build -c release --arch arm64 -Xswiftc -DUPDATE_TEST --scratch-path $W/rel -q || exit 2
BIN=$W/rel/release
[[ -x $BIN/Rondelle ]] || BIN=$(swift build -c release --arch arm64 -Xswiftc -DUPDATE_TEST --scratch-path $W/rel --show-bin-path)
bundle() {   # bundle VERSION → $APP
  APP=$W/v$1/Rondelle.app
  mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
  cp $BIN/Rondelle $APP/Contents/MacOS/
  cp Resources/Info.plist $APP/Contents/
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" $APP/Contents/Info.plist
  tools/add_update_check.sh $APP $BIN/UpdateCheck
  tools/add_feedback_send.sh $APP $BIN/FeedbackSend
  xattr -cr $APP
  codesign --force --options runtime --entitlements Resources/Rondelle.entitlements --sign - $APP
}
run() { perl -e 'alarm shift; exec @ARGV' 60 $APP/Contents/MacOS/Rondelle --update-test 2>/dev/null }

bundle 0.1.0; OUT=$(run)
check "versione vecchia: l'app da sola non raggiunge la rete" "$(print -r -- $OUT | grep RETE-APP)" "RETE-APP bloccata"
SVC=$(print -r -- $OUT | grep SERVIZIO)
[[ $SVC == "SERVIZIO "v[0-9]*" -" ]] && SVC=ok
check "versione vecchia: il servizio risponde" "$SVC" ok
check "versione vecchia: aggiornamento trovato" "$(print -r -- $OUT | grep DISPONIBILE | grep -c v)" 1

bundle 99.0.0; OUT=$(run)
check "versione nuova: nessun aggiornamento" "$(print -r -- $OUT | grep DISPONIBILE)" "DISPONIBILE nessuno"

# The release published on GitHub: what an older app finds, and the page it would open.
TAG=$(curl -s https://api.github.com/repos/jackb998/rondelle/releases/latest | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)
bundle 0.1.0; OUT=$(run)
check "pubblicata: l'app vecchia trova $TAG" "$(print -r -- $OUT | grep DISPONIBILE)" "DISPONIBILE $TAG"
bundle ${TAG#v}; OUT=$(run)
check "pubblicata: la stessa versione non si annuncia" "$(print -r -- $OUT | grep DISPONIBILE)" "DISPONIBILE nessuno"
check "pubblicata: la pagina di download esiste" "$(curl -s -o /dev/null -w '%{http_code}' -L https://github.com/jackb998/rondelle/releases/tag/$TAG)" 200

# The contact form's service, reached from the sandbox: with a field it refuses, so nothing is sent.
check "invio: il servizio risponde, senza spedire" "$(perl -e 'alarm shift; exec @ARGV' 60 $APP/Contents/MacOS/Rondelle --feedback-reach 2>/dev/null)" "INVIO invalid"

# Without the service the app must carry on.
bundle 0.2.0; rm -rf $APP/Contents/XPCServices
codesign --force --options runtime --entitlements Resources/Rondelle.entitlements --sign - $APP; OUT=$(run)
check "senza servizio: errore gestito" "$(print -r -- $OUT | grep SERVIZIO)" "SERVIZIO nessuno failed"

# MARK: version comparison
cmp() { check "confronto $1 > $2" "$($APP/Contents/MacOS/Rondelle --update-test-compare "$1" "$2")" $3 }
cmp v0.9.3 0.9.2 si; cmp v0.9.2 0.9.2 no; cmp v0.9.10 0.9.9 si; cmp v1.0 0.9.99 si; cmp v0.9 0.9.0 no
cmp 0.9.2 0.10.0 no; cmp beta 0.1 no
cmp v0.9.7.10 0.9.7.9 si; cmp v99999999999999999999.0 0.9.7.5 si; cmp v1.2.3.4.5 0.1 no; cmp v1.0-beta 0.1 no
cmp v0.9.7.5 99999999999999999999.0 no; cmp v00001.0 0.9 si; cmp v1.0 1.0.0.0 no; cmp "" 0.1 no

# MARK: release app
./build.sh >/dev/null 2>&1 || { print "FAIL build.sh"; exit 1 }
A=build/Rondelle.app
codesign --verify --strict --deep $A && check "firma dell'app e del servizio" ok ok || check "firma" no ok
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert json -o - - 2>/dev/null }
check "app: nessun permesso di rete" "$(ents $A | grep -c network)" 0
check "servizio: permesso di rete" "$(ents $A/Contents/XPCServices/UpdateCheck.xpc | grep -c 'network.client')" 1
check "servizio: nessun permesso sui file" "$(ents $A/Contents/XPCServices/UpdateCheck.xpc | grep -c 'files\.')" 0
check "invio: permesso di rete" "$(ents $A/Contents/XPCServices/FeedbackSend.xpc | grep -c 'network.client')" 1
check "invio: nessun permesso sui file" "$(ents $A/Contents/XPCServices/FeedbackSend.xpc | grep -c 'files\.')" 0
check "invio: nessuna stringa di prova" "$(strings $A/Contents/XPCServices/FeedbackSend.xpc/Contents/MacOS/FeedbackSend | grep -c -E -e '--body|--outcome')" 0
check "app: nessuna stringa della prova d'invio" "$(strings $A/Contents/MacOS/Rondelle | grep -c -e '--feedback-test')" 0
check "app: nessun URLSession nel codice di rilascio" "$(nm -u $A/Contents/MacOS/Rondelle | grep -c -E 'URLSession')" 0
check "nessuna stringa di prova" "$(strings $A/Contents/MacOS/Rondelle $A/Contents/XPCServices/UpdateCheck.xpc/Contents/MacOS/UpdateCheck | grep -c -E 'kstepanchuk|update-test')" 0
rm -rf build $W
print "Falliti: $fails"
exit $(( fails > 0 ))
