# Beta forum — the website texts, version 1.1 (WEB-02, WEB-03)

The forum's changes to the website texts are no longer a proposal. They are
written into **version 1.1** of the three texts:

- the source, in the app repository: `docs/legal/website/PRIVACY_POLICY.md`,
  `COOKIE_POLICY.md` and `TERMS_OF_SERVICE.md`;
- the pages here: `/privacy/`, `/cookies/` and `/terms/`, generated from that
  source in the 1.0 pages' exact markup. Regenerating 1.0 that way reproduces the
  live 1.0 pages byte for byte.

## Owner decisions, 27 September 2026

1. **When 1.1 takes effect:** on the day the forum is switched on, published
   in the same step: **27 September 2026**, the effective date in all three
   texts. The owner moved Supabase to Pro the same day, before the switch-on.
   Until then the pages carried `2026-MM-DD`; `scripts/check-site-texts.sh`
   (CI job `site`) refuses to let a page ship like that.
2. **Confidentiality:** a request in the forum rules, not a binding duty. The
   rule reads "Please don't share screenshots or details of unreleased features
   outside the forum." There is nothing about it in the Terms.
3. **Ideas and feedback:** Rebornly may use them freely (Terms §3a point 5).

## What 1.1 changes

- **Privacy Policy.**
  - New §2a covers the forum: who it is for, what is stored, who sees it, the legal basis, how long it is kept, and what erasure removes.
  - §2 adds one sentence: an invitation to the beta may include access to the forum. That is the same purpose the sign-up consent already covers, so no new consent is needed.
  - §4 says request logs are kept **7 days**, not 1. That is the Pro plan's retention, and it applies to the sign-up too.
  - §5 mentions the sign-in session in local storage.
  - §6 adds the forum project and **Resend**, and says Supabase keeps 7 days of backups.
  - §7, §8 and §9 now cover the forum as well.
- **Cookie Policy.** New §2a describes the forum's sign-in session, stored in `localStorage` under `rebornly.forum.session`. It is strictly necessary, so there is still no banner.
- **Terms of Service.** §1 and §2 mention the forum. A new §3a sets the forum's terms. §4, §5 and §8 follow.

## At publication (owner, the same day)

- Set the Edge Function secret `REBORNLY_WEBSITE_PRIVACY_POLICY_VERSION` to
  `1.1` for `website-intake` in the **Production** project. New sign-ups then
  record the version in force. The forum's own project does not use it.
- Merge the app repository's docs PR and this repository's switch-on PR together.
