# The beta forum (WEB-02, rebornly-web #12)

A closed, invitation-only, text-only forum at `rebornlyapp.com/forum/`, used
only before and during the Rebornly beta. It is **outside the app** and is not
Circles: it has its own Supabase project and shares no account or data with the
app.

## Parts

| Part | Where |
| --- | --- |
| Page, styles, client | `forum/index.html`, `forum/forum.css`, `forum/forum.js` |
| Project address (off while empty) | `forum/config.js` |
| Schema, functions, Auth hook | `supabase/migrations/20260927000100_web02_beta_forum.sql` |
| Sign-in code email | `supabase/templates/sign-in-code.html` |
| Tests | `supabase/tests/forum.test.sql`, run by `scripts/test-forum.sh` and CI (`.github/workflows/forum-tests.yml`) |
| Local development stack | `supabase/config.toml`, `supabase/seed.sql` |
| Owner setup and daily use | `docs/forum/RUNBOOK.md` |
| The website texts, version 1.1 | `docs/forum/LEGAL_TEXT_CHANGES.md` |

## How access works

- **Only invited addresses can create a sign-in account.** The Supabase Auth
  hook `public.forum_before_user_created` refuses every other address.
- **Joining needs the invitation too**, plus 18+ and the current rules version,
  so the forum stays closed even if the hook were switched off.
- **No table can be read or written directly.** Schema `forum` is not exposed,
  and `anon` and `authenticated` hold no privilege on it. Every read and write
  is a `SECURITY DEFINER` function with an empty `search_path` that checks
  membership first. `anon` can call none of them.
- **Moderators** are members with `role = 'moderator'`, set only by direct
  database access. No function writes the role, and a test pins that.
- **Hidden posts** keep their text for the author and the moderators, and the
  author sees the reason (DSA Art. 17). For every other member a hidden post is
  gone: left out of the thread, its counts and its times.
- **Hidden threads** (a moderator hid the opening post) are gone for everyone
  who took no part in them. The author sees the thread with the reason. A
  member who replied keeps the thread in view, without its title, and sees only
  their own replies there, so their words do not vanish without a word. Once
  the thread's author has been erased, a hidden thread is gone for everyone but
  the moderators, repliers included.
- **Erasure** (`forum.erase_member`) locks the member first. Every call that
  writes holds a shared lock on the caller's member row, so a post written while
  the erasure runs is either wiped by it or refused. A moderator acting on a
  post locks the post's author first, in the same order, and the erasure clears
  the moderation log once more at its end. `supabase/tests/erase_race.sh`
  proves this with two real sessions, and fails if they did not overlap.
- **Reads never lock.** The Data API runs a `STABLE` function in a read-only
  transaction, so the read functions check membership without a lock.
  `supabase/tests/read_only_calls.sh` runs every one of them in a real
  read-only transaction, and a pgTAP pin stops a read from taking a lock or a
  write from skipping one.
- **The page** renders everything a member wrote as text (`textContent`), loads
  no outside script, and makes no request while `config.js` is empty.

### Accepted trade-off: the sign-in endpoint shows who is invited

The page answers the same whether or not an address is invited. Supabase Auth's
own endpoint does not: anyone who calls `POST /auth/v1/otp` directly with the
public key gets a 403 from the invitation hook for an uninvited address and a
200 for an invited one. The alternative is to let every address through and
check invitations only when joining. That would make the forum send a code
email to any address anyone types in, which is worse: it can be used to flood a
stranger's inbox from `rebornlyapp.com`. Supabase's per-IP rate limit on that
endpoint bounds the guessing. What leaks is only that an address was invited to
the beta forum.

## Testing

```bash
bash scripts/test-forum.sh
```

This starts a throwaway `supabase/postgres` container, applies the migration and
runs the pgTAP suite. It then runs `read_only_calls.sh` (every read in a
read-only transaction) and `erase_race.sh` (an erasure against a member who is
writing at the same moment). It also checks that the rules version in
`forum.js` matches the one the database accepts. Nothing shared is touched.

To try the whole forum locally, run `npx supabase start` in this folder. It
starts a stack of its own, with project id `rebornly-web-forum` on ports
554xx. Serve the site with `forum/config.js` pointing at
`http://127.0.0.1:55421` and its publishable key, and put that URL in
`connect-src`. Keep those changes local and never commit them. The seed
invites `owner@example.test` and `member@example.test`, and their codes arrive
at `http://127.0.0.1:55424`.
