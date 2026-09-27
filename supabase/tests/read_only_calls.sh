#!/usr/bin/env bash
# WEB-02: every read-only (STABLE) forum function must work inside a
# read-only transaction, because that is how the Data API (PostgREST) runs
# it. pgTAP runs inside one read-write transaction and cannot see this.
# Run by scripts/test-forum.sh inside its throwaway container:
#   read_only_calls.sh <container>
set -uo pipefail
export MSYS_NO_PATHCONV=1
C="$1"
q() { docker exec "$C" psql -U postgres -h localhost -X -v ON_ERROR_STOP=1 -qtAc "$1"; }

MOD=20000000-0000-4000-8000-000000000001
THREAD=20000000-0000-4000-8000-0000000000aa
fail=0

q "insert into auth.users (id, email) values ('$MOD', 'mod@readonly.test');
   insert into forum.invitations (email) values ('mod@readonly.test');
   insert into forum.members (user_id, display_name, role, rules_version, adult_confirmed_at)
     values ('$MOD', 'Read Only Mod', 'moderator', '1.0', now());
   insert into forum.threads (id, category_id, author_id, title) values ('$THREAD', 4, '$MOD', 'Read-only thread');
   insert into forum.posts (thread_id, author_id, is_opening, body) values ('$THREAD', '$MOD', true, 'Opening');" \
  || { echo "not ok - read-only setup"; exit 1; }

# One call per read-only function, run as a moderator so that every one of
# them is allowed.
declare -A CALLS=(
  [forum_me]="select public.forum_me()"
  [forum_categories]="select public.forum_categories()"
  [forum_threads]="select public.forum_threads('general')"
  [forum_thread]="select public.forum_thread('$THREAD')"
  [forum_mod_reports]="select public.forum_mod_reports()"
  [forum_my_reports]="select public.forum_my_reports()"
  [forum_mod_invitations]="select public.forum_mod_invitations()"
  [forum_mod_members]="select public.forum_mod_members()"
)

# The list above must be exactly the read-only forum functions.
stable="$(q "select string_agg(p.proname, ' ' order by p.proname) from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname like 'forum\_%' and p.provolatile in ('s', 'i')")"
listed="$(printf '%s\n' "${!CALLS[@]}" | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$stable" != "$listed" ]; then
  echo "not ok - read-only functions ($stable) differ from the calls listed here ($listed)"; fail=1
fi

for name in $(printf '%s\n' "${!CALLS[@]}" | sort); do
  out="$(docker exec -i "$C" psql -U postgres -h localhost -X -qtA -v ON_ERROR_STOP=1 2>&1 <<SQL
begin transaction read only;
select set_config('request.jwt.claim.sub', '$MOD', true) \g /dev/null
set local role authenticated;
${CALLS[$name]};
rollback;
SQL
)"
  if [ $? -eq 0 ] && ! echo "$out" | grep -q "ERROR"; then
    echo "ok - $name works in a read-only transaction"
  else
    echo "not ok - $name fails in a read-only transaction: $out"; fail=1
  fi
done

exit "$fail"
