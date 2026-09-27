-- WEB-03: the forum meets DSA Articles 16 and 17 (rebornly-web #14).
--
-- The forum stores what members write on their request, so it is a hosting
-- service. Articles 16 and 17 apply to every hosting service, micro
-- enterprises included; only the online-platform duties of Section 3 are
-- lifted for them (Article 19).
--
-- Article 16, notices: a member reports a post either as breaking the forum
-- rules or as illegal. An illegal-content notice carries an explanation and a
-- statement of good faith; the post is the exact location and the signed-in
-- member is the notifier. The member sees the notice as received at once, and
-- later the decision, in "My reports". Anyone else notifies by email, following
-- the procedure in docs/forum/RUNBOOK.md.
--
-- Article 17, statements of reasons: hiding a post and suspending an account
-- are recorded as a decision with its restriction, its basis (the forum rules
-- or the law) and the rule or legal ground it rests on, the facts, whether it
-- followed a notice or was the moderators' own initiative, and when it was
-- lifted. The member it restricts sees all of it; the page adds that no
-- automated means were used and how to ask for another look.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

alter table forum.reports
  add column kind text not null default 'rules' check (kind in ('rules', 'illegal')),
  add column good_faith boolean not null default false,
  add column resolution_action text check (resolution_action in ('hidden', 'no_action', 'removed')),
  add column decision_seen_at timestamptz,
  add constraint reports_illegal_needs_good_faith check (kind <> 'illegal' or good_faith),
  add constraint reports_action_with_resolution check ((resolved_at is null) = (resolution_action is null));

create table forum.decisions (
  id               uuid primary key default gen_random_uuid(),
  action           text not null check (action in ('hide_post', 'suspend_account')),
  member_id        uuid references forum.members (user_id) on delete set null,
  post_id          uuid references forum.posts (id) on delete cascade,
  basis            text not null check (basis in ('rules', 'illegal')),
  basis_reference  text not null,
  facts            text not null,
  source           text not null check (source in ('member_report', 'email_notice', 'own_initiative')),
  report_id        uuid references forum.reports (id) on delete set null,
  decided_by       uuid,
  decided_at       timestamptz not null default now(),
  lifted_at        timestamptz,
  check ((action = 'hide_post') = (post_id is not null))
);
create index decisions_member_idx on forum.decisions (member_id);

alter table forum.posts
  add column hidden_decision_id uuid references forum.decisions (id) on delete set null;
alter table forum.threads
  add column hidden_decision_id uuid references forum.decisions (id) on delete set null;
alter table forum.members
  add column suspension_decision_id uuid references forum.decisions (id) on delete set null;

revoke all on all tables in schema forum from public;
revoke all on all tables in schema forum from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- An illegal-content notice needs a real explanation (Art. 16(2)(a)).
create function forum.clean_notice(p_text text) returns text
language plpgsql set search_path = '' as $$
declare
  v text := btrim(coalesce(p_text, ''), ' ' || chr(9) || chr(10) || chr(13));
begin
  if length(v) < 10 or length(v) > 2000 or not forum.text_ok(v) then
    perform forum.fail('invalid_notice');
  end if;
  return v;
end;
$$;

-- A member's own records stay theirs while suspended: their notices and the
-- decisions on them, the statements of reasons about their hidden posts, and
-- deleting their own posts (Terms 3a; GDPR). These checks admit an active or
-- a suspended member, and nobody else. The writer takes the same lock as
-- forum.require_member, so an erasure is still never raced.
create function forum.require_self_writer() returns forum.members
language plpgsql volatile set search_path = '' as $$
declare
  m forum.members;
begin
  if auth.uid() is null then
    perform forum.fail('not_signed_in');
  end if;
  select * into m from forum.members where user_id = auth.uid() for key share;
  if m.user_id is null then
    perform forum.fail('not_member');
  end if;
  return m;
end;
$$;

create function forum.require_self_reader() returns forum.members
language plpgsql stable set search_path = '' as $$
declare
  m forum.members;
begin
  if auth.uid() is null then
    perform forum.fail('not_signed_in');
  end if;
  select * into m from forum.members where user_id = auth.uid();
  if m.user_id is null then
    perform forum.fail('not_member');
  end if;
  return m;
end;
$$;

-- The ground a decision rests on: which forum rule, or which law.
create function forum.clean_basis(p_basis text, p_reference text) returns text
language plpgsql set search_path = '' as $$
declare
  v text := btrim(coalesce(p_reference, ''));
begin
  if p_basis is null or p_basis not in ('rules', 'illegal')
     or length(v) < 3 or length(v) > 200 or not forum.text_ok(v) or v ~ '[\r\n]' then
    perform forum.fail('invalid_basis');
  end if;
  return v;
end;
$$;

create function forum.clean_source(p_source text) returns text
language plpgsql set search_path = '' as $$
begin
  if p_source is null or p_source not in ('member_report', 'email_notice', 'own_initiative') then
    perform forum.fail('invalid_source');
  end if;
  return p_source;
end;
$$;

create function forum.own_record_title(t forum.threads, m forum.members) returns text
language sql stable set search_path = '' as $$
  select case
    when t.author_id = m.user_id then nullif(t.title, '')
    when m.status = 'active' and forum.thread_visible(t, m) then forum.thread_title(t, m)
  end
$$;

-- A decision as its member (or a moderator) sees it: the statement of reasons.
create function forum.decision_json(p_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'action', d.action,
    'basis', d.basis,
    'basis_reference', d.basis_reference,
    'facts', d.facts,
    'source', d.source,
    'decided_at', d.decided_at,
    'lifted_at', d.lifted_at,
    'automated', false)
  from forum.decisions d where d.id = p_id
$$;

create or replace function forum.post_json(p forum.posts, m forum.members) returns jsonb
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
                     end,
    -- The statement of reasons, for the member it restricts and the moderators.
    'decision', case
                  when p.hidden_at is not null and (p.author_id = m.user_id or m.role = 'moderator')
                  then forum.decision_json(p.hidden_decision_id)
                end
  )
$$;

create or replace function forum.me_json(p_uid uuid) returns jsonb
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
      'suspension', case when m.status = 'suspended' then forum.decision_json(m.suspension_decision_id) end,
      'reports_decided_unseen', (select count(*) from forum.reports r
                                 where r.reporter_id = m.user_id and r.resolved_at is not null
                                   and r.decision_seen_at is null),
      'read_only', forum.read_only(),
      'rules_version', forum.rules_version());
  end if;
  select u.email into v_email from auth.users u where u.id = p_uid;
  return jsonb_build_object(
    'state', case when v_email is not null and forum.invited(v_email) then 'invited' else 'not_invited' end,
    'rules_version', forum.rules_version());
end;
$$;

revoke all on all functions in schema forum from public;

-- A member deletes their own post, also while suspended: its text is gone for
-- good. Deleting the opening post also wipes the thread's title.
create or replace function public.forum_delete_post(p_post_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_self_writer();
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

-- ---------------------------------------------------------------------------
-- Notices (Art. 16)
-- ---------------------------------------------------------------------------

drop function public.forum_report_post(uuid, text);

create function public.forum_report_post(p_post_id uuid, p_reason text,
                                         p_kind text default 'rules', p_good_faith boolean default false)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member();
  p forum.posts;
  t forum.threads;
  v_reason text;
begin
  if p_kind is null or p_kind not in ('rules', 'illegal') then
    perform forum.fail('invalid_kind');
  end if;
  if p_kind = 'illegal' then
    v_reason := forum.clean_notice(p_reason);
    if p_good_faith is distinct from true then
      perform forum.fail('good_faith_required');
    end if;
  else
    v_reason := forum.clean_reason(p_reason);
  end if;
  -- FOR SHARE waits for a moderator hiding this post at the same moment
  -- (lock_post_for_moderation holds it FOR UPDATE), then sees it hidden.
  select * into p from forum.posts where id = p_post_id for share;
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
    insert into forum.reports (post_id, reporter_id, reason, kind, good_faith)
    values (p.id, m.user_id, v_reason, p_kind, coalesce(p_good_faith, false));
  exception when unique_violation then
    perform forum.fail('already_reported');
  end;
end;
$$;

-- The member's own notices: received, and later decided (Art. 16(4), 16(5)).
-- Where the reported post may no longer be seen, only that is said.
create function public.forum_my_reports() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_self_reader();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id,
             'kind', r.kind,
             'reason', r.reason,
             'created_at', r.created_at,
             'thread_id', case when m.status = 'active' and forum.thread_visible(t, m) then t.id end,
             'thread_title', forum.own_record_title(t, m),
             'decided', r.resolved_at is not null,
             'decided_at', r.resolved_at,
             'action', r.resolution_action,
             'decision', r.resolution,
             'seen', r.decision_seen_at is not null)
           order by r.created_at desc, r.id)
    from forum.reports r
    join forum.posts p on p.id = r.post_id
    join forum.threads t on t.id = p.thread_id
    where r.reporter_id = m.user_id), '[]'::jsonb);
end;
$$;

-- Marks as seen the decisions the member was shown (their ids), and only
-- those: one decided after the page loaded stays new.
create function public.forum_mark_reports_seen(p_ids uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_self_writer();
begin
  update forum.reports set decision_seen_at = now()
   where reporter_id = m.user_id and id = any(coalesce(p_ids, '{}'))
     and resolved_at is not null and decision_seen_at is null;
end;
$$;

-- My posts: every post of the member's that is not deleted, hidden or not,
-- each hidden one with its statement of reasons. It is how a suspended member
-- deletes their own posts, and how anyone keeps sight of their replies in a
-- thread they can no longer open. Newest first, at most 500.
create function public.forum_my_posts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m forum.members := forum.require_self_reader();
begin
  return coalesce((
    select jsonb_agg(row_json order by seq desc)
    from (
      select p.seq,
             jsonb_build_object(
               'id', p.id,
               'opening', p.is_opening,
               'thread_id', case when m.status = 'active' and forum.thread_visible(t, m) then t.id end,
               'thread_title', forum.own_record_title(t, m),
               'body', p.body,
               'created_at', p.created_at,
               'hidden', p.hidden_at is not null,
               'decision', case when p.hidden_at is not null then forum.decision_json(p.hidden_decision_id) end) as row_json
      from forum.posts p
      join forum.threads t on t.id = p.thread_id
      where p.author_id = m.user_id and p.deleted_at is null
      order by p.seq desc
      limit 500
    ) mine), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Decisions (Art. 17)
-- ---------------------------------------------------------------------------

drop function public.forum_mod_hide_post(uuid, text);

-- Hiding keeps the text for its author and the moderators and gives the
-- author a statement of reasons; every other member no longer sees the post.
-- Hiding the opening post hides the thread. Every open notice about the post
-- is decided with it, and each notifier is told.
create function public.forum_mod_hide_post(p_post_id uuid, p_reason text, p_basis text,
                                           p_basis_reference text,
                                           p_source text default 'own_initiative',
                                           p_report_id uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  p forum.posts;
  v_reason text := forum.clean_reason(p_reason);
  v_reference text := forum.clean_basis(p_basis, p_basis_reference);
  v_source text := forum.clean_source(p_source);
  v_decision uuid;
  r record;
begin
  p := forum.lock_post_for_moderation(p_post_id);
  if p.deleted_at is not null then
    perform forum.fail('not_found');
  end if;
  if p.hidden_at is not null then
    perform forum.fail('already_hidden');
  end if;
  if (v_source = 'member_report') is distinct from (p_report_id is not null) then
    perform forum.fail('invalid_source');
  end if;
  if p_report_id is not null then
    perform 1 from forum.reports
     where id = p_report_id and post_id = p.id and resolved_at is null for update;
    if not found then
      perform forum.fail('not_found');
    end if;
  elsif v_source = 'own_initiative' then
    -- Members had already reported this post: the decision follows their
    -- notices, whatever the moderator came from, and says so (Art. 17(3)(b)).
    select open_notice.id into p_report_id from forum.reports open_notice
     where open_notice.post_id = p.id and open_notice.resolved_at is null
     order by open_notice.created_at, open_notice.id limit 1 for update;
    if found then
      v_source := 'member_report';
    end if;
  end if;
  insert into forum.decisions (action, member_id, post_id, basis, basis_reference, facts,
                               source, report_id, decided_by)
  values ('hide_post', p.author_id, p.id, p_basis, v_reference, v_reason,
          v_source, p_report_id, m.user_id)
  returning id into v_decision;
  update forum.posts
     set hidden_at = now(), hidden_reason = v_reason, hidden_by = m.user_id,
         hidden_decision_id = v_decision
   where id = p.id;
  if p.is_opening then
    update forum.threads
       set hidden_at = now(), hidden_reason = v_reason, hidden_by = m.user_id,
           hidden_decision_id = v_decision
     where id = p.thread_id;
  end if;
  perform forum.log(m.user_id, 'hide_post', p.id::text, v_reason);
  for r in
    update forum.reports
       set resolved_at = now(), resolved_by = m.user_id, resolution_action = 'hidden',
           resolution = 'The post was hidden. Ground: ' || v_reference || '.'
     where post_id = p.id and resolved_at is null
    returning id, resolution
  loop
    perform forum.log(m.user_id, 'resolve_report', r.id::text, r.resolution);
  end loop;
end;
$$;

create or replace function public.forum_mod_unhide_post(p_post_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  p forum.posts;
begin
  p := forum.lock_post_for_moderation(p_post_id);
  update forum.decisions set lifted_at = now()
   where id = p.hidden_decision_id and lifted_at is null;
  update forum.reports
     set resolution = resolution || ' A moderator later restored the post.', decision_seen_at = null
   where post_id = p.id and resolution_action = 'hidden'
     and resolution not like '%later restored the post.';
  update forum.posts
     set hidden_at = null, hidden_reason = null, hidden_by = null, hidden_decision_id = null
   where id = p.id;
  if p.is_opening then
    update forum.threads
       set hidden_at = null, hidden_reason = null, hidden_by = null, hidden_decision_id = null
     where id = p.thread_id;
  end if;
  perform forum.log(m.user_id, 'unhide_post', p.id::text, null);
end;
$$;

create or replace function public.forum_mod_reports(p_include_resolved boolean default false) returns jsonb
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
             'kind', r.kind,
             'good_faith', r.good_faith,
             'reason', r.reason,
             'created_at', r.created_at,
             'resolved_at', r.resolved_at,
             'resolution_action', r.resolution_action,
             'resolution', r.resolution)
           order by r.created_at desc)
    from forum.reports r
    join forum.posts p on p.id = r.post_id
    join forum.threads t on t.id = p.thread_id
    where p_include_resolved or r.resolved_at is null), '[]'::jsonb);
end;
$$;

-- Deciding to take no action on a notice. The explanation is what the
-- notifier reads (Art. 16(5)).
create or replace function public.forum_mod_resolve_report(p_report_id uuid, p_resolution text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  v_resolution text := forum.clean_reason(p_resolution);
begin
  update forum.reports
     set resolved_at = now(), resolved_by = m.user_id, resolution = v_resolution,
         resolution_action = 'no_action'
   where id = p_report_id and resolved_at is null;
  if not found then
    perform forum.fail('not_found');
  end if;
  perform forum.log(m.user_id, 'resolve_report', p_report_id::text, v_resolution);
end;
$$;

drop function public.forum_mod_suspend(uuid, text);

create function public.forum_mod_suspend(p_user_id uuid, p_reason text, p_basis text,
                                         p_basis_reference text,
                                         p_source text default 'own_initiative')
returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  target forum.members;
  v_reason text := forum.clean_reason(p_reason);
  v_reference text := forum.clean_basis(p_basis, p_basis_reference);
  v_source text := forum.clean_source(p_source);
  v_decision uuid;
begin
  select * into target from forum.members where user_id = p_user_id for update;
  if not found then
    perform forum.fail('not_found');
  end if;
  if target.role = 'moderator' then
    perform forum.fail('cannot_suspend_moderator');
  end if;
  if target.status = 'suspended' then
    perform forum.fail('already_suspended');
  end if;
  insert into forum.decisions (action, member_id, basis, basis_reference, facts, source, decided_by)
  values ('suspend_account', target.user_id, p_basis, v_reference, v_reason, v_source, m.user_id)
  returning id into v_decision;
  update forum.members
     set status = 'suspended', suspended_reason = v_reason, suspension_decision_id = v_decision
   where user_id = target.user_id;
  perform forum.log(m.user_id, 'suspend', target.user_id::text, v_reason);
end;
$$;

create or replace function public.forum_mod_unsuspend(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m forum.members := forum.require_member(true);
  v_decision uuid;
begin
  select suspension_decision_id into v_decision from forum.members
   where user_id = p_user_id and status = 'suspended' for update;
  if not found then
    perform forum.fail('not_found');
  end if;
  update forum.members
     set status = 'active', suspended_reason = null, suspension_decision_id = null
   where user_id = p_user_id;
  update forum.decisions set lifted_at = now() where id = v_decision and lifted_at is null;
  perform forum.log(m.user_id, 'unsuspend', p_user_id::text, null);
end;
$$;

-- ---------------------------------------------------------------------------
-- Access and erasure (GDPR) cover the new records
-- ---------------------------------------------------------------------------

create or replace function forum.export_member(p_email text) returns jsonb
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
    'reports_made', coalesce((select jsonb_agg(jsonb_build_object('post_id', r.post_id, 'kind', r.kind,
                                      'good_faith', r.good_faith, 'reason', r.reason,
                                      'created_at', r.created_at, 'decided_at', r.resolved_at,
                                      'action', r.resolution_action, 'decision', r.resolution)
                                      order by r.created_at)
                              from forum.reports r where r.reporter_id = v_uid), '[]'::jsonb),
    -- Reports others made about this person's posts, without saying who made them.
    'reports_about_posts', coalesce((select jsonb_agg(jsonb_build_object('post_id', r.post_id, 'kind', r.kind,
                                             'reason', r.reason, 'created_at', r.created_at,
                                             'action', r.resolution_action, 'decision', r.resolution)
                                             order by r.created_at)
                                     from forum.reports r join forum.posts p on p.id = r.post_id
                                     where p.author_id = v_uid), '[]'::jsonb),
    -- The statements of reasons about this person in full; decisions this
    -- person took as a moderator about others only as that they happened.
    'decisions', coalesce((select jsonb_agg(case
                                     when d.member_id = v_uid then forum.decision_json(d.id)
                                     else jsonb_build_object('action', d.action, 'decided_at', d.decided_at,
                                                             'by_this_person', true)
                                   end order by d.decided_at, d.id)
                           from forum.decisions d
                           where v_uid is not null and (d.member_id = v_uid or d.decided_by = v_uid)), '[]'::jsonb),
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

-- As in WEB-02, plus the decisions: a statement of reasons about the member
-- loses its words and its link to them; one they made as a moderator loses
-- their id.
create or replace function forum.erase_member(p_email text) returns jsonb
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
  delete from forum.reports where reporter_id = v_uid;
  update forum.decisions
     set facts = 'Erased on request', basis_reference = 'Erased on request', member_id = null
   where member_id = v_uid;
  update forum.decisions set decided_by = null where decided_by = v_uid;
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
  -- Other members' notices about this member's posts are theirs, and the law
  -- owes them a decision (DSA Art. 16(5)): the open ones are decided now. This
  -- runs after the wipe above, which waited for any notice being filed.
  update forum.reports
     set resolved_at = now(), resolution_action = 'removed', decision_seen_at = null,
         resolution = 'The post was removed when its author''s account was deleted.'
   where resolved_at is null
     and post_id in (select id from forum.posts where author_id = v_uid);
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
-- Privileges, as in WEB-02, for the functions this migration created.
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
