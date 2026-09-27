#!/usr/bin/env bash
# WEB-03: checks that need no database, run by CI on every change to the
# legal pages or the forum page:
#   - no legal page is published with an unfilled effective date;
#   - the three legal pages carry the same version;
#   - the forum's project address and its Content-Security-Policy agree: off
#     means an empty config and connect-src 'none'; on means connect-src names
#     exactly the configured origin.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

for page in privacy cookies terms; do
  if grep -q 'MM-DD' "$page/index.html"; then bad "$page: the effective date is not filled in"
  else ok "$page: the effective date is filled in"; fi
done

versions="$(for page in privacy cookies terms; do
  grep -o 'class="meta">Version [0-9.]*' "$page/index.html" | grep -o '[0-9.]*$'
done | sort -u | tr '\n' ' ')"
if [ "$(echo "$versions" | wc -w)" = "1" ]; then ok "the three legal pages carry one version ($versions)"
else bad "the legal pages carry different versions: $versions"; fi

url="$(sed -n "s/^ *FORUM_URL: '\([^']*\)',.*/\1/p" forum/config.js)"
key="$(sed -n "s/^ *FORUM_KEY: '\([^']*\)',.*/\1/p" forum/config.js)"
csp="$(grep -o 'connect-src [^;"]*' forum/index.html | tail -1)"
if [ -z "$url" ] && [ -z "$key" ]; then
  if [ "$csp" = "connect-src 'none'" ]; then ok "the forum is off and connects nowhere"
  else bad "the forum is off but its CSP says: $csp"; fi
elif [ -n "$url" ] && [ -n "$key" ]; then
  if ! echo "$url" | grep -Eq '^https://[a-z0-9]{20}\.supabase\.co$'; then bad "FORUM_URL is not a Supabase project origin: $url"
  elif [ "$csp" != "connect-src $url" ]; then bad "the forum connects to $url but its CSP says: $csp"
  else ok "the forum's CSP names exactly its project ($url)"; fi
  case "$key" in
    sb_publishable_*) ok "the forum uses a publishable key" ;;
    *) bad "FORUM_KEY is not a publishable key (never put a secret key in the page)" ;;
  esac
else
  bad "only one of FORUM_URL and FORUM_KEY is set"
fi

exit "$fail"
