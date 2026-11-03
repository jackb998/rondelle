#!/bin/zsh
# Tests of the contact form's service: what it agrees to send and how it reads an answer. Sends nothing.
#
#   Tests/feedback/run.sh
#
# One real message through the sandbox is a separate step, by hand, and counts on the form's quota:
# build the test app of Tests/updates/run.sh and run it with --feedback-test.
ROOT=${0:A:h:h:h}
W=$(mktemp -d "${TMPDIR%/}/rondelle-feedback.XXXXXX")
fails=0
check() { if [[ $2 == $3 ]]; then print "PASS $1"; else print "FAIL $1: atteso «$3», ottenuto «$2»"; fails=$((fails + 1)); fi }
cd $ROOT || exit 2
swift build -c debug --product FeedbackSend --scratch-path $W/debug -q || exit 2
F=$W/debug/debug/FeedbackSend
body() { $F --body "$@" }

# MARK: what it sends
check "messaggio minimo" "$(body problema 'ciao' '' '' '')" '{"messaggio":"ciao","tipo":"problema"}'
check "tutti i campi" "$(body idea 'ciao' 'a@b.it' '0.9.7 (36)' '27.2.0')" '{"email":"a@b.it","messaggio":"ciao","tipo":"idea","versione_app":"0.9.7 (36)","versione_macos":"27.2.0"}'
check "virgolette nel testo restano testo" "$(body altro 'a"b' '' '' '')" '{"messaggio":"a\"b","tipo":"altro"}'
check "spazi intorno tolti" "$(body altro '  ciao  ' '' '' '')" '{"messaggio":"ciao","tipo":"altro"}'
check "messaggio vuoto" "$(body altro '   ' '' '' '')" rifiutato
check "tipo sconosciuto" "$(body spia 'x' '' '' '')" rifiutato
check "email senza chiocciola" "$(body altro 'x' 'nonemail' '' '')" rifiutato
check "email con a capo" "$(body altro 'x' $'a@b.it\nBcc: c@d.it' '' '')" rifiutato
check "versione che porta testo" "$(body altro 'x' '' '/Users/io/segreto.pdf' '')" rifiutato
check "macOS che porta testo" "$(body altro 'x' '' '' 'abc')" rifiutato
long=$(python3 -I -c "print('a'*5000)")
check "5000 caratteri passano" "$(body altro $long '' '' '' | cut -c1-16)" '{"messaggio":"aa'
check "5001 caratteri no" "$(body altro ${long}a '' '' '')" rifiutato
# T3: the limit is also in bytes; one letter with many accents is one character
acc() { python3 -I -c "print('e' + '\u0301'*$1, end='')" }
check "19.999 byte in un carattere passano" "$(body altro "$(acc 9999)" '' '' '' | wc -c | tr -d ' ')" 20031
check "20.001 byte in un carattere no" "$(body altro "$(acc 10000)" '' '' '' | cut -c1-20)" rifiutato
check "200.000 accenti no" "$(body altro "$(acc 200000)" '' '' '' | cut -c1-20)" rifiutato
check "email con a capo in fondo" "$(body altro 'x' $'a@b.it\n' '' '')" rifiutato
check "email con ritorno a capo" "$(body altro 'x' $'a@b.it\r' '' '')" rifiutato
local64=$(python3 -I -c "print('a'*64, end='')"); dom=$(python3 -I -c "print('b'*185, end='')")
check "email di 254 byte" "$(body altro 'x' "$local64@$dom.ccc" '' '' | grep -c email)" 1
check "email di 255 byte no" "$(body altro 'x' "$local64@$dom.cccc" '' '' | cut -c1-20)" rifiutato
check "tipo con maiuscola no" "$(body Problema 'x' '' '' '')" rifiutato

# MARK: how it reads an answer
out() { $F --outcome "$@" }
check "200 riuscito" "$(out 200 '{"success":true,"message":"Submission received."}')" ok
check "200 senza success" "$(out 200 '{}')" failed
check "200 non JSON" "$(out 200 '<html>')" failed
check "quota" "$(out 429 '{"success":false,"error":"quota_exceeded"}')" quota
check "troppi invii" "$(out 429 '{"message":"Too Many Attempts."}')" busy
check "captcha o provenienza" "$(out 403 '{"success":false,"error":"origin_missing"}')" refused
check "campi non validi" "$(out 422 '{}')" refused
check "errore del server" "$(out 500 '')" failed

# MARK: the address is fixed
S=$ROOT/Sources/FeedbackSend/main.swift
check "un solo indirizzo nel codice" "$(grep -c 'https://' $S)" 1
check "reindirizzamenti rifiutati" "$(grep -c 'completionHandler(nil)' $S)" 1
check "nessun accesso a file" "$(grep -c -E 'FileManager|contentsOf|FileHandle' $S)" 0
check "permessi: rete e sandbox soltanto" "$(grep -c '<key>' $ROOT/Resources/FeedbackSend.entitlements)" 2
rm -rf $W
print "Falliti: $fails"
exit $(( fails > 0 ))
