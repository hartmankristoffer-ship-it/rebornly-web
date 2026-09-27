#!/usr/bin/env bash
# WEB-02: erase_member against a member who is writing at the same moment.
# Two real sessions, so this cannot live in the single-transaction pgTAP file.
# Run by scripts/test-forum.sh inside its throwaway container:
#   erase_race.sh <container>
set -uo pipefail
export MSYS_NO_PATHCONV=1
C="$1"
q() { docker exec "$C" psql -U postgres -h localhost -X -v ON_ERROR_STOP=1 -qtAc "$1"; }

OWNER=10000000-0000-4000-8000-000000000001
ANN=10000000-0000-4000-8000-000000000002
BEA=10000000-0000-4000-8000-000000000003
THREAD=10000000-0000-4000-8000-0000000000aa
fail=0

q "insert into auth.users (id, email) values ('$OWNER', 'owner@race.test'), ('$ANN', 'ann@race.test'), ('$BEA', 'bea@race.test');
   insert into forum.invitations (email) values ('owner@race.test'), ('ann@race.test'), ('bea@race.test');
   insert into forum.members (user_id, display_name, rules_version, adult_confirmed_at) values
     ('$OWNER', 'Race Owner', '1.0', now()), ('$ANN', 'Ann', '1.0', now()), ('$BEA', 'Bea', '1.0', now());
   insert into forum.threads (id, category_id, author_id, title) values ('$THREAD', 4, '$OWNER', 'Race thread');
   insert into forum.posts (thread_id, author_id, is_opening, body) values ('$THREAD', '$OWNER', true, 'Opening');" \
  || { echo "not ok - race setup"; exit 1; }

as_member() {  # $1 user id, $2 SQL; one transaction that stays open for 4 s
  docker exec -i "$C" psql -U postgres -h localhost -X -qtA 2>&1 <<SQL
begin;
select set_config('request.jwt.claim.sub', '$1', true);
set local role authenticated;
$2
select pg_sleep(4);
commit;
SQL
}

# 1. The member's reply is in flight when the erasure starts: the erasure
#    must wait for it and then wipe it too.
as_member "$ANN" "select public.forum_reply('$THREAD', 'SECRET-1 written during erasure');" > /tmp/race1.out &
sleep 1.5
q "select forum.erase_member('ann@race.test')" > /dev/null
wait
# The reply must really have been written before the erasure reached it, or
# this case proves nothing.
# (set_config also prints the member's own id, so that line does not count.)
if ! grep -v "^$ANN\$" /tmp/race1.out | grep -Eq '^[0-9a-f-]{36}$'; then
  echo "not ok - the in-flight reply was never written: $(cat /tmp/race1.out)"; fail=1
fi
left=$(q "select count(*) from forum.posts where body like '%SECRET-1%'")
if [ "$left" = "0" ]; then echo "ok - a reply in flight when the erasure starts is wiped by it"
else echo "not ok - a reply in flight survived the erasure ($left left)"; fail=1; fi

# 2. The erasure holds the member (its transaction stays open): a reply the
#    member tries meanwhile must wait, then be refused, leaving nothing.
docker exec "$C" psql -U postgres -h localhost -X -qtA -c \
  "begin; select forum.erase_member('bea@race.test'); select pg_sleep(4); commit;" > /dev/null 2>&1 &
sleep 1.5
out=$(docker exec -i "$C" psql -U postgres -h localhost -X -qtA 2>&1 <<SQL
begin;
select set_config('request.jwt.claim.sub', '$BEA', true);
set local role authenticated;
select public.forum_reply('$THREAD', 'SECRET-2 written during erasure');
commit;
SQL
)
wait
left=$(q "select count(*) from forum.posts where body like '%SECRET-2%'")
if echo "$out" | grep -q "forum:not_member" && [ "$left" = "0" ]; then
  echo "ok - a reply tried while the erasure holds the member waits and is refused"
else
  echo "not ok - a reply during a held erasure was not refused (left=$left): $out"; fail=1
fi

exit "$fail"
