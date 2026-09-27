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
   `supabase/migrations/20260927000100_web02_beta_forum.sql` → **Run**. It should
   finish without an error.
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

Claude then opens a small PR in rebornly-web that sets them in
`forum/config.js` and puts the URL in `connect-src` in `forum/index.html`. The
forum goes live when you merge it.

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

## 8. Everyday use

- **Invite:** Moderation → *Invite an email address*. This only lets the address
  sign in; write to the person yourself and send them to
  `https://rebornlyapp.com/forum/`.
- **Reports** show under Moderation. Hide the post with a reason (the author
  sees it) or resolve the report with a note.
- **Suspend** a member under Moderation → Members, with a reason they will see.

## 9. Requests from members

In the SQL Editor:

- Copy of their data (access, portability):
  `select forum.export_member('<their address>');`
- Delete them (erasure):
  `select forum.erase_member('<their address>');`
  This wipes their posts, thread titles and reports, and deletes their sign-in
  account. Replies by others stay.
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
   every account, post and log. Then ask Claude to take `/forum/` off the website
   and remove the forum parts from the legal texts.
