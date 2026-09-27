# Beta forum — proposed changes to the website texts (WEB-02)

**Status: draft for the owner's approval. Nothing here is in force.** The texts
in force (Version 1.0, effective 2026-09-25) stay unchanged until the owner
approves these changes. The forum must not open before that.

After approval, the same wording goes into both copies of each text: the
Markdown source in the app repository (`docs/legal/website/*.md`, a small docs
PR there) and the pages here (`/privacy/`, `/cookies/`, `/terms/`), as
Version 1.1 with a new effective date.

**One Version 1.1, not two in a row.** WEB-01 has already planned a Privacy
Policy 1.1 that removes the sentence saying the form is not switched on yet,
now that sign-up is live. That change and the forum changes below go out
together in the same 1.1, in both repositories.

**Production, at the moment 1.1 is published (owner):** set the Edge Function
secret `REBORNLY_WEBSITE_PRIVACY_POLICY_VERSION` to `1.1` for `website-intake`
in the Production project, so new beta sign-ups record the version in force.
The forum's own project does not use that secret.

## Two decisions for the owner

1. **Is forum content confidential?** Recommended: a *request* in the forum
   rules, not a binding duty: "Please don't share screenshots or details of
   unreleased features outside the forum." A binding confidentiality term with
   consequences would be heavy for a friendly beta and hard to enforce.
2. **May Rebornly use ideas from the forum freely?** Recommended: yes, the
   usual feedback clause (Terms, new §3a, point 5 below). Without it, a tester
   who suggested a feature could later claim a share in it.

---

## Privacy Policy

### New section after §2: "2a. The beta forum"

> **Who it is for.** The beta forum at rebornlyapp.com/forum/ is for people we
> invite. If you signed up for the beta on this website, we may use your email
> address to invite you to the forum, as part of inviting you to the beta.
>
> **What we store**
> - your email address, to invite you and to send your sign-in codes;
> - the name you choose for the forum;
> - your confirmation that you are 18 or older, and which version of the forum
>   rules you accepted, and when;
> - what you write: threads, replies and edits;
> - reports you send about posts, and reports others send about yours;
> - moderators' decisions about your posts or your account, with their reasons,
>   in a moderation log;
> - your sign-in session: when you signed in, and the IP address and browser
>   you signed in from;
> - a security log of sign-in events kept by our sign-in service (for example
>   when a code was sent or used), which names your email address.
>
> A post a moderator hides disappears for other members; you still see it,
> with the reason.
>
> **Who sees it.** Other members see your forum name and what you write. They
> never see your email address. The Rebornly team, as moderators, sees your
> email address and the reports.
>
> **Why, and our legal basis.** To run the forum you joined (Article 6(1)(b)
> GDPR), and to keep it safe and moderate it (our legitimate interest,
> Article 6(1)(f) GDPR).
>
> **How long.** You can delete your own posts at any time; the text is then
> gone. The forum is used only before and during the beta. When the beta ends,
> the forum becomes read-only for 30 days and is then deleted completely,
> including every account, post, report and log. You can ask us to delete your
> forum account earlier; see §7. We then delete your account, sessions,
> reports and sign-in log entries, wipe what you wrote, and remove your
> address and our reasons about you from the moderation log. Replies others
> wrote stay.

### §4 "Technical data" — add to the list of request logs

> …or when you use the beta forum…

### §5 "Cookies" — replace

> Rebornly does not set analytics or marketing cookies. If you sign in to the
> beta forum, your browser keeps your sign-in session in its local storage so
> that you stay signed in. See our Cookie Policy.

### §6 "Service providers" — table

- Supabase row: "Receives the form, stores the sign-ups and counts, **and runs
  the beta forum (a separate project)**", same region.
- New row: **Resend** — sends the sign-in codes for the beta forum — Resend,
  Inc., USA; add Resend to "Transfers outside the EU/EEA".

### §7 "Your rights" — add

> For the beta forum, email support@rebornlyapp.com from the address you were
> invited with.

### §9 "Security" — add

> The beta forum's database can be read and written only through checked
> functions that let members see nothing but the forum itself; you sign in with
> a one-time code sent to your email address, and only invited addresses can
> sign in.

---

## Cookie Policy

### §2 — replace the first paragraph and the last sentence

> Rebornly does not set analytics or marketing cookies. The website stores
> nothing on your device, with one exception you choose yourself:
>
> **Signing in to the beta forum.** When you sign in, the website keeps your
> sign-in session (a token) in your browser's local storage, so you stay signed
> in on that device. This is strictly necessary for the forum you asked to use,
> so it needs no consent. It is removed when you sign out, and you can also
> clear it in your browser. If you do not use the forum, nothing is stored.

> Because nothing is stored unless you sign in to the forum, and that storage
> is strictly necessary, we do not show a cookie banner.

---

## Terms of Service

### §2 "What the website is" — add

> …and hosts a closed forum for people invited to the beta.

### New section after §3: "3a. The beta forum"

> 1. The forum is for people we invite, and only while the beta runs. You must
>    be 18 or older.
> 2. You follow the forum rules shown when you join, at rebornlyapp.com/forum/.
> 3. What you write stays yours. You let Rebornly show it in the forum for as
>    long as the forum exists.
> 4. You can report a post that breaks the rules or the law with the Report
>    button. Anyone, member or not, can also report illegal content to
>    support@rebornlyapp.com.
> 5. If you share ideas or feedback, Rebornly may use them to develop Rebornly
>    without owing you anything. *(Owner decision 2.)*
> 6. Moderators may hide posts or suspend accounts that break the rules or the
>    law. We tell you what we did and why. If you disagree, write to
>    support@rebornlyapp.com and a person will look at it again.
> 7. When the beta ends, the forum becomes read-only for 30 days and is then
>    deleted. We may also close it earlier.

### §4 "Acceptable use" — add

> …or post anything in the beta forum that breaks its rules.
