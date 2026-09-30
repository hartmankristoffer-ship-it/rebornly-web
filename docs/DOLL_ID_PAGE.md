# Doll ID links (DOLL-ID-01, app issue #132)

Every Doll in the app has a permanent public ID, `RB-XXXXX-XXXXX`, and its QR
code carries only `https://rebornlyapp.com/d/RB-XXXXX-XXXXX`. On a phone where
the app is installed and linked to this domain, the app opens that address.
Everywhere else it reaches this website, which has no page there.

## The ID

- It is `RB-`, five characters, a dash and five more characters: 14 in all,
  always printed in capitals. The ten characters come from
  `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, which has no I, L, O or U. The first
  nine are random and the tenth is the check character.
- The check character follows Luhn mod 32 over all ten characters; the prefix
  and the dashes do not count. From the right the weights are 1, 2, 1, 2 …, a
  weighted value `a` adds `a div 32 + a mod 32`, and the ID is right when the
  sum is a multiple of 32. The rule catches every single wrong character and
  every swap of two neighbours except `0` and `Z`.
- Why ten characters: the Gate 1 review asked for an ID long enough that
  guessing one is useless, and the owner decided this form on 30 September
  2026 (issue #132, point 4 of the owner decisions). Nine random characters
  give 32^9 = 35,184,372,088,832 IDs. Even with a million Dolls registered, a
  guessed ID with a right check character belongs to a Doll about once in 35
  million tries. Two groups of five are easier to read aloud and copy than one
  run of ten.
- The six-character draft of 28 September was never printed, and this page
  does not read it: `/d/RB-DVP8B0` is "Page not found".

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
  `^/d/(RB|rb|Rb|rB)-([0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{5})-([0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{5})/?$`
  goes further: the ten characters are uppercased and the check character is
  tested with the rule above. It is the same rule as the app's `DollCode` and
  the database's `security.doll_code_is_valid`. The shared test IDs are
  `RB-T9T3A-2K714`, `RB-FWGCW-ASFZN`, `RB-QRNC4-2P59M`, `RB-P4JGP-82YE7` and
  `RB-6X8C3-MPR4M`; `RB-T9T3A-2K715` is the shared mistyped one.
- The page is strict: it reads only the printed shape. It does not read
  look-alike letters (O, I, L, U) as digits, a missing or moved dash, or a
  space, because a QR code always carries the printed form. Typing an ID by
  hand is for the app's search, which is forgiving: it ignores spaces, dashes
  and letter case, and reads O as 0 and I or L as 1. A transfer receipt number
  such as `RB-TR-000123` is never a Doll ID.
- When the ID is right, the page shows only "This doll is registered on
  Rebornly", the ID as printed (`RB-XXXXX-XXXXX`, in capitals), and "Rebornly
  is coming soon". The site header and footer stay, so the legal links are
  still there. The title is "Rebornly".
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
- `https://rebornlyapp.com/d/RB-T9T3A-2K714` should show the Doll view, and
  `https://rebornlyapp.com/d/RB-T9T3A-2K715` should show "Page not found".
- Both `/.well-known/` addresses should answer 200.
