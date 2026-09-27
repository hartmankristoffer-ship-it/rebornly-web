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

create function tests.val(p text) returns jsonb
language sql as $$
  select case when p like 'ok:%' then substr(p, 4)::jsonb
              else jsonb_build_object('error', p) end
$$;

insert into auth.users (id, email) values
  (:'alice', 'alice@example.com'),
  (:'bob',   'bob@example.com'),
  (:'carol', 'carol@example.com'),
  (:'mod',   'owner@example.com');

-- Bootstrap exactly as the runbook does it: the owner's invitation and role
-- are written by direct database access.
insert into forum.invitations (email) values
  ('alice@example.com'), ('bob@example.com'), ('owner@example.com');

select plan(109);

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
update forum.members set role = 'moderator' where user_id = :'mod';
select is(tests.val(tests.as_user(:'mod', 'select public.forum_me()::text')) ->> 'moderator',
          'true', 'the moderator role, set by direct access, shows in forum_me');

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

select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L)::text', :'p2', 'Off topic for this thread')),
          'ok:', 'the moderator hides a reply with a reason');
select ok((tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) #> '{posts,1}')
          @> '{"hidden": true, "body": null, "hidden_reason": null}',
          'other members see neither the hidden text nor the reason');
select ok((tests.val(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1'))) #> '{posts,1}')
          @> '{"hidden": true, "body": "A reply", "hidden_reason": "Off topic for this thread"}',
          'the author sees her hidden text and the reason');
select is(tests.as_user(:'bob', format('select public.forum_edit_post(%L, %L)::text', :'p2', 'Sneaky edit')),
          'error:forum:hidden', 'a hidden post cannot be edited');

select is(tests.as_user(:'mod', format('select public.forum_mod_hide_post(%L, %L)::text', :'p1', 'Breaks the forum rules')),
          'ok:', 'hiding the opening post hides the thread');
select is(tests.as_user(:'bob', format('select public.forum_thread(%L)::text', :'t1')),
          'error:forum:not_found', 'a hidden thread is gone for other members');
select is(tests.val(tests.as_user(:'bob', $$select public.forum_threads('general')::text$$)) ->> 'total',
          '0', 'a hidden thread is left out of other members'' lists');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{thread,hidden_reason}',
          'Breaks the forum rules', 'the thread''s author sees why it was hidden');
select is(tests.as_user(:'mod', format('select public.forum_mod_unhide_post(%L)::text', :'p1')),
          'ok:', 'the moderator restores the opening post');
select is(tests.val(tests.as_user(:'bob', $$select public.forum_threads('general')::text$$)) ->> 'total',
          '1', 'a restored thread is back for everyone');

select is(tests.as_user(:'mod', format('select public.forum_mod_set_thread(%L, true, true)::text', :'t1')),
          'ok:', 'the moderator pins and locks the thread');
select is(tests.as_user(:'bob', format('select public.forum_reply(%L, %L)::text', :'t1', 'Still here')),
          'error:forum:locked', 'nobody but a moderator replies in a locked thread');
select is(tests.as_user(:'mod', format('select public.forum_reply(%L, %L)::text', :'t1', 'Closing this one')) like 'ok:%',
          true, 'a moderator may still reply in a locked thread');
select is(tests.val(tests.as_user(:'alice', $$select public.forum_threads('general')::text$$)) #>> '{threads,0,pinned}',
          'true', 'the thread shows as pinned');

select id as r1 from forum.reports limit 1 \gset
select is(tests.as_user(:'mod', format('select public.forum_mod_resolve_report(%L, %L)::text', :'r1', 'Checked, no action')),
          'ok:', 'the moderator resolves a report');
select is(tests.as_user(:'mod', format('select public.forum_mod_resolve_report(%L, %L)::text', :'r1', 'Again')),
          'error:forum:not_found', 'a resolved report cannot be resolved again');

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
select is(tests.as_user(:'mod', format('select public.forum_mod_suspend(%L, %L)::text', :'carol', 'Repeated rude replies')),
          'ok:', 'the moderator suspends a member');
select is(tests.as_user(:'carol', 'select public.forum_categories()::text'),
          'error:forum:suspended', 'a suspended member cannot read the forum');
select is(tests.val(tests.as_user(:'carol', 'select public.forum_me()::text')) ->> 'suspended_reason',
          'Repeated rude replies', 'a suspended member is told why');
select is(tests.as_user(:'mod', format('select public.forum_mod_suspend(%L, %L)::text', :'mod', 'Testing myself')),
          'error:forum:cannot_suspend_moderator', 'a moderator cannot be suspended through the forum');
select is(tests.as_user(:'mod', format('select public.forum_mod_unsuspend(%L)::text', :'carol')),
          'ok:', 'the moderator lifts a suspension');
select ok(tests.as_user(:'mod', 'select public.forum_mod_members()::text') ~ 'carol@example\.com',
          'the moderator sees members'' email addresses');
select is(tests.as_user(:'alice', 'select public.forum_mod_invitations()::text'),
          'error:forum:not_moderator', 'a member cannot list the invitations');
select ok(tests.val(tests.as_user(:'mod', 'select public.forum_mod_invitations()::text'))
          @> '[{"email": "alice@example.com", "member": "Alice", "revoked": false}, {"email": "carol@example.com", "revoked": true}]',
          'the moderator sees each invitation, who joined and what was withdrawn');
select is((select count(*) from forum.moderation_log), 9::bigint,
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
select is(jsonb_array_length(forum.export_member(' BOB@example.com ') -> 'posts'),
          (select count(*)::integer from forum.posts where author_id = :'bob'),
          'the export holds every post of the member');
select is(forum.export_member('bob@example.com') #>> '{member,display_name}', 'Bob',
          'the export holds the membership');
select is(forum.erase_member('bob@example.com') ->> 'account', 'true', 'the erasure finds the account');
select ok(not exists (select 1 from auth.users where id = :'bob')
          and not exists (select 1 from forum.members where user_id = :'bob')
          and not exists (select 1 from forum.invitations where email = 'bob@example.com'),
          'the account, the membership and the invitation are gone');
select is((select count(*) from forum.posts where body like 'Reply %' or body = 'A reply'),
          0::bigint, 'the erased member''s texts are wiped');
select is(tests.val(tests.as_user(:'alice', format('select public.forum_thread(%L)::text', :'t1'))) #>> '{posts,1,author,name}',
          null, 'an erased member''s place in a thread shows no name');

select * from finish();
rollback;
