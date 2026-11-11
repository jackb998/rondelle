#!/bin/bash
# Static checks for the public site (site/). No dependencies besides bash, grep and python3.
# Run from the repository root:  bash Tests/site/check.sh
cd "$(dirname "$0")/../.." || exit 2
fail=0
bad() { echo "FAIL  $1"; fail=$((fail+1)); }
ok()  { echo "ok    $1"; }

for f in site/*.html; do
  n=$(basename "$f")
  # 1. every page carries a Content-Security-Policy and a referrer policy as <meta>
  grep -q 'http-equiv="Content-Security-Policy"' "$f" && ok "$n: CSP meta" || bad "$n: no CSP meta"
  grep -q 'name="referrer"' "$f" && ok "$n: referrer meta" || bad "$n: no referrer meta"
  # 2. the CSP never allows unsafe-eval, unsafe-inline scripts or wildcards for scripts
  csp=$(grep -o 'http-equiv="Content-Security-Policy" content="[^"]*"' "$f")
  scriptsrc=$(printf '%s' "$csp" | grep -o "script-src[^;]*")
  case "$scriptsrc" in *unsafe-eval*|*unsafe-inline*|*" * "*|*" *") bad "$n: script-src too permissive";; *) ok "$n: script-src strict";; esac
  # 3. every inline script has its hash in the CSP, and no inline event handlers exist
  python3 -I - "$f" "$csp" <<'PY' || bad "$n: inline script not covered by CSP"
import sys, re, hashlib, base64
html = open(sys.argv[1], encoding="utf8").read()
csp = sys.argv[2]
for m in re.finditer(r"<script(?![^>]*\ssrc=)[^>]*>(.*?)</script>", html, re.S):
    h = "sha256-" + base64.b64encode(hashlib.sha256(m.group(1).encode()).digest()).decode()
    if h not in csp:
        sys.exit(1)
PY
  grep -qE '\son[a-z]+="' "$f" && bad "$n: inline event handler" || ok "$n: no inline handlers"
done

# 4. no target=_blank without noopener, no http:// resources (XML namespaces excepted)
grep -rnE 'target="_blank"' site --include=*.html | grep -v noopener && bad "target=_blank without noopener" || ok "links: noopener"
grep -rnoE 'http://[^"'"'"' )]+' site | grep -vE 'w3.org|sitemaps.org' && bad "http:// resource" || ok "no http:// resources"

# 5. nothing that looks like a secret or a personal path in the published folder
grep -rnE 'ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|/Users/[A-Za-z]' site && bad "secret or personal path in site/" || ok "no secrets or personal paths"

# 6. URL parameters are never concatenated into a selector
grep -nE 'querySelector[A-Za-z]*\([^)]*q\.get\(' site/site.js && bad "q.get() inside a selector" || ok "q.get() not used in selectors"

# 7. the vendored ALTCHA widget is the pinned one
if [ -f site/altcha.js ]; then
  pin=$(cat Tests/site/altcha.sha256 2>/dev/null)
  cur=$(shasum -a 256 site/altcha.js | cut -d' ' -f1)
  [ "$pin" = "$cur" ] && ok "altcha.js matches the pinned hash" || bad "altcha.js differs from Tests/site/altcha.sha256"
else
  bad "site/altcha.js missing"
fi

# 8. workflow actions are pinned to full commit hashes
grep -nE 'uses: *[^ ]+@' .github/workflows/*.yml | grep -vE '@[0-9a-f]{40}' && bad "action not pinned to a full hash" || ok "actions pinned by hash"

echo "---"; [ $fail -eq 0 ] && echo "all checks passed" || echo "$fail check(s) failed"
exit $((fail>0))
