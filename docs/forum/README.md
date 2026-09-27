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
| Proposed legal text changes | `docs/forum/LEGAL_TEXT_CHANGES.md` |

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
- **Hidden posts** keep their text for the author and the moderators. The author
  sees the reason (DSA Art. 17), and other members see only that the post was
  removed.
- **The page** renders everything a member wrote as text (`textContent`), loads
  no outside script, and makes no request while `config.js` is empty.

## Testing

```bash
bash scripts/test-forum.sh
```

This starts a throwaway `supabase/postgres` container, applies the migration and
runs the pgTAP suite. It also checks that the rules version in `forum.js`
matches the one the database accepts. Nothing shared is touched.

To try the whole forum locally, run `npx supabase start` in this folder. It
starts a stack of its own, with project id `rebornly-web-forum` on ports
554xx. Serve the site with `forum/config.js` pointing at
`http://127.0.0.1:55421` and its publishable key, and put that URL in
`connect-src`. Keep those changes local and never commit them. The seed
invites `owner@example.test` and `member@example.test`, and their codes arrive
at `http://127.0.0.1:55424`.
