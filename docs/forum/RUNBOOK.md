# Beta forum — owner runbook (WEB-02)

Everything here is done by the owner in the Supabase and Resend dashboards.
Nothing touches the app's Staging or Production project. Plan about 45 minutes.
Placeholders are written like `<this>`.

## 1. Supabase plan and project

1. Supabase → your organisation → **Billing** → move to **Pro** (backups; projects
   no longer pause after a week).
2. **New project**
   - Name: `rebornly-beta-forum`
   - Region: **Central EU (Frankfurt)**
   - Database password: generate one and keep it in your password manager.
3. Wait until the project is ready.

## 2. The database

1. **SQL Editor** → New query → paste the whole file
   `supabase/migrations/20260927000100_web02_beta_forum.sql` → **Run**. Then do
   the same with `supabase/migrations/20260928000100_web03_dsa_notices_and_statements.sql`.
   Run them in that order. Both should finish without an error.
2. Invite yourself (one line, your own address):

   ```sql
   insert into forum.invitations (email) values (lower('<your address>'));
   ```

3. **Project Settings → Data API**: *Exposed schemas* must be `public` only (the
   default). Do **not** add `forum`.

## 3. Sign-in

**Authentication → Sign In / Providers**

- **Email**: on. *Confirm email*: on. *Email OTP expiration*: `600` seconds.
  *Email OTP length*: `6`.
- **Allow new users to sign up**: on. (The hook in step 4 lets only invited
  addresses through.)
- Every other provider, phone and **anonymous sign-ins**: off.

**Authentication → URL Configuration**

- Site URL: `https://rebornlyapp.com/forum/`
- Redirect URLs: `https://rebornlyapp.com/forum/` (only this one).

## 4. The invitation check (Auth hook)

**Authentication → Hooks → Add hook → Before User Created**

- Type: **Postgres**
- Schema `public`, function **`forum_before_user_created`**
- Enable it and save.

Test: in a private window, go to the forum later (step 7) and ask for a code for
an address you have *not* invited. No email may arrive.

## 5. Email through Resend

1. Resend → **API Keys** → Create: name `rebornly-beta-forum`, permission
   **Sending access**, domain `rebornlyapp.com`. Copy the key once.
2. Supabase → **Authentication → Emails → SMTP Settings** → enable custom SMTP:
   - Host `smtp.resend.com`, port `587`
   - Username `resend`, password: the key from step 1
   - Sender email `no-reply@rebornlyapp.com`, sender name `Rebornly`
3. **Authentication → Emails → Templates**. Set **both** *Confirm signup* and
   *Magic Link* to:
   - Subject: `Your Rebornly beta forum code`
   - Body: the whole file `supabase/templates/sign-in-code.html`

   Both are needed: a first sign-in sends *Confirm signup*, later ones send
   *Magic Link*. Neither contains a link, only the code.

## 6. Switching the website on

Send Claude two values from **Project Settings → API Keys** / **Data API**. Both are
public by design and safe to paste in chat:

- Project URL, `https://<project-ref>.supabase.co`
- **Publishable** key, `sb_publishable_…` (never the secret key)

Claude then opens two PRs.

- **rebornly-web:** sets the two values in `forum/config.js`, puts the URL in
  `connect-src` in `forum/index.html`, and fills in the effective date of the
  texts' **version 1.1** (`docs/forum/LEGAL_TEXT_CHANGES.md`).
- **The app repository:** a documents PR with the same date in
  `docs/legal/website/`.

The same day, in this order:

1. You have moved to **Pro** (step 1). Version 1.1 says request logs are kept
   7 days, which is true only on Pro.
2. Merge both PRs.
3. In the **Production** project (not the forum's), set the Edge Function
   secret `REBORNLY_WEBSITE_PRIVACY_POLICY_VERSION` to `1.1` for
   `website-intake`.

The forum and the new texts go live together.

## 7. Your moderator role

1. Open `https://rebornlyapp.com/forum/`, ask for a code with your address, sign
   in and join with your forum name.
2. Back in the SQL Editor:

   ```sql
   update forum.members set role = 'moderator'
    where user_id = (select id from auth.users where email = lower('<your address>'));
   ```

3. Reload the forum: **Moderation** appears in the top bar.

The moderator role is only ever granted like this, by direct database access.

## 7b. Go-live check (10 minutes, before inviting anyone else)

Tick each one. If one fails, stop and tell Claude.

You need two test addresses of your own (**A** and **B**) and three separate
browsers or devices, because every private window of one browser shares one
sign-in: for example your own browser as yourself, a phone as A, and a second
browser (Edge, Firefox) as B.

1. **Uninvited address:** in the second browser, ask for a code for B before
   you have invited it. No email arrives.
2. **Invited members:** as yourself, invite A and B (Moderation → Invite).
   Sign in and join as A on the phone, and as B in the second browser.
3. **Announcements are team-only:** as A, open Announcements. There is no
   *Start a thread* button.
4. **No moderation for members:** as A, go to
   `https://rebornlyapp.com/forum/#/mod`. It says *Not found*.
5. **A reply to hide:** as yourself, start a thread in General. As A, reply to it.
6. **Hidden means gone:** as yourself, hide A's reply with a reason. A still
   sees the reply, with your reason. B opens the same thread: the reply is not
   there at all, and the thread shows no replies.
7. **Sign out and back in** as A: a new code arrives and works.
8. **Clean up:** run `select forum.erase_member('<A>');` and
   `select forum.erase_member('<B>');`, and delete your test thread.

## 8. Everyday use

- **Invite:** Moderation → *Invite an email address*. This only lets the address
  sign in; write to the person yourself and send them to
  `https://rebornlyapp.com/forum/`.
- **Reports** show under Moderation, marked *Forum rules* or *Illegal
  content*; an illegal-content notice shows the notifier's name. One marked
  *Child sexual abuse material* goes to the police at once, before anything
  else. Look at reports at least once a day during the beta. Either:
  - *Hide the post*: choose the ground (a forum rule, or the law with its
    provision) and write what happened. The author sees all of it, and so does
    the reporter's decision.
  - *No action*: write why. The member who reported reads it under My reports.
- **Suspend** a member under Moderation → Members: the ground, what happened,
  and what it followed. They see all of it.
- The member always sees that no automated means were used and how to ask for
  another look. Nothing in the forum decides by itself.
- A suspended member still sees their reports (My reports) and their posts
  (My posts), and can delete their own posts.
- **If anything in the forum suggests a threat to someone's life or safety**,
  whether from a report, an email or your own reading, report it to the police
  at once (DSA Art. 18).

## 8b. Notices of illegal content by email (EU Digital Services Act, Art. 16)

Anyone can send one to support@rebornlyapp.com, as described on
`rebornlyapp.com/forum/#/notice`. For each notice:

1. **Confirm receipt** the same or the next working day:

   > Thank you. We have received your notice about content in the Rebornly
   > beta forum. A person will look at it, and we will tell you what we decide.

2. **Look at it yourself.** If the notice says where the content is and why it
   is illegal, you can act on it. Ask the sender for anything missing.
3. **Decide.**
   - To hide the post, use *Hide*, choose the law as the ground and name the
     provision, and set *What it followed* to "A notice sent by email".
   - Otherwise take no action.
4. **Tell the sender** your decision:

   > We have looked at your notice. Our decision: [the post was hidden /
   > no action], because [reason]. If you disagree, reply to this email and
   > a person will look at it again. You can also take the matter to a
   > court.

Keep the email thread until the forum is deleted. It is the record of the
notice.

## 9. Requests from members

In the SQL Editor:

- Copy of their data (access, portability):
  `select forum.export_member('<their address>');`
- Delete them (erasure):
  `select forum.erase_member('<their address>');`
  This wipes their posts and thread titles, deletes the reports they made,
  removes their address, id and your reasons about them from the moderation
  log and from your decisions, deletes Supabase Auth's sign-in log entries that
  name them, and deletes their sign-in account (with its sessions). Replies by
  others stay, and so do other members' reports about their posts: an open one
  is decided as "removed", and its reporter sees that under My reports. A reply
  of theirs you had hidden stays hidden.
- For both requests, also search the support mailbox for notices of illegal
  content (section 8b):
  - **Notices the person sent:** include them in the copy. On erasure, delete
    them once you have told them your decision.
  - **Notices others sent that name the person:** for a copy, give the content
    without the sender's name or address (GDPR Art. 15(4)). On erasure, keep
    them: you must keep a notice until the forum is deleted, as the Privacy
    Policy says.
- Never delete a member from the Authentication → Users page instead: that
  removes the account but leaves the texts they wrote.

## 10. When the beta ends

1. Read-only:

   ```sql
   update forum.settings set read_only = true;
   ```

   Members can still read and delete their own posts. Post an announcement with
   the date the forum will be deleted.
2. After 30 days: **Project Settings → General → Delete project**. This deletes
   every account, post and log. Also delete the notice emails in the support
   mailbox (section 8b); the Privacy Policy promises they go with the forum.
   Then ask Claude to take `/forum/` off the website and remove the forum parts
   from the legal texts.
