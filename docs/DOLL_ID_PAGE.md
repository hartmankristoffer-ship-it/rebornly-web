# Doll ID links (DOLL-ID-01, app issue #132)

Every Doll in the app has a permanent public ID, `RB-XXXXXX`, and its QR code
carries only `https://rebornlyapp.com/d/RB-XXXXXX`. On a phone where the app is
installed and linked to this domain, the app opens that address. Everywhere
else it reaches this website, which has no page there.

## Parts

| Part | Where |
| --- | --- |
| The page for `/d/…` and every other unknown path | `404.html` |
| Android App Links statement list | `.well-known/assetlinks.json`, exactly `[]` |
| iOS Universal Links file | `.well-known/apple-app-site-association`, exactly `{"applinks":{"details":[]}}` |
| Tests | `scripts/test-site-pages.mjs`, in CI as `.github/workflows/site-pages.yml` |

## The page

- GitHub Pages answers every path that has no file with `/404.html` and status
  404, and the address bar keeps the path. With no JavaScript, and for any path
  that is not a Doll ID, the page is a plain "Page not found".
- One inline script reads `location.pathname`. Only
  `^/d/(RB|rb|Rb|rB)-[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{6}/?$` goes further: the
  six characters are uppercased and the check character is tested with the
  app's rule (Luhn mod 32 over `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, weights 1,
  2, 1, … from the right). It is the same rule as the app's `DollCode` and the
  database's `security.doll_code_is_valid`. The shared test IDs are
  `RB-DVP8B0`, `RB-HKYRKE`, `RB-RJGTKV`, `RB-DJ9XWC` and `RB-TTX466`.
- The page is strict. It does not read look-alike letters (O, I, L, U) as
  digits, because a QR code always carries the printed form. Typing an ID by
  hand is for the app's search, which is forgiving.
- When the ID is right, the page shows only "This doll is registered on
  Rebornly", the ID as printed, and "Rebornly is coming soon". The site header
  and footer stay, so the legal links are still there. The title is "Rebornly".
- The page cannot know whether that Doll exists or who may see it. Every ID
  with a right check character reads the same, including an invented one
  (about 1 in 32 pass the check). This matches the app's rule that a missing
  Doll and a Doll the viewer may not see answer the same way.
- It makes no request and stores nothing. It shows no Doll data. It has
  `noindex`, and its 404 status also keeps it out of search results. Visits
  are not counted: Privacy §3 counts three things, and counting scans would be
  a text change. GitHub's hosting logs record the path, as they do for any
  page (Privacy §4 and §6).
- The Content-Security-Policy allows only the sha256 of that one script. If
  you change the script, update the hash: the test prints the right one when
  it fails. `.gitattributes` keeps `404.html` LF, so the committed bytes match
  what a browser hashes.

## The association files

The files are published granting nothing (owner decision, 29 September 2026).
No installable Android test build exists yet, so there is no certificate
fingerprint to list, and Google Play's app-signing fingerprint and the Apple
Team ID do not exist either. A placeholder must never be published. The app
repository (Rebornly) keeps the templates these files are made from:
`docs/etapp_3c/well-known/assetlinks.template.json` and
`docs/etapp_3c/well-known/apple-app-site-association.template.json`.

`.nojekyll` must stay, or GitHub Pages drops the dot-folder. GitHub Pages
serves the extensionless AASA as `application/octet-stream`, so after a real
deploy, check that Apple accepts it:
`curl -sI https://rebornlyapp.com/.well-known/apple-app-site-association`,
then `https://app-site-association.cdn-apple.com/a/v1/rebornlyapp.com`.

## Follow-ups

In the owner's order (29 September 2026):

1. **The first installable Android test build's certificate SHA-256 into
   `assetlinks.json`.** This goes in as soon as that build exists; it does not
   wait for Google Play. It is one statement shaped like the app repo's
   `assetlinks.template.json`: relation
   `delegate_permission/common.handle_all_urls`, package
   `com.rebornlyapp.rebornly`, and the test build's certificate SHA-256. A dev
   or staging build installs under its own application ID and needs a
   statement of its own. Check it with
   `adb shell pm verify-app-links --re-verify com.rebornlyapp.rebornly` and
   Google's `statements:list` API.
2. **Google Play's app-signing fingerprint, added later.** Once Play App
   Signing re-signs the app, its SHA-256 joins the test build's in the same
   statement's `sha256_cert_fingerprints`. Check it the same way.
3. **The Apple Team ID into `appIDs` of the AASA.** Once the Apple Developer
   membership exists, the AASA is the app repo's
   `apple-app-site-association.template.json` with the Team ID in place of
   `<APPLE_TEAM_ID>`: one `details` entry whose `appIDs` is
   `<TEAMID>.com.rebornlyapp.rebornly`, with the template's components, which
   claim `/r/*` and `/d/*`. The app needs nothing else: it already has the
   Associated Domains entitlement `applinks:rebornlyapp.com`, and iOS takes the
   paths from this file.
4. **Store links replace "Rebornly is coming soon"** once the app is in the
   stores. Changing only the markup does not change the script hash.

**Before 1 and 3, the owner decides whether `/r/` stays an app link.** Android
verifies a whole host, not a path. Once `assetlinks.json` verifies, the app's
existing verified link filter for `/r/` also takes over the email links
`/r/AUTH-03` (email verified) and `/r/AUTH-06` (new password). Those links
would open in the app instead of on these pages, which changes the live
sign-in email flow. One of two things must be decided first:

- keep `/r/` in the app, and prove AUTH-03 and AUTH-06 work in the app; the
  AASA then claims the template's `/r/*` and `/d/*`; or
- narrow the Android filter to `/d/`; the app repo's AASA template then drops
  `/r/*`, so both platforms claim `/d/` only.

Either way both platforms claim the same paths, and the app repo's template
changes first; this file follows it. When real values go in,
`scripts/test-site-pages.mjs` changes with them: it pins exactly the empty
files today, and will pin the decided statements then.

## After merging

- `gh api repos/hartmankristoffer-ship-it/rebornly-web/pages --jq .custom_404`
  should read `true`.
- `https://rebornlyapp.com/d/RB-DVP8B0` should show the Doll view, and
  `https://rebornlyapp.com/d/RB-DVP8B1` should show "Page not found".
- Both `/.well-known/` addresses should answer 200.
