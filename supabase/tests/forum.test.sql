-- WEB-02: pgTAP suite for the closed beta forum.
-- Run by scripts/test-forum.sh against a throwaway supabase/postgres container
-- that has the migration applied. Every call a member makes goes through
-- tests.as_user, which switches to the real `authenticated` (or `anon`) role,
-- so the privileges are tested exactly as a browser meets them.

\set ON_ERROR_STOP 1
\set QUIET 1
\pset format unaligned
\pset tuples_only on

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

\set alice '00000000-0000-4000-8000-00000000000a'
\set bob   '00000000-0000-4000-8000-00000000000b'
\set carol '00000000-0000-4000-8000-00000000000c'
\set mod   '00000000-0000-4000-8000-00000000000d'
\set dan   '00000000-0000-4000-8000-00000000000e'
\set mod2  '00000000-0000-4000-8000-00000000000f'

create schema tests;

-- Run p_sql as the given user (null = anon) and return 'ok:<first value>' or
-- 'error:<message>'.
create function tests.as_user(p_uid uuid, p_sql text) returns text
language plpgsql as $$
declare
  v text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  if p_uid is null then
    execute 'set local role anon';
  else
    execute 'set local role authenticated';
  end if;
  begin
    execute p_sql into v;
    v := 'ok:' || coalesce(v, '');
  exception when others then
    v := 'error:' || sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  return v;
end;
$$;

-- The `authenticated` role with no user id in the token.
create function tests.as_nobody(p_sql text) returns text
language plpgsql as $$
declare
  v text;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role authenticated';
  begin
    execute p_sql into v;
    v := 'ok:' || coalesce(v, '');
  exception when others then
    v := 'error:' || sqlerrm;
  end;
  execute 'reset role';
  return v;
end;
$$;

-- One harmless call of every member and moderator function. Each refusal
-- test below runs all of them, and a pin checks the list is complete, so a
-- new function cannot arrive without its refusals being tested.
create table tests.calls (name text primary key, moderator boolean not null, call text not null,
                          self_service boolean not null default false);
insert into tests.calls (name, moderator, call) values
  ('forum_categories',         false, $$select public.forum_categories()::text$$),
  ('forum_threads',            false, $$select public.forum_threads('general')::text$$),
  ('forum_thread',             false, $$select public.forum_thread('00000000-0000-4000-8000-000000000000')::text$$),
  ('forum_create_thread',      false, $$select public.forum_create_thread('general', 'A title', 'A body')::text$$),
  ('forum_reply',              false, $$select public.forum_reply('00000000-0000-4000-8000-000000000000', 'A body')::text$$),
  ('forum_edit_post',          false, $$select public.forum_edit_post('00000000-0000-4000-8000-000000000000', 'A body')::text$$),
  ('forum_delete_post',        false, $$select public.forum_delete_post('00000000-0000-4000-8000-000000000000')::text$$),
  ('forum_report_post',        false, $$select public.forum_report_post('00000000-0000-4000-8000-000000000000', 'A reason')::text$$),
  ('forum_my_reports',         false, $$select public.forum_my_reports()::text$$),
  ('forum_mark_reports_seen',  false, $$select public.forum_mark_reports_seen(array[]::uuid[])::text$$),
  ('forum_my_hidden_posts',    false, $$select public.forum_my_hidden_posts()::text$$),
  ('forum_mod_hide_post',      true,  $$select public.forum_mod_hide_post('00000000-0000-4000-8000-000000000000', 'A reason', 'rules', 'Forum rule 1')::text$$),
  ('forum_mod_unhide_post',    true,  $$select public.forum_mod_unhide_post('00000000-0000-4000-8000-000000000000')::text$$),
  ('forum_mod_set_thread',     true,  $$select public.forum_mod_set_thread('00000000-0000-4000-8000-000000000000', true, true)::text$$),
  ('forum_mod_reports',        true,  $$select public.forum_mod_reports()::text$$),
  ('forum_mod_resolve_report', true,  $$select public.forum_mod_resolve_report('00000000-0000-4000-8000-000000000000', 'A note')::text$$),
  ('forum_mod_invite',         true,  $$select public.forum_mod_invite('someone@example.com')::text$$),
  ('forum_mod_revoke_invite',  true,  $$select public.forum_mod_revoke_invite('someone@example.com')::text$$),
  ('forum_mod_invitations',    true,  $$select public.forum_mod_invitations()::text$$),
  ('forum_mod_members',        true,  $$select public.forum_mod_members()::text$$),
  ('forum_mod_suspend',        true,  $$select public.forum_mod_suspend('00000000-0000-4000-8000-000000000000', 'A reason', 'rules', 'Forum rule 1')::text$$),
  ('forum_mod_unsuspend',      true,  $$select public.forum_mod_unsuspend('00000000-0000-4000-8000-000000000000')::text$$);

-- A member's own records stay theirs while suspended (Terms 3a).
update tests.calls set self_service = true
 where name in ('forum_my_reports', 'forum_mark_reports_seen', 'forum_my_hidden_posts', 'forum_delete_post');

-- Which calls did NOT answer as expected; null when every one did.
create function tests.offenders(p_uid uuid, p_expected text, p_moderator_only boolean,
                                p_skip_self_service boolean default false) returns text
language sql as $$
  select string_agg(c.name || ' -> ' || r.result, '; ' order by c.name)
  from tests.calls c
  cross join lateral (select tests.as_user(p_uid, c.call) as result) r
  where (not p_moderator_only or c.moderator)
    and (not p_skip_self_service or not c.self_service)
    and r.result not like p_expected
$$;

create function tests.val(p text) returns jsonb
language sql as $$
  select case when p like 'ok:%' then substr(p, 4)::jsonb
              else jsonb_build_object('error', p) end
$$;

insert into auth.users (id, email) values
  (:'alice', 'alice@example.com'),
  (:'bob',   'bob@example.com'),
  (:'carol', 'carol@example.com'),
  (:'mod',   'owner@example.com'),
  (:'dan',   'dan@example.com'),
  (:'mod2',  'helper@example.com');

-- Bootstrap exactly as the runbook does it: the owner's invitation and role
-- are written by direct database access.
insert into forum.invitations (email) values
  ('alice@example.com'), ('bob@example.com'), ('owner@example.com'),
  ('dan@example.com'), ('helper@example.com');

select plan(222);

-- ---------------------------------------------------------------------------
-- 1. Privileges: nothing is reachable except the checked functions
-- ---------------------------------------------------------------------------

select is((select count(*) from information_schema.role_table_grants
           where table_schema = 'forum' and grantee in ('anon', 'authenticated', 'PUBLIC')),
          0::bigint, 'no table in schema forum carries a grant to anon, authenticated or PUBLIC');

select ok(not has_schema_privilege('anon', 'forum', 'usage')
          and not has_schema_privilege('authenticated', 'forum', 'usage'),
          'anon and authenticated cannot use schema forum');

select alike(tests.as_user(:'alice', 'select count(*)::text from forum.posts'),
            'error:permission denied%', 'a signed-in user cannot read a forum table directly');

select alike(tests.as_user(null, 'select count(*)::text from forum.members'),
            'error:permission denied%', 'anon cannot read a forum table directly');

select alike(tests.as_user(:'alice', $$insert into forum.invitations (email) values ('x@y.zz') returning email$$),
            'error:permission denied%', 'a signed-in user cannot invite by writing the table');

select alike(tests.as_user(null, 'select public.forum_me()::text'),
            'error:permission denied%', 'anon cannot call a forum function');

select alike(tests.as_user(:'alice', $$select public.forum_before_user_created('{}'::jsonb)::text$$),
            'error:permission denied%', 'a signed-in user cannot call the Auth hook');

select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'forum\_%'
             and p.proname <> 'forum_before_user_created'
             and (not has_function_privilege('authenticated', p.oid, 'execute')
                  or has_function_privilege('anon', p.oid, 'execute'))),
          0::bigint, 'every member function is executable by authenticated and by no anon');

select ok(has_function_privilege('supabase_auth_admin', 'public.forum_before_user_created(jsonb)', 'execute')
          and not has_function_privilege('anon', 'public.forum_before_user_created(jsonb)', 'execute'),
          'only supabase_auth_admin runs the Auth hook');

select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'forum\_%'
             and not (p.prosecdef and p.proconfig @> array['search_path=""'])),
          0::bigint, 'every public forum function is SECURITY DEFINER with an empty search_path');

select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('public', 'forum')
             and p.prosrc ~* 'update\s+forum\.members\s+set[^;]*\mrole\M'),
          0::bigint, 'no function writes the moderator role (it is granted only by direct access)');

-- ---------------------------------------------------------------------------
-- 2. The Auth hook: only invited addresses become users
-- ---------------------------------------------------------------------------

select is(public.forum_before_user_created('{"user":{"email":"alice@example.com"}}'),
          '{}'::jsonb, 'an invited address may be created');
select is(public.forum_before_user_created('{"user":{"email":"  Alice@Example.COM "}}'),
          '{}'::jsonb, 'the invitation matches regardless of case and spaces');
select is(public.forum_before_user_created('{"user":{"email":"stranger@example.com"}}') -> 'error' ->> 'http_code',
          '403', 'an address without an invitation is refused');
select is(public.forum_before_user_created('{"user":{"phone":"+46700000000"}}') -> 'error' ->> 'http_code',
          '403', 'a user without an email address is refused');

-- ---------------------------------------------------------------------------
-- 3. Joining
-- ---------------------------------------------------------------------------

select is(tests.val(tests.as_user(:'carol', 'select public.forum_me()::text')) ->> 'state',
          'not_invited', 'a signed-in user without an invitation is not_invited');
select is(tests.as_user(:'carol', $$select public.forum_join('Carol', true, '1.0')::text$$),
          'error:forum:not_invited', 'an uninvited user cannot join');
select is(tests.as_user(:'carol', 'select public.forum_categories()::text'),
          'error:forum:not_member', 'a non-member cannot read the forum');
select set_eq($$select name from tests.calls$$,
              $$select p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname like 'forum\_%'
                  and p.proname not in ('forum_before_user_created', 'forum_me', 'forum_join')$$,
              'every member and moderator function is in the refusal list');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'forum\_%'),
          (select count(distinct p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'forum\_%'),
          'no forum function is overloaded, so the refusal list covers every signature');
-- The Data API runs STABLE functions in a read-only transaction: they must
-- not lock. Every function that writes must take the member lock that keeps
-- an erasure safe. (supabase/tests/read_only_calls.sh calls each read in a
-- real read-only transaction.)
select is((select string_agg(p.proname, ', ' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'forum\_%' and p.provolatile in ('s', 'i')
             and (p.prosrc ~* 'require_member\(|for (update|no key update|share|key share)')),
          null, 'no read-only forum function locks a row or calls the locking member check');
select is((select string_agg(p.proname, ', ' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'forum\_%' and p.provolatile = 'v'
             and p.proname not in ('forum_before_user_created', 'forum_join')
             and p.prosrc !~ 'forum\.require_(member|self_writer)\('),
          null, 'every forum function that writes takes the member lock');
select is(tests.offenders(:'carol', 'error:forum:not_member', false), null,
          'a signed-in non-member is refused by every member and moderator function');
select is(tests.offenders(null, 'error:permission denied%', false), null,
          'anon is refused by every member and moderator function');
select is((select string_agg(c.name || ' -> ' || r, '; ')
           from (select name, call from tests.calls
                 union all select 'forum_me', 'select public.forum_me()::text'
                 union all select 'forum_join', $j$select public.forum_join('Nobody', true, '1.0')::text$j$) c
           cross join lateral tests.as_nobody(c.call) r
           where r <> 'error:forum:not_signed_in'), null,
          'a token without a user is refused by every function as not_signed_in');
select is(tests.val(tests.as_user(:'alice', 'select public.forum_me()::text')) ->> 'state',
          'invited', 'an invited user is invited before joining');
select is(tests.as_user(:'alice', $$select public.forum_join('Alice', false, '1.0')::text$$),
          'error:forum:adult_required', 'joining needs the 18+ confirmation');
select is(tests.as_user(:'alice', $$select public.forum_join('Alice', true, '0.9')::text$$),
          'error:forum:rules_outdated', 'joining needs the current rules version');
select is(tests.as_user(:'alice', $$select public.forum_join('A', true, '1.0')::text$$),
          'error:forum:invalid_name', 'a one-letter name is refused');
select is(tests.as_user(:'alice', $$select public.forum_join('Rebornly Fan', true, '1.0')::text$$),
          'error:forum:invalid_name', 'a name that looks like the team is refused');
select is(tests.as_user(:'alice', $$select public.forum_join('<b>Alice</b>', true, '1.0')::text$$),
          'error:forum:invalid_name', 'a name with markup characters is refused');
select is(tests.val(tests.as_user(:'alice', $$select public.forum_join('  Alice  ', true, '1.0')::text$$)) ->> 'state',
          'member', 'an invited adult joins');
select is((select display_name from forum.members where user_id = :'alice'),
          'Alice', 'the display name is stored trimmed');
select is(tests.as_user(:'alice', $$select public.forum_join('Alice2', true, '1.0')::text$$),
          'error:forum:already_member', 'joining twice is refused');
select is(tests.as_user(:'bob', $$select public.forum_join('ALICE', true, '1.0')::text$$),
          'error:forum:name_taken', 'display names are unique regardless of case');
select is(tests.val(tests.as_user(:'bob', $$select public.forum_join('Bob', true, '1.0')::text$$)) ->> 'state',
          'member', 'a second member joins');
select is(tests.val(tests.as_user(:'mod', $$select public.forum_join('Therese', true, '1.0')::text$$)) ->> 'state',
          'member', 'the owner joins like everyone else');
select is(tests.val(tests.as_user(:'dan', $$select public.forum_join('Dan', true, '1.0')::text$$)) ->> 'state',
          'member', 'a third member joins (Dan never replies in Alice''s first thread)');
update forum.members set role = 'moderator' where user_id = :'mod';
select is(tests.val(tests.as_user(:'mod', 'select public.forum_me()::text')) ->> 'moderator',
          'true', 'the moderator role, set by direct access, shows in forum_me');
select is(tests.offenders(:'alice', 'error:forum:not_moderator', true), null,
          'a member is refused by every moderator function');

-- ---------------------------------------------------------------------------
-- 4. Threads and replies
-- ---------------------------------------------------------------------------

select is(jsonb_array_length(tests.val(tests.as_user(:'alice', 'select public.forum_categories()::text'))),
          4, 'a member sees the four categories');
select is(tests.as_user(:'alice', $$select public.forum_create_thread('announcements', 'Hello all', 'Hi')::text$$),
          'error:forum:team_only', 'a member cannot start a thread in Announcements');
select is(tests.as_user(:'alice', $$select public.forum_create_thread('nowhere', 'Hello all', 'Hi')::text$$),
          'error:forum:not_found', 'an unknown category is refused');
select is(tests.as_user(:'alice', $$select public.forum_create_thread('general', 'Hi', 'Hi')::text$$),
          'error:forum:invalid_title', 'a two-letter title is refused');
select is(tests.as_user(:'alice', format('select public.forum_create_thread(%L, %L, %L)::text',
                                         'general', 'Two' || chr(10) || 'lines', 'Hi')),
          'error:forum:invalid_title', 'a title with a line break is refused');
select is(tests.as_user(:'alice', format('select public.forum_create_thread(%L, %L, %L)::text',
                                         'general', 'Hello all', 'Bell' || chr(7))),
          'error:forum:invalid_body', 'a body with a control character is refused');
select is(tests.as_user(:'alice', $$select public.forum_create_thread('general', 'Hello all', '   ')::text$$),
          'error:forum:invalid_body', 'an empty body is refused');

select substr(tests.as_user(:'alice', $$select public.forum_create_thread('general', 'Hello all', 'First post')::text$$), 4) as t1 \gset
select ok(:'t1' ~ '^[0-9a-f-]{36}$', 'a member starts a thread');
select id as p1 from forum.posts where thread_id = :'t1' and is_opening \gset
select is(tests.as_user(:'mod', $$select public.forum_create_thread('announcements', 'Welcome', 'Hello from the team')::text$$) like 'ok:%',
          true, 'a moderator starts a thread in Announcements');

select substr(tests.as_user(:'bob', format('select public.forum_reply(%L, %L)::text', :'t1', 'A reply')), 4) as p2 \gset
select ok(:'p2' ~ '^[0-9a-f-]{36}$', 'a member replies');

select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,replies}',
          '1', 'the thread list counts the reply');
select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,author,name}',
          'Alice', 'the thread list names the author by display name');
select ok(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$) !~ 'example\.com',
          'no email address reaches a member');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{posts,0,mine}',
          'true', 'the author sees her post marked as hers');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{posts,1,mine}',
          'false', 'another member''s reply is not marked as hers');
select is(tests.val(tests.as_user(:'mod', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{posts,0,author,team}',
          'false', 'a member is not marked as team');

-- ---------------------------------------------------------------------------
-- 5. Editing, reporting
-- ---------------------------------------------------------------------------

select is(tests.as_user(:'bob', format('select public.forum_edit_post(%L, %L)::text', :'p1', 'Taken over')),
          'error:forum:not_found', 'a member cannot edit someone else''s post');
select is(tests.as_user(:'bob', format('select public.forum_edit_post(%L, %L, %L)::text', :'p2', 'Edit', 'New title')),
          'error:forum:invalid_title', 'a reply cannot change the thread title');
select is(tests.as_user(:'alice', format('select public.forum_edit_post(%L, %L, %L)::text', :'p1', 'First post, edited', 'Hello everyone')),
          'ok:', 'the author edits her opening post and title');
select ok((select title = 'Hello everyone' from forum.threads where id = :'t1')
          and (select edited_at is not null from forum.posts where id = :'p1'),
          'the edit is stored and marked as edited');

select is(tests.as_user(:'bob', format('select public.forum_report_post(%L, %L)::text', :'p1', 'This looks like spam')),
          'ok:', 'a member reports a post');
select is(tests.as_user(:'bob', format('select public.forum_report_post(%L, %L)::text', :'p1', 'Again please')),
          'error:forum:already_reported', 'the same member cannot report the same post twice while open');
select is(tests.as_user(:'bob', format('select public.forum_report_post(%L, %L)::text', :'p2', 'My own')),
          'error:forum:own_post', 'a member cannot report her own post');
select is(tests.as_user(:'alice', format('select public.forum_report_post(%L, %L)::text', :'p2', 'no')),
          'error:forum:invalid_reason', 'a report needs a reason');

-- ---------------------------------------------------------------------------
-- 6. Moderation
-- ---------------------------------------------------------------------------

select is(tests.as_user(:'alice', 'select public.forum_mod_reports()::text'),
          'error:forum:not_moderator', 'a member cannot read the reports');
select is(tests.as_user(:'alice', $$select public.forum_mod_invite('friend@example.com')::text$$),
          'error:forum:not_moderator', 'a member cannot invite');
select is(jsonb_array_length(tests.val(tests.as_user(:'mod', 'select public.forum_mod_reports()::text'))),
          1, 'the moderator sees the open report');

select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p2', 'Off topic for this thread', 'rules', 'Forum rule 1')),
          'ok:', 'the moderator hides a reply with a reason');
select ok(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1')) !~ :'p2'
          and tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1')) !~ 'A reply|Off topic',
          'another member does not see the hidden reply at all: no id, no text, no reason');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) ->> 'total',
          '1', 'the hidden reply is left out of the thread''s count for other members');
select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,replies}',
          '0', 'the hidden reply is left out of the reply count in the list');
-- Everything here runs in one transaction, so every now() is equal; move the
-- hidden reply a minute later so the time comparison can tell them apart.
update forum.posts set created_at = created_at + interval '1 minute' where id = :'p2';
select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,last_post_at}',
          tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{posts,0,created_at}',
          'the list''s last-post time ignores the hidden reply');
select is(tests.val(tests.as_user(:'mod', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,last_post_at}',
          tests.val(tests.as_user(:'mod', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{posts,1,created_at}',
          'the moderator''s list counts the hidden reply''s time');
-- A second thread, 30 seconds after Alice's opening post but 30 seconds
-- before the hidden reply: the list order and the category time must follow
-- what each reader may see.
select substr(tests.as_user(:'dan', $$select public.forum_create_thread('general', 'Dan asks something', 'A question')::text$$), 4) as t_dan \gset
update forum.posts set created_at = created_at + interval '30 seconds' where thread_id = :'t_dan';
select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,id}',
          :'t_dan', 'for other members the thread with the newest visible post comes first');
select is(tests.val(tests.as_user(:'mod', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,id}',
          :'t1', 'for the moderator the hidden reply still counts in the order');
select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general', 1)::text$$)) #>> '{threads,0,id}',
          :'t_dan', 'a one-thread page picks the newest visible thread for other members');
select is(tests.val(tests.as_user(:'mod', $$select public.forum_threads('general', 1)::text$$)) #>> '{threads,0,id}',
          :'t1', 'and the newest thread counting the hidden reply for the moderator');
select is((select c ->> 'last_post_at' from jsonb_array_elements(tests.val(tests.as_user(:'alice', 'select public.forum_categories()::text'))) c
           where c ->> 'slug' = 'general'),
          (select to_jsonb(created_at) #>> '{}' from forum.posts where thread_id = :'t_dan' and is_opening),
          'the category''s last-post time ignores the hidden reply for other members');
select is((select c ->> 'last_post_at' from jsonb_array_elements(tests.val(tests.as_user(:'mod', 'select public.forum_categories()::text'))) c
           where c ->> 'slug' = 'general'),
          (select to_jsonb(created_at) #>> '{}' from forum.posts where id = :'p2'),
          'the category''s last-post time includes the hidden reply for the moderator');
select is(tests.as_user(:'alice', format('select public.forum_report_post(%L, %L)::text', :'p2', 'Reporting a ghost')),
          'error:forum:not_found', 'a hidden reply cannot be reported by someone who cannot see it');
select is(tests.val(tests.as_user(:'mod', format('select public.forum_thread(%L)::text', :'t1'))) ->> 'total',
          '2', 'the moderator still sees the hidden reply');
select ok((tests.val(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1'))) #> '{posts,1}')
          @> '{"hidden": true, "body": "A reply", "hidden_reason": "Off topic for this thread"}',
          'the author sees her hidden text and the reason');
select is(tests.as_user(:'bob', format('select public.forum_edit_post(%L, %L)::text', :'p2', 'Sneaky edit')),
          'error:forum:hidden', 'a hidden post cannot be edited');

select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p1', 'Breaks the forum rules', 'rules', 'Forum rule 1')),
          'ok:', 'hiding the opening post hides the thread');
select is(tests.as_user(:'dan', format('select public.forum_thread(%L)::text', :'t1')),
          'error:forum:not_found', 'a hidden thread is gone for a member who took no part in it');
select is(tests.val(tests.as_user(:'dan', $$select public.forum_threads('general')::text$$)) ->> 'total',
          '1', 'a hidden thread is left out of that member''s list (only Dan''s own thread is left)');
select ok((tests.val(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1'))) -> 'thread')
          @> '{"title": null, "hidden": true, "hidden_reason": null, "can_reply": false}',
          'a member who replied still finds the thread, without its title or the reason');
select ok(jsonb_path_query_array(tests.val(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1'))), '$.posts[*].id')
          = jsonb_build_array(:'p2')
          and tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1')) !~ 'Hello everyone|First post|Breaks the forum',
          'in a hidden thread a replier sees only their own reply, nothing of the opening post');
select ok((select e from jsonb_array_elements(tests.val(tests.as_user(:'bob', $$select public.forum_threads('general')::text$$)) -> 'threads') e
           where e ->> 'id' = :'t1') @> '{"title": null, "hidden": true}',
          'the replier''s list shows the hidden thread without its title');
select is(tests.as_user(:'bob', format('select public.forum_reply(%L, %L)::text', :'t1', 'Still here?')),
          'error:forum:locked', 'nobody but a moderator replies in a hidden thread');
select ok(tests.as_user(:'mod', format('select public.forum_reply(%L, %L)::text', :'t1', 'Team note while hidden')) like 'ok:%',
          'setup: the moderator writes a visible reply in the hidden thread');
select is(jsonb_path_query_array(tests.val(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1'))), '$.posts[*].id'),
          jsonb_build_array(:'p2'),
          'in a hidden thread a replier does not see a visible reply by someone else');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{thread,hidden_reason}',
          'Breaks the forum rules', 'the thread''s author sees why it was hidden');
select is(tests.as_user(:'mod', format('select public.forum_mod_unhide_post(%L)::text', :'p1')),
          'ok:', 'the moderator restores the opening post');
select is(tests.val(tests.as_user(:'dan', $$select public.forum_threads('general')::text$$)) ->> 'total',
          '2', 'a restored thread is back for everyone');

select is(tests.as_user(:'mod', format('select public.forum_mod_set_thread(%L, true, true)::text', :'t1')),
          'ok:', 'the moderator pins and locks the thread');
select is(tests.as_user(:'bob', format('select public.forum_reply(%L, %L)::text', :'t1', 'Still here')),
          'error:forum:locked', 'nobody but a moderator replies in a locked thread');
select is(tests.as_user(:'mod', format('select public.forum_reply(%L, %L)::text', :'t1', 'Closing this one')) like 'ok:%',
          true, 'a moderator may still reply in a locked thread');
select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,pinned}',
          'true', 'the thread shows as pinned');

-- ---------------------------------------------------------------------------
-- 6b. DSA Art. 16 (notices) and Art. 17 (statements of reasons)
-- ---------------------------------------------------------------------------

select id as r1 from forum.reports limit 1 \gset
select ok((select resolution_action = 'hidden' and resolution ~ 'Forum rule 1' from forum.reports where id = :'r1'),
          'hiding a reported post decides its open notice, naming the ground');
select is(tests.as_user(:'mod', format('select public.forum_mod_resolve_report(%L, %L)::text', :'r1', 'Again')),
          'error:forum:not_found', 'a decided notice cannot be decided again');
select is(tests.val(tests.as_user(:'bob', 'select public.forum_me()::text')) ->> 'reports_decided_unseen',
          '1', 'the notifier is told a decision is waiting');
select ok(tests.val(tests.as_user(:'bob', 'select public.forum_my_reports()::text'))
          @> jsonb_build_array(jsonb_build_object('id', :'r1', 'kind', 'rules', 'decided', true,
                                                  'action', 'hidden', 'seen', false)),
          'the notifier sees the decision on their notice');
select ok((select resolution like '%A moderator later restored the post.' and decision_seen_at is null
           from forum.reports where id = :'r1'),
          'restoring the post adds that to the notifier''s decision, as new');
select is(tests.as_user(:'bob', format('select public.forum_mark_reports_seen(%L)::text', array[:'r1'])), 'ok:',
          'the notifier marks the decisions they were shown as seen');
select is(tests.val(tests.as_user(:'bob', 'select public.forum_me()::text')) ->> 'reports_decided_unseen',
          '0', 'and nothing is waiting any more');

select is(tests.as_user(:'dan', format('select public.forum_report_post(%L, %L, %L)::text', :'p1', 'This is unlawful', 'other')),
          'error:forum:invalid_kind', 'a notice is either about the rules or about illegal content');
select is(tests.as_user(:'dan', format('select public.forum_report_post(%L, %L, %L)::text', :'p1', 'This post defames a named person', 'illegal')),
          'error:forum:good_faith_required', 'an illegal-content notice needs the statement of good faith');
select is(tests.as_user(:'dan', format('select public.forum_report_post(%L, %L, %L, true)::text', :'p1', 'Unlawful', 'illegal')),
          'error:forum:invalid_notice', 'an illegal-content notice needs a real explanation');
select is(tests.as_user(:'dan', format('select public.forum_report_post(%L, %L, %L, true)::text', :'p1', 'This post defames a named person', 'illegal')),
          'ok:', 'a member sends an illegal-content notice');
select ok(tests.val(tests.as_user(:'mod', 'select public.forum_mod_reports()::text')) @> '[{"kind": "illegal", "good_faith": true}]',
          'the moderators see what kind of notice it is and the statement of good faith');
select id as r_dan from forum.reports where reporter_id = :'dan' \gset
select ok(tests.val(tests.as_user(:'dan', 'select public.forum_my_reports()::text'))
          @> jsonb_build_array(jsonb_build_object('id', :'r_dan', 'kind', 'illegal', 'decided', false)),
          'the notifier sees the notice as received at once');
select is(tests.as_user(:'mod', format('select public.forum_mod_resolve_report(%L, %L)::text', :'r_dan', 'We looked and found nothing unlawful in the post')),
          'ok:', 'the moderator decides to take no action, with an explanation');
select ok(tests.val(tests.as_user(:'dan', 'select public.forum_my_reports()::text'))
          @> jsonb_build_array(jsonb_build_object('id', :'r_dan', 'decided', true, 'action', 'no_action',
                                                  'decision', 'We looked and found nothing unlawful in the post')),
          'the notifier reads the decision and its explanation');
select is(tests.as_user(:'bob', format('select public.forum_mark_reports_seen(%L)::text', array[:'r_dan'])), 'ok:',
          'setup: another member tries to mark Dan''s decision as seen');
select ok((select decision_seen_at is null from forum.reports where id = :'r_dan'),
          'nobody marks another member''s decision as seen');
select ok(tests.as_user(:'alice', 'select public.forum_my_reports()::text') !~ :'r_dan',
          'nobody sees another member''s notices');
select ok(tests.val(tests.as_user(:'bob', 'select public.forum_my_hidden_posts()::text'))
          @> jsonb_build_array(jsonb_build_object('id', :'p2', 'decision',
               jsonb_build_object('basis_reference', 'Forum rule 1', 'facts', 'Off topic for this thread'))),
          'the author finds each hidden post of theirs with its statement of reasons');
select ok(tests.as_user(:'alice', 'select public.forum_my_hidden_posts()::text') !~ :'p2',
          'nobody sees another member''s hidden posts there');

select ok((tests.val(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1'))) #> '{posts,1,decision}')
          @> '{"action": "hide_post", "basis": "rules", "basis_reference": "Forum rule 1", "facts": "Off topic for this thread", "source": "own_initiative", "automated": false, "lifted_at": null}',
          'the author of a hidden reply gets the whole statement of reasons');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p2', 'Twice', 'rules', 'Forum rule 1')),
          'error:forum:already_hidden', 'a hidden post is not hidden twice');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p1', 'No ground', 'politeness', 'Forum rule 1')),
          'error:forum:invalid_basis', 'a decision rests on the forum rules or on the law');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p1', 'No ground', 'illegal', '  ')),
          'error:forum:invalid_basis', 'a decision names its rule or legal ground');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L, %L)::text', :'p1', 'Reason', 'rules', 'Forum rule 1', 'rumour')),
          'error:forum:invalid_source', 'a decision says what it followed');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L, %L)::text', :'p1', 'Reason', 'rules', 'Forum rule 1', 'member_report')),
          'error:forum:invalid_source', 'a decision on a member''s notice names the notice');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L, %L, %L)::text', :'p1', 'Reason', 'rules', 'Forum rule 1', 'member_report', :'r1')),
          'error:forum:not_found', 'the notice must be an open one about that post');
select ok((select lifted_at is not null from forum.decisions where post_id = :'p1' and action = 'hide_post'),
          'restoring a hidden post lifts its decision');
select substr(tests.as_user(:'alice', $$select public.forum_create_thread('general', 'A thread to report', 'Something to report')::text$$), 4) as t_rep \gset
select id as p_rep from forum.posts where thread_id = :'t_rep' and is_opening \gset
select is(tests.as_user(:'dan', format('select public.forum_report_post(%L, %L)::text', :'p_rep', 'Breaks rule 2')),
          'ok:', 'setup: Dan reports a post');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p_rep', 'Off topic', 'rules', 'Forum rule 2')),
          'ok:', 'setup: the moderator hides it, choosing their own review');
select ok((select source = 'member_report' and report_id is not null from forum.decisions where post_id = :'p_rep'),
          'a hide over an open notice is recorded as following the notice');
select is(tests.as_user(:'mod', format('select public.forum_mod_unhide_post(%L)::text', :'p_rep')),
          'ok:', 'setup: and restores it');

select is(tests.as_user(:'mod', $$select public.forum_mod_invite('not-an-email')::text$$),
          'error:forum:invalid_email', 'an invitation needs an email address');
select is(tests.as_user(:'mod', $$select public.forum_mod_invite('  Carol@Example.com ')::text$$),
          'ok:', 'the moderator invites an address');
select is(tests.val(tests.as_user(:'carol', $$select public.forum_join('Carol', true, '1.0')::text$$)) ->> 'state',
          'member', 'the newly invited user joins');
select is(tests.as_user(:'mod', $$select public.forum_mod_revoke_invite('carol@example.com')::text$$),
          'ok:', 'the moderator revokes an invitation');
select is(public.forum_before_user_created('{"user":{"email":"carol@example.com"}}') -> 'error' ->> 'http_code',
          '403', 'a revoked address can no longer sign up');
select is(tests.as_user(:'mod', format('select public.forum_mod_suspend(%L, %L, %L, %L)::text', :'carol', 'Repeated rude replies', 'rules', 'Forum rule 1')),
          'ok:', 'the moderator suspends a member');
select is(tests.as_user(:'carol', 'select public.forum_categories()::text'),
          'error:forum:suspended', 'a suspended member cannot read the forum');
select is(tests.val(tests.as_user(:'carol', 'select public.forum_me()::text')) ->> 'suspended_reason',
          'Repeated rude replies', 'a suspended member is told why');
select ok(tests.val(tests.as_user(:'carol', 'select public.forum_me()::text')) -> 'suspension'
          @> '{"action": "suspend_account", "basis": "rules", "basis_reference": "Forum rule 1", "source": "own_initiative", "automated": false, "lifted_at": null}',
          'a suspended member gets the whole statement of reasons');
select is(tests.as_user(:'mod', format('select public.forum_mod_suspend(%L, %L, %L, %L)::text', :'carol', 'Again', 'rules', 'Forum rule 1')),
          'error:forum:already_suspended', 'a suspended member is not suspended twice');
select is(tests.offenders(:'carol', 'error:forum:suspended', false, true), null,
          'a suspended member is refused by every member and moderator function but their own records');
select is((select string_agg(c.name || ' -> ' || r, '; ' order by c.name)
           from tests.calls c cross join lateral tests.as_user(:'carol', c.call) r
           where c.self_service and r = 'error:forum:suspended'), null,
          'a suspended member still reaches My reports, their hidden posts and deleting their own posts');
select is(tests.as_user(:'mod', format('select public.forum_mod_suspend(%L, %L, %L, %L)::text', :'mod', 'Testing myself', 'rules', 'Forum rule 1')),
          'error:forum:cannot_suspend_moderator', 'a moderator cannot be suspended through the forum');
select is(tests.as_user(:'mod', format('select public.forum_mod_unsuspend(%L)::text', :'carol')),
          'ok:', 'the moderator lifts a suspension');
select ok((select lifted_at is not null from forum.decisions where member_id = :'carol' and action = 'suspend_account'),
          'lifting a suspension lifts its decision');
select ok(tests.as_user(:'mod', 'select public.forum_mod_members()::text') ~ 'carol@example\.com',
          'the moderator sees members'' email addresses');
select is(tests.as_user(:'alice', 'select public.forum_mod_invitations()::text'),
          'error:forum:not_moderator', 'a member cannot list the invitations');
select ok(tests.val(tests.as_user(:'mod', 'select public.forum_mod_invitations()::text'))
          @> '[{"email": "alice@example.com", "member": "Alice", "revoked": false}, {"email": "carol@example.com", "revoked": true}]',
          'the moderator sees each invitation, who joined and what was withdrawn');
-- Thirteen: hiding a reported post also logs the notice it decided, and
-- 6b hides, decides and restores one more post.
select is((select count(*) from forum.moderation_log), 13::bigint,
          'every moderator action is logged');

-- ---------------------------------------------------------------------------
-- 7. Deleting your own post
-- ---------------------------------------------------------------------------

select is(tests.as_user(:'alice', format('select public.forum_delete_post(%L)::text', :'p1')),
          'ok:', 'the author deletes her opening post');
select ok((select body = '' and deleted_at is not null from forum.posts where id = :'p1')
          and (select title = '' and deleted_at is not null from forum.threads where id = :'t1'),
          'the deleted text and title are gone from the database');
select ok((tests.val(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1'))) -> 'thread')
          @> '{"deleted": true, "title": null}',
          'others see the thread as deleted, with the replies kept');
select is(tests.as_user(:'alice', format('select public.forum_delete_post(%L)::text', :'p1')),
          'error:forum:not_found', 'a deleted post cannot be deleted again');

-- ---------------------------------------------------------------------------
-- 8. Throttling
-- ---------------------------------------------------------------------------

select substr(tests.as_user(:'mod', $$select public.forum_create_thread('general', 'Open thread', 'Talk here')::text$$), 4) as t2 \gset
select is((select count(*) from generate_series(1, 15) g
           where tests.as_user(:'bob', format('select public.forum_reply(%L, %L)::text', :'t2', 'Reply ' || g)) like 'ok:%'),
          10 - (select count(*) from forum.posts where author_id = :'bob' and created_at > now() - interval '10 minutes' and thread_id <> :'t2'),
          'a member gets at most ten posts in ten minutes');
select is(tests.as_user(:'bob', format('select public.forum_reply(%L, %L)::text', :'t2', 'One more')),
          'error:forum:rate_limited', 'the eleventh post is refused as rate_limited');

-- Paging a thread by cursor (t2 now holds ten posts).
select tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L, 2)::text', :'t2'))) #>> '{posts,1,id}' as page1_last \gset
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L, 2, %L)::text', :'t2', :'page1_last'))) #>> '{posts,0,id}',
          (select id::text from forum.posts where thread_id = :'t2' order by seq offset 2 limit 1),
          'the next page starts right after the cursor');
select is(jsonb_array_length(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L, 100, %L)::text', :'t2', :'page1_last'))) -> 'posts'),
          (select count(*)::integer - 2 from forum.posts where thread_id = :'t2'),
          'the pages after the cursor hold every remaining post, none twice');
select is(tests.as_user(:'alice', format('select public.forum_thread(%L, 2, %L)::text', :'t2', :'p1')),
          'error:forum:not_found', 'a cursor from another thread is refused');

-- ---------------------------------------------------------------------------
-- 9. Read-only when the beta ends
-- ---------------------------------------------------------------------------

update forum.settings set read_only = true;
select is(tests.val(tests.as_user(:'alice', 'select public.forum_me()::text')) ->> 'read_only',
          'true', 'forum_me tells members the forum is read-only');
select is(tests.as_user(:'alice', $$select public.forum_create_thread('general', 'After the beta', 'Hello')::text$$),
          'error:forum:read_only', 'no new thread while read-only');
select is(tests.as_user(:'alice', format('select public.forum_reply(%L, %L)::text', :'t2', 'Late reply')),
          'error:forum:read_only', 'no reply while read-only');
select id as p3 from forum.posts where author_id = :'bob' and thread_id = :'t2' and deleted_at is null limit 1 \gset
select is(tests.as_user(:'bob', format('select public.forum_edit_post(%L, %L)::text', :'p3', 'Edited late')),
          'error:forum:read_only', 'no edit while read-only');
select is(tests.as_user(:'bob', format('select public.forum_delete_post(%L)::text', :'p3')),
          'ok:', 'a member may still delete her own post while read-only');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t2'))) ->> 'total',
          '10', 'members can still read while read-only');
select is(tests.as_user(:'mod', $$select public.forum_create_thread('announcements', 'The forum closes', 'Thank you all')::text$$) like 'ok:%',
          true, 'a moderator can still post an announcement while read-only');
update forum.settings set read_only = false;

-- ---------------------------------------------------------------------------
-- 10. Access and erasure requests, run by the owner in the SQL editor
-- ---------------------------------------------------------------------------

select alike(tests.as_user(:'alice', $$select forum.erase_member('bob@example.com')::text$$),
             'error:permission denied%', 'a member cannot call the erasure function');
select alike(tests.as_user(:'alice', $$select forum.export_member('bob@example.com')::text$$),
             'error:permission denied%', 'a member cannot call the export function');
select throws_ok($$select forum.erase_member('  ')$$, 'P0001', 'forum:invalid_email',
                 'the erasure refuses an empty address instead of matching everything');
select throws_ok($$select forum.export_member('not-an-email')$$, 'P0001', 'forum:invalid_email',
                 'the export refuses something that is not an address');

-- Give Bob a history that names him everywhere it can: the moderator invites
-- him again and suspends him, hides one of his replies after Alice reports it,
-- resolves the report, and Supabase Auth's sign-in log names him by address
-- and by id. Two near misses in that log must survive his erasure.
select id as p4 from forum.posts
 where author_id = :'bob' and thread_id = :'t2' and deleted_at is null order by seq limit 1 \gset
select is(tests.as_user(:'mod', $$select public.forum_mod_invite('bob@example.com')::text$$), 'ok:',
          'setup: Bob is invited again (the log records his address)');
select is(tests.as_user(:'alice', format('select public.forum_report_post(%L, %L)::text', :'p4', 'Bob is being rude here')),
          'ok:', 'setup: Alice reports one of Bob''s replies');
select id as r2 from forum.reports where post_id = :'p4' \gset
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L, %L, %L)::text',
                                       :'p4', 'Rude reply by Bob', 'rules', 'Forum rule 1', 'member_report', :'r2')),
          'ok:', 'setup: the moderator hides it after Alice''s report, which decides the report');
-- Bob hit the throttle earlier in this transaction; age his posts so he can
-- start a thread of his own.
update forum.posts set created_at = created_at - interval '1 hour' where author_id = :'bob';
select substr(tests.as_user(:'bob', $$select public.forum_create_thread('feedback', 'Bob''s own idea', 'Please add dark mode')::text$$), 4) as t_bob \gset
select ok(:'t_bob' ~ '^[0-9a-f-]{36}$', 'setup: Bob starts a thread of his own');
select id as p_bob1 from forum.posts where thread_id = :'t_bob' and is_opening \gset
select is(tests.as_user(:'dan', format('select public.forum_report_post(%L, %L)::text', :'p_bob1', 'Please look at this')),
          'ok:', 'setup: Dan reports Bob''s thread, and nobody decides it before Bob is erased');
select id as r_bob1 from forum.reports where post_id = :'p_bob1' \gset
select substr(tests.as_user(:'bob', $$select public.forum_create_thread('feedback', 'Bob''s second idea', 'Something rude')::text$$), 4) as t_bob2 \gset
select id as p_bob2 from forum.posts where thread_id = :'t_bob2' and is_opening \gset
select ok(tests.as_user(:'alice', format('select public.forum_reply(%L, %L)::text', :'t_bob2', 'Alice replies to Bob')) like 'ok:%',
          'setup: Alice replies in Bob''s second thread');
select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p_bob2', 'Rude opening', 'rules', 'Forum rule 1')),
          'ok:', 'setup: the moderator hides Bob''s second thread');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t_bob2'))) #>> '{thread,hidden}',
          'true', 'while Bob is a member, Alice (who replied) still finds his hidden thread');
select is(tests.as_user(:'mod', format('select public.forum_mod_suspend(%L, %L, %L, %L)::text', :'bob', 'Bob was rude twice', 'rules', 'Forum rule 1')),
          'ok:', 'setup: the moderator suspends Bob');
insert into auth.audit_log_entries (id, payload, created_at) values
  (gen_random_uuid(), json_build_object('action', 'login', 'actor_username', 'bob@example.com'), now()),
  (gen_random_uuid(), json_build_object('action', 'token_refreshed', 'actor_id', :'bob'), now()),
  (gen_random_uuid(), json_build_object('action', 'login', 'actor_username', 'xbob@example.com'), now()),
  (gen_random_uuid(), json_build_object('action', 'login', 'actor_username', 'bob@example.com.au'), now());

select is(jsonb_array_length(forum.export_member(' BOB@example.com ') -> 'posts'),
          (select count(*)::integer from forum.posts where author_id = :'bob'),
          'the export holds every post of the member');
select is(forum.export_member('bob@example.com') #>> '{member,display_name}', 'Bob',
          'the export holds the membership');
select is(forum.export_member('bob@example.com') #>> '{account,email}', 'bob@example.com',
          'the export holds the sign-in account');
select is(jsonb_array_length(forum.export_member('bob@example.com') -> 'sign_in_log'), 2,
          'the export holds exactly the sign-in log entries that name him');
select ok(forum.export_member('bob@example.com') -> 'moderation'
          @> '[{"action": "invite"}, {"action": "suspend", "reason": "Bob was rude twice"},
               {"action": "hide_post", "reason": "Rude reply by Bob"}, {"action": "resolve_report"}]',
          'the export holds the moderator actions about him and his posts');
select ok(forum.export_member('bob@example.com') -> 'decisions'
          @> '[{"action": "hide_post", "facts": "Rude reply by Bob", "source": "member_report", "basis_reference": "Forum rule 1"},
               {"action": "suspend_account", "facts": "Bob was rude twice"}]',
          'the export holds the statements of reasons about him');
select ok(forum.export_member('bob@example.com') -> 'reports_about_posts' @> '[{"reason": "Bob is being rude here"}]'
          and forum.export_member('bob@example.com')::text !~ :'alice'
          and (forum.export_member('bob@example.com') -> 'reports_about_posts')::text !~ 'Alice',
          'the export holds reports about his posts without saying who made them');

select is(forum.erase_member('bob@example.com') ->> 'account', 'true', 'the erasure finds the account');
select ok(not exists (select 1 from auth.users where id = :'bob')
          and not exists (select 1 from forum.members where user_id = :'bob')
          and not exists (select 1 from forum.invitations where email = 'bob@example.com'),
          'the account, the membership and the invitation are gone');
select ok(not exists (select 1 from forum.decisions where member_id = :'bob')
          and not exists (select 1 from forum.decisions where facts ~* 'bob' or basis_reference ~* 'bob')
          and (select count(*) from forum.decisions where facts = 'Erased on request') >= 2,
          'the statements of reasons about him lose his link and the moderator''s words');
select is((select count(*) from forum.posts where body like 'Reply %' or body = 'A reply'),
          0::bigint, 'the erased member''s texts are wiped');
select is((select count(*) from forum.moderation_log
           where target in ('bob@example.com', :'bob') or moderator_id = :'bob'),
          0::bigint, 'no moderation log row names his address or his id');
select is((select count(*) from forum.moderation_log
           where reason ~* 'bob' or target ~* 'bob'), 0::bigint,
          'no moderator''s words about him or his posts are left in the log');
select ok((select count(*) from forum.moderation_log where target = 'erased') >= 2,
          'the log keeps that actions happened, without saying about whom');
select ok((select count(*) from forum.reports where post_id = :'p4') = 1
          and tests.val(tests.as_user(:'alice', 'select public.forum_my_reports()::text'))
              @> jsonb_build_array(jsonb_build_object('id', :'r2', 'action', 'hidden')),
          'another member''s decided notice about his post stays hers');
select ok(tests.val(tests.as_user(:'dan', 'select public.forum_my_reports()::text'))
          @> jsonb_build_array(jsonb_build_object('id', :'r_bob1', 'decided', true, 'action', 'removed', 'seen', false)),
          'an open notice about his post is decided as removed, and its notifier is told');
select is((select count(*) from auth.audit_log_entries
           where payload::text like '%' || :'bob' || '%'), 0::bigint,
          'the sign-in log entry that names him by id is deleted');
select is((select string_agg(coalesce(payload ->> 'actor_username', '(no address)'), ','
                             order by payload ->> 'actor_username')
           from auth.audit_log_entries),
          'bob@example.com.au,xbob@example.com',
          'the entry that names his address is deleted and exactly the two near misses stay');
select ok(not exists (select 1 from forum.reports where id = :'r1')
          and (select reason is null from forum.moderation_log where target = :'r1'),
          'the report he made is deleted, and the moderator''s note on it is wiped from the log');
select ok((select title = '' and deleted_at is not null from forum.threads where id = :'t_bob')
          and (select e from jsonb_array_elements(tests.val(tests.as_user(:'alice', $$select public.forum_threads('feedback')::text$$)) -> 'threads') e
               where e ->> 'id' = :'t_bob') @> '{"title": null, "deleted": true}',
          'the title of the thread he started is wiped');
select is(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t_bob2')),
          'error:forum:not_found', 'once its author is erased, a hidden thread is gone even for a member who replied in it');
select is(tests.as_user(:'dan', format('select public.forum_thread(%L)::text', :'t_bob2')),
          'error:forum:not_found', 'and for a member who took no part in it');
select ok(tests.as_user(:'alice', $$select public.forum_threads('feedback')::text$$) !~ :'t_bob2',
          'and stays out of their lists');
select is(tests.val(tests.as_user(:'mod', format('select public.forum_thread(%L)::text', :'t_bob2'))) #>> '{thread,hidden}',
          'true', 'a moderator still finds it');
select is(tests.as_user(:'alice', format('select public.forum_report_post(%L, %L)::text', :'p_bob2', 'Reporting a ghost')),
          'error:forum:not_found', 'and its opening post cannot be reported');
select ok(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t2')) !~ :'p4',
          'his hidden reply stays hidden from other members after the erasure');
select is((select hidden_reason from forum.posts where id = :'p4'), 'Erased on request',
          'the moderator''s reason about his hidden reply is replaced');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t2'))) #>> '{posts,1,author,name}',
          null, 'an erased member''s place in a thread shows no name');
select is((select jsonb_build_array(e -> 'account', e -> 'member', e -> 'invitation',
                                    jsonb_array_length(e -> 'posts'), jsonb_array_length(e -> 'threads'),
                                    jsonb_array_length(e -> 'sessions'), jsonb_array_length(e -> 'sign_in_log'),
                                    jsonb_array_length(e -> 'reports_made'), jsonb_array_length(e -> 'reports_about_posts'),
                                    jsonb_array_length(e -> 'moderation'), jsonb_array_length(e -> 'decisions'))
           from (select forum.export_member('bob@example.com') e) x),
          '[null, null, null, 0, 0, 0, 0, 0, 0, 0, 0]'::jsonb,
          'after the erasure an export for his address finds nothing at all');

-- A second moderator, whose own export must not hand over other people's
-- data, and whose erasure must take their id off everything they touched.
select is(tests.val(tests.as_user(:'mod2', $$select public.forum_join('Helper', true, '1.0')::text$$)) ->> 'state',
          'member', 'setup: a second moderator joins');
update forum.members set role = 'moderator' where user_id = :'mod2';
select id as p_dan from forum.posts where thread_id = :'t_dan' and is_opening \gset
select id as p_mod from forum.posts where thread_id = :'t2' and is_opening \gset
select is(tests.as_user(:'alice', format('select public.forum_report_post(%L, %L)::text', :'p_mod', 'Testing the report')),
          'ok:', 'setup: Alice reports a post');
select id as r3 from forum.reports where post_id = :'p_mod' and resolved_at is null \gset
select ok(tests.as_user(:'mod2', $$select public.forum_mod_invite('zed@example.com')::text$$) = 'ok:'
          and tests.as_user(:'mod2', format('select public.forum_mod_suspend(%L, %L, %L, %L)::text', :'dan', 'Dan posted spam', 'rules', 'Forum rule 1')) = 'ok:'
          and tests.as_user(:'mod2', format('select public.forum_mod_hide_post(%L, %L, %L, %L)::text', :'p_dan', 'Dan broke rule 4', 'rules', 'Forum rule 1')) = 'ok:'
          and tests.as_user(:'mod2', format('select public.forum_mod_resolve_report(%L, %L)::text', :'r3', 'Looked at it')) = 'ok:',
          'setup: the second moderator invites, suspends, hides and resolves');
select is(jsonb_array_length(forum.export_member('helper@example.com') -> 'moderation'), 4,
          'the moderator''s export lists the four actions they took');
select ok(forum.export_member('helper@example.com')::text !~ ('zed@example|Dan posted spam|Dan broke rule|Looked at it|'
                                                              || :'dan' || '|' || :'p_dan' || '|' || :'r3'),
          'but not whom they were about or why: that is other people''s data');
select is(forum.erase_member('helper@example.com') ->> 'account', 'true', 'the second moderator is erased');
select ok(not exists (select 1 from forum.moderation_log where moderator_id = :'mod2')
          and (select invited_by is null from forum.invitations where email = 'zed@example.com')
          and (select hidden_by is null from forum.posts where id = :'p_dan')
          and (select hidden_by is null from forum.threads where id = :'t_dan')
          and (select resolved_by is null from forum.reports where id = :'r3'),
          'the erased moderator''s id is gone from the log, the invitation, the hidden post and thread, and the report');
select ok(exists (select 1 from forum.decisions where post_id = :'p_dan')
          and not exists (select 1 from forum.decisions where decided_by = :'mod2'),
          'the erased moderator''s decisions stay for their members, without the moderator''s id');
select ok((select reason = 'Dan posted spam' from forum.moderation_log where action = 'suspend' and target = :'dan')
          and exists (select 1 from forum.moderation_log where target = 'zed@example.com'),
          'what the log says about other people stays, since it is theirs, not the moderator''s');
select ok(forum.export_member('zed@example.com') -> 'moderation' @> '[{"action": "invite", "by_this_person": false}]'
          and not (forum.export_member('zed@example.com') -> 'moderation' @> '[{"by_this_person": true}]'),
          'an address with no account is never taken for the moderator of an erased moderator''s actions');

select is(tests.as_user(:'mod', $$select public.forum_mod_invite('dave@example.com')::text$$), 'ok:',
          'setup: an address is invited but never signs in');
insert into auth.audit_log_entries (id, payload, created_at)
values (gen_random_uuid(), json_build_object('action', 'user_signedup', 'actor_username', 'dave@example.com'), now());
select ok(forum.erase_member('Dave@Example.com') @> '{"account": false}',
          'erasing an address that never signed in reports no account');
-- A separate statement: one statement sees the data as it was when it began.
select ok(not exists (select 1 from forum.moderation_log where target = 'dave@example.com')
          and not exists (select 1 from forum.invitations where email = 'dave@example.com'),
          'erasing an address that never signed in removes the invitation and its log rows');
select is((select count(*) from auth.audit_log_entries where payload::text like '%dave@example.com%'), 0::bigint,
          'erasing an address with no account still deletes the sign-in log entries that name it');

select * from finish();
rollback;
