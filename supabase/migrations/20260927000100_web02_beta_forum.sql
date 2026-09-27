-- WEB-02: the closed beta forum at rebornlyapp.com/forum/ (rebornly-web #12).
--
-- This runs in the forum's own Supabase project, never in the app's Staging or
-- Production project. The forum is outside the app, is not Circles, and lives
-- only before and during the beta.
--
-- Access model:
--   * Only invited email addresses can create a sign-in account: the Auth hook
--     public.forum_before_user_created refuses every other address.
--   * Nobody can read or write a table directly. The schema `forum` is not
--     exposed and anon/authenticated hold no privilege on it; every read and
--     write goes through a SECURITY DEFINER function below that checks the
--     caller's membership first.
--   * Joining needs the invitation too, so the forum stays closed even if the
--     hook were ever switched off.
--   * The moderator role is granted only by direct database access; no
--     function here can make anybody a moderator.

create schema if not exists forum;
revoke all on schema forum from public;
revoke all on schema forum from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table forum.invitations (
  email       text primary key
              check (email = lower(btrim(email))
                     and length(email) between 3 and 254
                     and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  invited_by  uuid,
  invited_at  timestamptz not null default now(),
  revoked_at  timestamptz
);

create table forum.members (
  user_id             uuid primary key references auth.users (id) on delete cascade,
  display_name        text not null check (length(display_name) between 2 and 30),
  role                text not null default 'member' check (role in ('member', 'moderator')),
  status              text not null default 'active' check (status in ('active', 'suspended')),
  suspended_reason    text,
  rules_version       text not null,
  adult_confirmed_at  timestamptz not null,
  joined_at           timestamptz not null default now(),
  check ((status = 'suspended') = (suspended_reason is not null))
);
create unique index members_display_name_key on forum.members (lower(display_name));

create table forum.categories (
  id           smallint primary key,
  slug         text not null unique,
  title        text not null,
  description  text not null,
  position     smallint not null,
  team_only    boolean not null default false
);

insert into forum.categories (id, slug, title, description, position, team_only) values
  (1, 'announcements', 'Announcements',    'News from the Rebornly team.', 1, true),
  (2, 'feedback',      'Feedback & ideas', 'What works, what does not, and what you wish for.', 2, false),
  (3, 'bugs',          'Bugs & problems',  'Something went wrong? Tell us what you did and what happened.', 3, false),
  (4, 'general',       'General',          'Say hello and talk about anything reborn.', 4, false);

create table forum.threads (
  id             uuid primary key default gen_random_uuid(),
  category_id    smallint not null references forum.categories (id),
  author_id      uuid references forum.members (user_id) on delete set null,
  title          text not null,
  created_at     timestamptz not null default now(),
  last_post_at   timestamptz not null default now(),
  pinned         boolean not null default false,
  locked         boolean not null default false,
  hidden_at      timestamptz,
  hidden_reason  text,
  hidden_by      uuid,
  deleted_at     timestamptz,
  check ((hidden_at is null) = (hidden_reason is null)),
  check ((deleted_at is null) = (title <> ''))
);
create index threads_category_order_idx on forum.threads (category_id, pinned desc, last_post_at desc);

create table forum.posts (
  id             uuid primary key default gen_random_uuid(),
  seq            bigint generated always as identity unique,
  thread_id      uuid not null references forum.threads (id) on delete cascade,
  author_id      uuid references forum.members (user_id) on delete set null,
  is_opening     boolean not null default false,
  body           text not null,
  created_at     timestamptz not null default now(),
  edited_at      timestamptz,
  deleted_at     timestamptz,
  hidden_at      timestamptz,
  hidden_reason  text,
  hidden_by      uuid,
  check ((hidden_at is null) = (hidden_reason is null)),
  check ((deleted_at is null) = (body <> ''))
);
create unique index posts_one_opening_key on forum.posts (thread_id) where is_opening;
create index posts_thread_order_idx on forum.posts (thread_id, seq);
create index posts_author_recent_idx on forum.posts (author_id, created_at);

create table forum.reports (
  id           uuid primary key default gen_random_uuid(),
  post_id      uuid not null references forum.posts (id) on delete cascade,
  reporter_id  uuid references forum.members (user_id) on delete set null,
  reason       text not null,
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  resolved_by  uuid,
  resolution   text,
  check ((resolved_at is null) = (resolution is null))
);
create unique index reports_one_open_key on forum.reports (post_id, reporter_id) where resolved_at is null;
create index reports_reporter_recent_idx on forum.reports (reporter_id, created_at);

create table forum.moderation_log (
  id            bigint generated always as identity primary key,
  moderator_id  uuid,
  action        text not null,
  target        text not null,
  reason        text,
  created_at    timestamptz not null default now()
);

-- One row of forum-wide state. read_only is switched on by direct database
-- access when the beta ends: members can still read, delete their own posts
-- and report, but not write; moderators can still post announcements.
create table forum.settings (
  id         boolean primary key default true check (id),
  read_only  boolean not null default false
);
insert into forum.settings default values;

revoke all on all tables in schema forum from public;
revoke all on all tables in schema forum from anon, authenticated;
revoke all on all sequences in schema forum from public;
revoke all on all sequences in schema forum from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers (not callable by clients: they live in the unexposed schema, which
-- anon and authenticated cannot use)
-- ---------------------------------------------------------------------------

-- The version of the forum rules a member accepts when joining. The client
-- sends the version it showed; a mismatch refuses the join.
create function forum.rules_version() returns text
language sql immutable set search_path = '' as $$ select '1.0'::text $$;

create function forum.fail(p_code text) returns void
language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = 'P0001', message = 'forum:' || p_code;
end;
$$;

-- Text a member writes may hold line breaks and tabs, but no other control
-- characters. Built with chr() so the file carries no raw control bytes.
create function forum.text_ok(p_text text) returns boolean
language sql immutable set search_path = '' as $$
  select p_text !~ ('[' || chr(1) || '-' || chr(8) || chr(11) || chr(12)
                    || chr(14) || '-' || chr(31) || chr(127) || ']')
$$;

create function forum.clean_title(p_title text) returns text
language plpgsql set search_path = '' as $$
declare
  v text := btrim(coalesce(p_title, ''));
begin
  if length(v) < 3 or length(v) > 120 or not forum.text_ok(v) or v ~ '[\r\n\t]' then
    perform forum.fail('invalid_title');
  end if;
  return v;
end;
$$;

create function forum.clean_body(p_body text) returns text
language plpgsql set search_path = '' as $$
declare
  v text := btrim(coalesce(p_body, ''), ' ' || chr(9) || chr(10) || chr(13));
begin
  if length(v) < 1 or length(v) > 10000 or not forum.text_ok(v) then
    perform forum.fail('invalid_body');
  end if;
  return v;
end;
$$;

create function forum.clean_reason(p_reason text) returns text
language plpgsql set search_path = '' as $$
declare
  v text := btrim(coalesce(p_reason, ''));
begin
  if length(v) < 3 or length(v) > 500 or not forum.text_ok(v) then
    perform forum.fail('invalid_reason');
  end if;
  return v;
end;
$$;

create function forum.clean_email(p_email text) returns text
language plpgsql set search_path = '' as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
begin
  if length(v) < 3 or length(v) > 254
     or v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    perform forum.fail('invalid_email');
  end if;
  return v;
end;
$$;

-- The checks every call makes on the member row it found.
create function forum.check_member(m forum.members, p_moderator boolean) returns forum.members
language plpgsql stable set search_path = '' as $$
begin
  if m.user_id is null then
    perform forum.fail('not_member');
  end if;
  if m.status <> 'active' then
    perform forum.fail('suspended');
  end if;
  if p_moderator and m.role <> 'moderator' then
    perform forum.fail('not_moderator');
  end if;
  return m;
end;
$$;

-- For calls that WRITE: the signed-in member, active; with p_moderator, also
-- a moderator. The member row is read FOR KEY SHARE, held to the end of the
-- call. That lock conflicts only with erase_member's FOR UPDATE, so while a
-- member is being erased every write they make waits, then finds no member
-- and fails: nothing they write can slip past the erasure. (Volatile, because
-- a non-volatile function may not lock rows.)
create function forum.require_member(p_moderator boolean default false)
returns forum.members
language plpgsql volatile set search_path = '' as $$
declare
  m forum.members;
begin
  if auth.uid() is null then
    perform forum.fail('not_signed_in');
  end if;
  select * into m from forum.members where user_id = auth.uid() for key share;
  return forum.check_member(m, p_moderator);
end;
$$;

-- For calls that only READ. The Data API (PostgREST) runs a STABLE function
-- in a read-only transaction, where no row may be locked, so reads check the
-- member without a lock. A read during an erasure writes nothing to protect.
create function forum.require_reader(p_moderator boolean default false)
returns forum.members
language plpgsql stable set search_path = '' as $$
declare
  m forum.members;
begin
  if auth.uid() is null then
    perform forum.fail('not_signed_in');
  end if;
  select * into m from forum.members where user_id = auth.uid();
  return forum.check_member(m, p_moderator);
end;
$$;

create function forum.invited(p_email text) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from forum.invitations i
    where i.email = lower(btrim(p_email)) and i.revoked_at is null
  )
$$;

create function forum.log(p_moderator uuid, p_action text, p_target text, p_reason text)
returns void language sql set search_path = '' as $$
  insert into forum.moderation_log (moderator_id, action, target, reason)
  values (p_moderator, p_action, p_target, p_reason)
$$;

-- Whether the member sees a thread in full: always, unless a moderator hid
-- it; then only its author (who sees the reason) and the moderators.
create function forum.thread_in_full(t forum.threads, m forum.members) returns boolean
language sql stable set search_path = '' as $$
  -- coalesce: a thread whose author was erased has no author (null), and a
  -- null here must mean "no", never let the thread through.
  select coalesce(t.hidden_at is null or t.author_id = m.user_id or m.role = 'moderator', false)
$$;

-- Whether the thread is in the member's view at all. Besides the above, a
-- member who replied in a thread a moderator then hid keeps it in view, so
-- their own replies do not vanish without a word; they see only their own
-- replies there, not its title (forum.thread_title) or anyone else's posts
-- (forum.post_visible).
create function forum.thread_visible(t forum.threads, m forum.members) returns boolean
language sql stable set search_path = '' as $$
  select forum.thread_in_full(t, m)
      or exists (select 1 from forum.posts p where p.thread_id = t.id and p.author_id = m.user_id)
$$;

-- The title as the member may see it: none once deleted, none for a replier
-- looking at a thread a moderator hid.
create function forum.thread_title(t forum.threads, m forum.members) returns text
language sql stable set search_path = '' as $$
  select case when forum.thread_in_full(t, m) then nullif(t.title, '') end
$$;

-- A post a moderator hid is gone for everyone but its author and the
-- moderators: left out of threads, counts and times, not shown as a
-- placeholder. In a hidden thread a replier sees only their own posts.
create function forum.post_visible(p forum.posts, t forum.threads, m forum.members) returns boolean
language sql stable set search_path = '' as $$
  select coalesce(p.author_id = m.user_id or m.role = 'moderator'
                  or (p.hidden_at is null and forum.thread_in_full(t, m)), false)
$$;

-- When the last post the given member may see was written.
create function forum.last_visible_at(t forum.threads, m forum.members) returns timestamptz
language sql stable set search_path = '' as $$
  select coalesce(max(p.created_at), t.created_at)
  from forum.posts p where p.thread_id = t.id and forum.post_visible(p, t, m)
$$;

create function forum.author_json(p_author uuid) returns jsonb
language sql stable set search_path = '' as $$
  select case
    when mem.user_id is null then jsonb_build_object('name', null, 'team', false)
    else jsonb_build_object('name', mem.display_name, 'team', mem.role = 'moderator')
  end
  from (select 1) one
  left join forum.members mem on mem.user_id = p_author
$$;

-- A post as the given member may see it: a hidden post keeps its text only
-- for its author and the moderators, and only they see the reason.
create function forum.post_json(p forum.posts, m forum.members) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'author', forum.author_json(p.author_id),
    'mine', coalesce(p.author_id = m.user_id, false),
    'opening', p.is_opening,
    'body', case
              when p.deleted_at is not null then null
              when p.hidden_at is not null
                   and p.author_id is distinct from m.user_id
                   and m.role <> 'moderator' then null
              else p.body
            end,
    'created_at', p.created_at,
    'edited_at', p.edited_at,
    'deleted', p.deleted_at is not null,
    'hidden', p.hidden_at is not null,
    'hidden_reason', case
                       when p.author_id = m.user_id or m.role = 'moderator' then p.hidden_reason
                     end
  )
$$;

create function forum.me_json(p_uid uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  m forum.members;
  v_email text;
begin
  select * into m from forum.members where user_id = p_uid;
  if found then
    return jsonb_build_object(
      'state', case when m.status = 'active' then 'member' else 'suspended' end,
      'display_name', m.display_name,
      'moderator', m.role = 'moderator',
      'suspended_reason', m.suspended_reason,
      'read_only', forum.read_only(),
      'rules_version', forum.rules_version());
  end if;
  select u.email into v_email from auth.users u where u.id = p_uid;
  return jsonb_build_object(
    'state', case when v_email is not null and forum.invited(v_email) then 'invited' else 'not_invited' end,
    'rules_version', forum.rules_version());
end;
$$;

-- Throttles: ten posts in ten minutes, five new threads an hour, twenty
-- reports a day, per member. Moderators are not throttled.
create function forum.throttle(m forum.members, p_kind text) returns void
language plpgsql stable set search_path = '' as $$
begin
  if m.role = 'moderator' then
    return;
  end if;
  if p_kind in ('post', 'thread') and (
       select count(*) from forum.posts
       where author_id = m.user_id and created_at > now() - interval '10 minutes') >= 10 then
    perform forum.fail('rate_limited');
  end if;
  if p_kind = 'thread' and (
       select count(*) from forum.threads
       where author_id = m.user_id and created_at > now() - interval '1 hour') >= 5 then
    perform forum.fail('rate_limited');
  end if;
  if p_kind = 'report' and (
       select count(*) from forum.reports
       where reporter_id = m.user_id and created_at > now() - interval '1 day') >= 20 then
    perform forum.fail('rate_limited');
  end if;
end;
$$;

create function forum.read_only() returns boolean
language sql stable set search_path = '' as $$
  select coalesce((select s.read_only from forum.settings s where s.id), false)
$$;

create function forum.require_writable(m forum.members) returns void
language plpgsql stable set search_path = '' as $$
begin
  if forum.read_only() and m.role <> 'moderator' then
    perform forum.fail('read_only');
  end if;
end;
$$;

-- The ids (as text, the form moderation_log.target uses) of everything that is
-- about one person: their address, their account, their threads and posts,
-- the reports they made and the reports made about their posts.
create function forum.targets_about(p_email text, p_uid uuid) returns text[]
language sql stable set search_path = '' as $$
  select array_remove(
    array[p_email, p_uid::text]
    || coalesce((select array_agg(t.id::text) from forum.threads t where t.author_id = p_uid), '{}')
    || coalesce((select array_agg(p.id::text) from forum.posts p where p.author_id = p_uid), '{}')
    || coalesce((select array_agg(r.id::text) from forum.reports r
                 where r.reporter_id = p_uid
                    or r.post_id in (select p.id from forum.posts p where p.author_id = p_uid)), '{}'),
    null)
$$;

-- Supabase Auth's own sign-in log (auth.audit_log_entries) names a user by id
-- and address inside a JSON payload. Matching the quoted value means one
-- address never matches inside a longer one ("ann@x.se" in "joann@x.se").
create function forum.auth_log_mentions(p_payload text, p_email text, p_uid uuid) returns boolean
language sql immutable set search_path = '' as $$
  select position('"' || p_email || '"' in lower(p_payload)) > 0
      or (p_uid is not null and position('"' || p_uid::text || '"' in lower(p_payload)) > 0)
$$;

-- For access requests (GDPR Art. 15 and 20), run by the owner in the SQL
-- editor: everything the forum project holds about one address, including
-- what Supabase Auth keeps about the sign-ins. No client can call it.
create function forum.export_member(p_email text) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_email text := forum.clean_email(p_email);
  v_uid uuid;
  v_targets text[];
  v_account jsonb;
  v_sessions jsonb := '[]'::jsonb;
  v_sign_ins jsonb := '[]'::jsonb;
begin
  select u.id, to_jsonb(u) into v_uid, v_account from auth.users u where lower(u.email) = v_email;
  v_targets := forum.targets_about(v_email, v_uid);
  -- Only the account fields that describe the person, whatever else the Auth
  -- schema version carries.
  v_account := (select jsonb_object_agg(k, v_account -> k)
                from unnest(array['id', 'email', 'created_at', 'email_confirmed_at',
                                  'confirmed_at', 'last_sign_in_at']) k
                where v_account ? k);
  if v_uid is not null and to_regclass('auth.sessions') is not null then
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''created_at'', s.created_at,
               ''updated_at'', s.updated_at, ''ip'', s.ip, ''user_agent'', s.user_agent)
               order by s.created_at), ''[]''::jsonb)
             from auth.sessions s where s.user_id = $1'
      into v_sessions using v_uid;
  end if;
  if to_regclass('auth.audit_log_entries') is not null then
    execute 'select coalesce(jsonb_agg(to_jsonb(a) - ''instance_id'' order by a.created_at), ''[]''::jsonb)
             from auth.audit_log_entries a
             where forum.auth_log_mentions(a.payload::text, $1, $2)'
      into v_sign_ins using v_email, v_uid;
  end if;
  return jsonb_build_object(
    'email', v_email,
    'account', v_account,
    'sessions', v_sessions,
    'sign_in_log', v_sign_ins,
    'invitation', (select to_jsonb(i) - 'invited_by' from forum.invitations i where i.email = v_email),
    'member', (select to_jsonb(m) from forum.members m where m.user_id = v_uid),
    'threads', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title,
                                 'created_at', t.created_at, 'deleted_at', t.deleted_at,
                                 'hidden_reason', t.hidden_reason) order by t.created_at)
                         from forum.threads t where t.author_id = v_uid), '[]'::jsonb),
    'posts', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'thread_id', p.thread_id,
                               'body', p.body, 'created_at', p.created_at, 'edited_at', p.edited_at,
                               'deleted_at', p.deleted_at, 'hidden_reason', p.hidden_reason) order by p.seq)
                       from forum.posts p where p.author_id = v_uid), '[]'::jsonb),
    'reports_made', coalesce((select jsonb_agg(jsonb_build_object('post_id', r.post_id, 'reason', r.reason,
                                      'created_at', r.created_at, 'resolution', r.resolution) order by r.created_at)
                              from forum.reports r where r.reporter_id = v_uid), '[]'::jsonb),
    -- Reports others made about this person's posts, without saying who made them.
    'reports_about_posts', coalesce((select jsonb_agg(jsonb_build_object('post_id', r.post_id, 'reason', r.reason,
                                             'created_at', r.created_at, 'resolution', r.resolution) order by r.created_at)
                                     from forum.reports r join forum.posts p on p.id = r.post_id
                                     where p.author_id = v_uid), '[]'::jsonb),
    -- Moderator actions about this person or their content in full. Actions
    -- this person took as a moderator about someone else are listed without
    -- their target or reason, which are that other person's data (Art. 15(4)).
    'moderation', coalesce((select jsonb_agg(case
                                      when l.target = any(v_targets) then
                                        jsonb_build_object('action', l.action, 'target', l.target,
                                          'reason', l.reason, 'created_at', l.created_at,
                                          'by_this_person', coalesce(l.moderator_id = v_uid, false))
                                      else
                                        jsonb_build_object('action', l.action, 'created_at', l.created_at,
                                          'by_this_person', true)
                                    end order by l.id)
                            from forum.moderation_log l
                            where l.target = any(v_targets) or l.moderator_id = v_uid), '[]'::jsonb));
end;
$$;

-- Takes a person's address and id out of the moderation log, wipes the
-- moderators' words about them and their content, and clears their id as
-- the moderator who acted.
create function forum.clear_log_about(p_email text, p_uid uuid, p_targets text[]) returns void
language sql set search_path = '' as $$
  update forum.moderation_log set target = 'erased', reason = null
   where target in (p_email, p_uid::text);
  update forum.moderation_log set reason = null
   where target = any(p_targets) and reason is not null;
  update forum.moderation_log set moderator_id = null where moderator_id = p_uid;
$$;

-- For erasure requests (GDPR Art. 17), run by the owner in the SQL editor.
-- Wipes the member's texts and the moderators' reasons about them, removes
-- their address and id from the moderation log, deletes the reports they
-- made or that concern their posts, deletes Supabase Auth's sign-in log
-- entries that name them, and finally deletes the sign-in account (which
-- takes the membership, sessions and tokens with it). Replies by others stay.
create function forum.erase_member(p_email text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_email text := forum.clean_email(p_email);
  v_uid uuid;
  v_targets text[];
  v_posts integer := 0;
  v_log integer := 0;
begin
  select u.id into v_uid from auth.users u where lower(u.email) = v_email;
  -- Lock the member first: any call they are making finishes before this
  -- goes on, and any later one waits and then fails (see require_member).
  perform 1 from forum.members where user_id = v_uid for update;
  -- Collected before anything is wiped or deleted.
  v_targets := forum.targets_about(v_email, v_uid);

  select count(*) into v_log from forum.moderation_log
   where target = any(v_targets) or moderator_id = v_uid;

  perform forum.clear_log_about(v_email, v_uid, v_targets);

  delete from forum.invitations where email = v_email;
  update forum.invitations set invited_by = null where invited_by = v_uid;

  if to_regclass('auth.audit_log_entries') is not null then
    execute 'delete from auth.audit_log_entries a where forum.auth_log_mentions(a.payload::text, $1, $2)'
      using v_email, v_uid;
  end if;

  if v_uid is null then
    return jsonb_build_object('email', v_email, 'account', false);
  end if;

  select count(*) into v_posts from forum.posts where author_id = v_uid and deleted_at is null;
  delete from forum.reports
   where reporter_id = v_uid
      or post_id in (select id from forum.posts where author_id = v_uid);
  update forum.threads
     set title = '', deleted_at = coalesce(deleted_at, now()),
         hidden_reason = case when hidden_at is not null then 'Erased on request' end,
         hidden_by = null
   where author_id = v_uid;
  -- A post a moderator hid stays hidden (others never see it), but the
  -- moderator's words about it go.
  update forum.posts
     set body = '', deleted_at = coalesce(deleted_at, now()),
         hidden_reason = case when hidden_at is not null then 'Erased on request' end,
         hidden_by = null
   where author_id = v_uid;
  -- If the person was a moderator, their id leaves the records they touched.
  update forum.threads set hidden_by = null where hidden_by = v_uid;
  update forum.posts set hidden_by = null where hidden_by = v_uid;
  update forum.reports set resolved_by = null where resolved_by = v_uid;

  delete from auth.users where id = v_uid;
  -- Once more at the end: a moderator action on their content that committed
  -- while this ran (resolving a report, say) cannot leave its words behind.
  perform forum.clear_log_about(v_email, v_uid, v_targets);
  return jsonb_build_object('email', v_email, 'account', true,
                            'posts_wiped', v_posts, 'log_rows_cleared', v_log);
end;
$$;

revoke all on all functions in schema forum from public;

-- ---------------------------------------------------------------------------
-- The Auth hook: only invited addresses may become users
-- ---------------------------------------------------------------------------

create function public.forum_before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(btrim(coalesce(event -> 'user' ->> 'email', '')));
begin
  if v_email <> '' and forum.invited(v_email) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This email address has not been invited to the Rebornly beta forum.'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Member functions
-- ---------------------------------------------------------------------------

create function public.forum_me() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    perform forum.fail('not_signed_in');
  end if;
  return forum.me_json(auth.uid());
end;
$$;

create function public.forum_join(p_display_name text, p_adult_confirmed boolean, p_rules_version text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_name text := regexp_replace(btrim(coalesce(p_display_name, '')), '[[:space:]]+', ' ', 'g');
begin
  if v_uid is null then
    perform forum.fail('not_signed_in');
  end if;
  if exists (select 1 from forum.members where user_id = v_uid) then
    perform forum.fail('already_member');
  end if;
  select u.email into v_email from auth.users u where u.id = v_uid;
  if v_email is null or not forum.invited(v_email) then
    perform forum.fail('not_invited');
  end if;
  if p_adult_confirmed is distinct from true then
    perform forum.fail('adult_required');
  end if;
  if p_rules_version is distinct from forum.rules_version() then
    perform forum.fail('rules_outdated');
  end if;
  if length(v_name) < 2 or length(v_name) > 30
     or v_name !~ '^[[:alnum:]][[:alnum:] ._-]*[[:alnum:].]$'
     or lower(v_name) ~ '(rebornly|moderator|admin|support|staff)' then
    perform forum.fail('invalid_name');
  end if;
  begin
    insert into forum.members (user_id, display_name, rules_version, adult_confirmed_at)
    values (v_uid, v_name, p_rules_version, now());
  exception when unique_violation then
    perform forum.fail('name_taken');
  end;
  return forum.me_json(v_uid);
end;
$$;

create function public.forum_categories() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_reader();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'slug', c.slug, 'title', c.title, 'description', c.description,
             'team_only', c.team_only,
             'thread_count', (select count(*) from forum.threads t
                              where t.category_id = c.id and forum.thread_visible(t, m)),
             'last_post_at', (select max(forum.last_visible_at(t, m)) from forum.threads t
                              where t.category_id = c.id and forum.thread_visible(t, m)))
           order by c.position)
    from forum.categories c), '[]'::jsonb);
end;
$$;

create function public.forum_threads(p_category text, p_limit integer default 30, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_reader();
  c forum.categories;
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  select * into c from forum.categories where slug = p_category;
  if not found then
    perform forum.fail('not_found');
  end if;
  return jsonb_build_object(
    'category', jsonb_build_object('slug', c.slug, 'title', c.title,
                                   'description', c.description, 'team_only', c.team_only),
    'total', (select count(*) from forum.threads t
              where t.category_id = c.id and forum.thread_visible(t, m)),
    'threads', coalesce((
      select jsonb_agg(row_json order by pinned desc, last_at desc, id)
      from (
        select t.pinned, v.last_at, t.id,
               jsonb_build_object(
                 'id', t.id,
                 'title', forum.thread_title(t, m),
                 'author', forum.author_json(t.author_id),
                 'created_at', t.created_at,
                 'last_post_at', v.last_at,
                 'replies', v.replies,
                 'pinned', t.pinned,
                 'locked', t.locked,
                 'deleted', t.deleted_at is not null,
                 'hidden', t.hidden_at is not null) as row_json
        from forum.threads t
        cross join lateral (
          select forum.last_visible_at(t, m) as last_at,
                 (select count(*) from forum.posts p
                  where p.thread_id = t.id and not p.is_opening and forum.post_visible(p, t, m)) as replies
        ) v
        where t.category_id = c.id and forum.thread_visible(t, m)
        order by t.pinned desc, v.last_at desc, t.id
        limit v_limit offset v_offset
      ) page), '[]'::jsonb));
end;
$$;

-- Posts come in pages after a cursor, the id of the last post already shown
-- (p_after), so a post hidden or restored meanwhile never makes the next page
-- skip or repeat one.
create function public.forum_thread(p_thread_id uuid, p_limit integer default 50, p_after uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_reader();
  t forum.threads;
  c forum.categories;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_after bigint := 0;
begin
  select * into t from forum.threads where id = p_thread_id;
  if not found or not forum.thread_visible(t, m) then
    perform forum.fail('not_found');
  end if;
  if p_after is not null then
    select p.seq into v_after from forum.posts p where p.id = p_after and p.thread_id = t.id;
    if not found then
      perform forum.fail('not_found');
    end if;
  end if;
  select * into c from forum.categories where id = t.category_id;
  return jsonb_build_object(
    'thread', jsonb_build_object(
      'id', t.id,
      'title', forum.thread_title(t, m),
      'category', jsonb_build_object('slug', c.slug, 'title', c.title),
      'author', forum.author_json(t.author_id),
      'pinned', t.pinned,
      'locked', t.locked,
      'deleted', t.deleted_at is not null,
      'hidden', t.hidden_at is not null,
      'hidden_reason', case when t.author_id = m.user_id or m.role = 'moderator'
                            then t.hidden_reason end,
      'can_reply', (not t.locked and t.hidden_at is null) or m.role = 'moderator'),
    'total', (select count(*) from forum.posts p
              where p.thread_id = t.id and forum.post_visible(p, t, m)),
    'posts', coalesce((
      select jsonb_agg(forum.post_json(p, m) order by p.seq)
      from (select * from forum.posts p2
            where p2.thread_id = t.id and p2.seq > v_after and forum.post_visible(p2, t, m)
            order by p2.seq
            limit v_limit) p), '[]'::jsonb));
end;
$$;

create function public.forum_create_thread(p_category text, p_title text, p_body text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member();
  c forum.categories;
  v_title text := forum.clean_title(p_title);
  v_body text := forum.clean_body(p_body);
  v_thread uuid;
begin
  select * into c from forum.categories where slug = p_category;
  if not found then
    perform forum.fail('not_found');
  end if;
  if c.team_only and m.role <> 'moderator' then
    perform forum.fail('team_only');
  end if;
  perform forum.require_writable(m);
  perform forum.throttle(m, 'thread');
  insert into forum.threads (category_id, author_id, title)
  values (c.id, m.user_id, v_title)
  returning id into v_thread;
  insert into forum.posts (thread_id, author_id, is_opening, body)
  values (v_thread, m.user_id, true, v_body);
  return v_thread;
end;
$$;

create function public.forum_reply(p_thread_id uuid, p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member();
  t forum.threads;
  v_body text := forum.clean_body(p_body);
  v_post uuid;
begin
  select * into t from forum.threads where id = p_thread_id for update;
  if not found or not forum.thread_visible(t, m) then
    perform forum.fail('not_found');
  end if;
  perform forum.require_writable(m);
  if m.role <> 'moderator' and (t.locked or t.hidden_at is not null) then
    perform forum.fail('locked');
  end if;
  perform forum.throttle(m, 'post');
  insert into forum.posts (thread_id, author_id, body)
  values (t.id, m.user_id, v_body)
  returning id into v_post;
  update forum.threads set last_post_at = now() where id = t.id;
  return v_post;
end;
$$;

create function public.forum_edit_post(p_post_id uuid, p_body text, p_title text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member();
  p forum.posts;
  t forum.threads;
  v_body text := forum.clean_body(p_body);
begin
  select * into p from forum.posts where id = p_post_id for update;
  if not found or p.author_id is distinct from m.user_id then
    perform forum.fail('not_found');
  end if;
  if p.deleted_at is not null then
    perform forum.fail('not_found');
  end if;
  if p.hidden_at is not null then
    perform forum.fail('hidden');
  end if;
  perform forum.require_writable(m);
  select * into t from forum.threads where id = p.thread_id for update;
  if m.role <> 'moderator' and (t.locked or t.hidden_at is not null) then
    perform forum.fail('locked');
  end if;
  if p_title is not null then
    if not p.is_opening then
      perform forum.fail('invalid_title');
    end if;
    update forum.threads set title = forum.clean_title(p_title) where id = t.id;
  end if;
  update forum.posts set body = v_body, edited_at = now() where id = p.id;
end;
$$;

-- A member deletes their own post: its text is gone for good. Deleting the
-- opening post also wipes the thread's title; the replies of others stay.
create function public.forum_delete_post(p_post_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member();
  p forum.posts;
begin
  select * into p from forum.posts where id = p_post_id for update;
  if not found or p.author_id is distinct from m.user_id or p.deleted_at is not null then
    perform forum.fail('not_found');
  end if;
  update forum.posts set body = '', deleted_at = now() where id = p.id;
  if p.is_opening then
    update forum.threads set title = '', deleted_at = now() where id = p.thread_id;
  end if;
end;
$$;

create function public.forum_report_post(p_post_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member();
  p forum.posts;
  t forum.threads;
  v_reason text := forum.clean_reason(p_reason);
begin
  select * into p from forum.posts where id = p_post_id;
  if not found then
    perform forum.fail('not_found');
  end if;
  select * into t from forum.threads where id = p.thread_id;
  if not forum.thread_visible(t, m) or not forum.post_visible(p, t, m) or p.deleted_at is not null then
    perform forum.fail('not_found');
  end if;
  if p.author_id = m.user_id then
    perform forum.fail('own_post');
  end if;
  perform forum.throttle(m, 'report');
  begin
    insert into forum.reports (post_id, reporter_id, reason) values (p.id, m.user_id, v_reason);
  exception when unique_violation then
    perform forum.fail('already_reported');
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Moderator functions
-- ---------------------------------------------------------------------------

-- A post a moderator is about to act on, locked in the same order as
-- erase_member locks: first its author's member row, then the post. So a
-- moderator's action never interleaves with the erasure of the post's
-- author; if the author was erased meanwhile, the post is gone.
create function forum.lock_post_for_moderation(p_post_id uuid) returns forum.posts
language plpgsql volatile set search_path = '' as $$
declare
  p forum.posts;
  v_author uuid;
begin
  select author_id into v_author from forum.posts where id = p_post_id;
  if not found then
    perform forum.fail('not_found');
  end if;
  if v_author is not null then
    perform 1 from forum.members where user_id = v_author for key share;
  end if;
  select * into p from forum.posts where id = p_post_id for update;
  if not found or p.author_id is distinct from v_author then
    perform forum.fail('not_found');
  end if;
  return p;
end;
$$;

-- Hiding keeps the text for its author and the moderators and shows the
-- author the reason (DSA Art. 17); every other member no longer sees the post
-- at all. Hiding the opening post hides the thread.
create function public.forum_mod_hide_post(p_post_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  p forum.posts;
  v_reason text := forum.clean_reason(p_reason);
begin
  p := forum.lock_post_for_moderation(p_post_id);
  if p.deleted_at is not null then
    perform forum.fail('not_found');
  end if;
  update forum.posts
     set hidden_at = now(), hidden_reason = v_reason, hidden_by = m.user_id
   where id = p.id;
  if p.is_opening then
    update forum.threads
       set hidden_at = now(), hidden_reason = v_reason, hidden_by = m.user_id
     where id = p.thread_id;
  end if;
  perform forum.log(m.user_id, 'hide_post', p.id::text, v_reason);
end;
$$;

create function public.forum_mod_unhide_post(p_post_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  p forum.posts;
begin
  p := forum.lock_post_for_moderation(p_post_id);
  update forum.posts set hidden_at = null, hidden_reason = null, hidden_by = null where id = p.id;
  if p.is_opening then
    update forum.threads set hidden_at = null, hidden_reason = null, hidden_by = null
     where id = p.thread_id;
  end if;
  perform forum.log(m.user_id, 'unhide_post', p.id::text, null);
end;
$$;

create function public.forum_mod_set_thread(p_thread_id uuid, p_pinned boolean default null, p_locked boolean default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
begin
  update forum.threads
     set pinned = coalesce(p_pinned, pinned),
         locked = coalesce(p_locked, locked)
   where id = p_thread_id;
  if not found then
    perform forum.fail('not_found');
  end if;
  perform forum.log(m.user_id, 'set_thread', p_thread_id::text,
                    'pinned=' || coalesce(p_pinned::text, '-') || ' locked=' || coalesce(p_locked::text, '-'));
end;
$$;

create function public.forum_mod_reports(p_include_resolved boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_reader(true);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id,
             'post_id', r.post_id,
             'thread_id', p.thread_id,
             'thread_title', nullif(t.title, ''),
             'excerpt', left(p.body, 280),
             'post_author', forum.author_json(p.author_id),
             'post_hidden', p.hidden_at is not null,
             'post_deleted', p.deleted_at is not null,
             'reporter', forum.author_json(r.reporter_id),
             'reason', r.reason,
             'created_at', r.created_at,
             'resolved_at', r.resolved_at,
             'resolution', r.resolution)
           order by r.created_at desc)
    from forum.reports r
    join forum.posts p on p.id = r.post_id
    join forum.threads t on t.id = p.thread_id
    where p_include_resolved or r.resolved_at is null), '[]'::jsonb);
end;
$$;

create function public.forum_mod_resolve_report(p_report_id uuid, p_resolution text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  v_resolution text := forum.clean_reason(p_resolution);
begin
  update forum.reports
     set resolved_at = now(), resolved_by = m.user_id, resolution = v_resolution
   where id = p_report_id and resolved_at is null;
  if not found then
    perform forum.fail('not_found');
  end if;
  perform forum.log(m.user_id, 'resolve_report', p_report_id::text, v_resolution);
end;
$$;

create function public.forum_mod_invite(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  v_email text := forum.clean_email(p_email);
begin
  insert into forum.invitations (email, invited_by)
  values (v_email, m.user_id)
  on conflict (email) do update
    set revoked_at = null, invited_by = excluded.invited_by, invited_at = now();
  perform forum.log(m.user_id, 'invite', v_email, null);
end;
$$;

-- Revoking stops an address from joining or signing up. A member who has
-- already joined keeps access until a moderator suspends them.
create function public.forum_mod_revoke_invite(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  v_email text := forum.clean_email(p_email);
begin
  update forum.invitations set revoked_at = now()
   where email = v_email and revoked_at is null;
  if not found then
    perform forum.fail('not_found');
  end if;
  perform forum.log(m.user_id, 'revoke_invite', v_email, null);
end;
$$;

create function public.forum_mod_invitations() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_reader(true);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'email', i.email,
             'invited_at', i.invited_at,
             'revoked', i.revoked_at is not null,
             'member', mem.display_name)
           order by i.invited_at desc, i.email)
    from forum.invitations i
    left join auth.users u on lower(u.email) = i.email
    left join forum.members mem on mem.user_id = u.id), '[]'::jsonb);
end;
$$;

create function public.forum_mod_members() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_reader(true);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'user_id', mem.user_id,
             'display_name', mem.display_name,
             'email', u.email,
             'moderator', mem.role = 'moderator',
             'status', mem.status,
             'suspended_reason', mem.suspended_reason,
             'joined_at', mem.joined_at,
             'posts', (select count(*) from forum.posts p where p.author_id = mem.user_id))
           order by mem.joined_at, mem.user_id)
    from forum.members mem
    join auth.users u on u.id = mem.user_id), '[]'::jsonb);
end;
$$;

create function public.forum_mod_suspend(p_user_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  target forum.members;
  v_reason text := forum.clean_reason(p_reason);
begin
  select * into target from forum.members where user_id = p_user_id for update;
  if not found then
    perform forum.fail('not_found');
  end if;
  if target.role = 'moderator' then
    perform forum.fail('cannot_suspend_moderator');
  end if;
  update forum.members set status = 'suspended', suspended_reason = v_reason
   where user_id = target.user_id;
  perform forum.log(m.user_id, 'suspend', target.user_id::text, v_reason);
end;
$$;

create function public.forum_mod_unsuspend(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
begin
  update forum.members set status = 'active', suspended_reason = null
   where user_id = p_user_id and status = 'suspended';
  if not found then
    perform forum.fail('not_found');
  end if;
  perform forum.log(m.user_id, 'unsuspend', p_user_id::text, null);
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges: members call the forum_* functions and nothing else. Supabase
-- grants EXECUTE on new public functions to anon and authenticated by
-- default, so every grant is set explicitly here.
-- ---------------------------------------------------------------------------

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'forum\_%'
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon, authenticated', f.sig);
    if f.proname = 'forum_before_user_created' then
      execute format('grant execute on function %s to supabase_auth_admin', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end;
$$;
