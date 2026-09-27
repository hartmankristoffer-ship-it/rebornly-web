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

# Wait (up to 30 s) until the session named $1 is inside its pg_sleep, that
# is, has done its work and holds its locks. No fixed sleeps: a slow runner
# only makes this wait longer; it can never let a case pass without overlap.
wait_sleeping() {
  for _ in $(seq 1 150); do
    n="$(q "select count(*) from pg_stat_activity
            where application_name = '$1' and state = 'active' and query like '%pg_sleep%'")"
    [ "$n" = "1" ] && return 0
    sleep 0.2
  done
  return 1
}
ms() { date +%s%3N; }

# ---------------------------------------------------------------------------
# 1. The member's reply is in flight when the erasure starts: the erasure
#    must wait for it and then wipe it too.
# ---------------------------------------------------------------------------
out1="$(mktemp)"
docker exec -i "$C" psql -U postgres -h localhost -X -qtA > "$out1" 2>&1 <<SQL &
set application_name = 'race-ann';
begin;
select set_config('request.jwt.claim.sub', '$ANN', true);
set local role authenticated;
select public.forum_reply('$THREAD', 'SECRET-1 written during erasure');
select pg_sleep(6);
commit;
SQL
if ! wait_sleeping race-ann; then
  echo "not ok - the member's session never reached its open transaction: $(cat "$out1")"; fail=1
fi
t0=$(ms)
q "select forum.erase_member('ann@race.test')" > /dev/null
waited=$(( $(ms) - t0 ))
wait
# The reply must really have been written, and the erasure must really have
# waited for it; otherwise this case proves nothing. (set_config also prints
# the member's own id, so that line does not count as the reply.)
if ! grep -v "^$ANN\$" "$out1" | grep -Eq '^[0-9a-f-]{36}$'; then
  echo "not ok - the in-flight reply was never written: $(cat "$out1")"; fail=1
elif [ "$waited" -lt 2000 ]; then
  echo "not ok - the erasure did not wait for the member's open write (${waited} ms): nothing overlapped"; fail=1
fi
left=$(q "select count(*) from forum.posts where body like '%SECRET-1%'")
if [ "$left" = "0" ]; then
  echo "ok - a reply in flight when the erasure starts is wiped by it (the erasure waited ${waited} ms)"
else
  echo "not ok - a reply in flight survived the erasure ($left left)"; fail=1
fi
rm -f "$out1"

# ---------------------------------------------------------------------------
# 2. The erasure holds the member (its transaction stays open): a reply the
#    member tries meanwhile must wait, then be refused, leaving nothing.
# ---------------------------------------------------------------------------
docker exec -i "$C" psql -U postgres -h localhost -X -qtA > /dev/null 2>&1 <<SQL &
set application_name = 'race-erase';
begin;
select forum.erase_member('bea@race.test');
select pg_sleep(6);
commit;
SQL
if ! wait_sleeping race-erase; then echo "not ok - the erasure session never reached its open transaction"; fail=1; fi
t0=$(ms)
out=$(docker exec -i "$C" psql -U postgres -h localhost -X -qtA 2>&1 <<SQL
begin;
select set_config('request.jwt.claim.sub', '$BEA', true);
set local role authenticated;
select public.forum_reply('$THREAD', 'SECRET-2 written during erasure');
commit;
SQL
)
waited=$(( $(ms) - t0 ))
wait
left=$(q "select count(*) from forum.posts where body like '%SECRET-2%'")
if echo "$out" | grep -q "forum:not_member" && [ "$left" = "0" ] && [ "$waited" -ge 2000 ]; then
  echo "ok - a reply tried while the erasure holds the member waits (${waited} ms) and is refused"
else
  echo "not ok - a reply during a held erasure: waited ${waited} ms, left=$left: $out"; fail=1
fi

# ---------------------------------------------------------------------------
# WEB-03 fixtures: a moderator, and members with posts of their own.
# ---------------------------------------------------------------------------
MOD=10000000-0000-4000-8000-000000000004
CARL=10000000-0000-4000-8000-000000000005   # writes a post the moderator hides
DORA=10000000-0000-4000-8000-000000000006   # reports it meanwhile
EVE=10000000-0000-4000-8000-000000000007    # deletes her own post while being erased
FAY=10000000-0000-4000-8000-000000000008    # erased while Dora reports her post
P_CARL=10000000-0000-4000-8000-0000000000c1
P_EVE=10000000-0000-4000-8000-0000000000e1
P_FAY=10000000-0000-4000-8000-0000000000f1
q "insert into auth.users (id, email) values ('$MOD', 'mod@race.test'), ('$CARL', 'carl@race.test'),
     ('$DORA', 'dora@race.test'), ('$EVE', 'eve@race.test'), ('$FAY', 'fay@race.test');
   insert into forum.members (user_id, display_name, role, rules_version, adult_confirmed_at) values
     ('$MOD', 'Race Mod', 'moderator', '1.0', now()), ('$CARL', 'Carl', 'member', '1.0', now()),
     ('$DORA', 'Dora', 'member', '1.0', now()), ('$EVE', 'Eve', 'member', '1.0', now()),
     ('$FAY', 'Fay', 'member', '1.0', now());
   insert into forum.posts (id, thread_id, author_id, body) values
     ('$P_CARL', '$THREAD', '$CARL', 'Carl writes'), ('$P_EVE', '$THREAD', '$EVE', 'Eve writes'),
     ('$P_FAY', '$THREAD', '$FAY', 'Fay writes');" \
  || { echo "not ok - WEB-03 race setup"; exit 1; }

as_member() {  # $1 member id, $2 SQL: one call, as that member, in its own session
  docker exec -i "$C" psql -U postgres -h localhost -X -qtA 2>&1 <<SQL
begin;
select set_config('request.jwt.claim.sub', '$1', true) \g /dev/null
set local role authenticated;
$2;
commit;
SQL
}

# ---------------------------------------------------------------------------
# 3. A moderator is hiding a post (transaction open): a notice about it waits,
#    then sees the post hidden and is refused, so no notice stays open on a
#    hidden post without its decision.
# ---------------------------------------------------------------------------
docker exec -i "$C" psql -U postgres -h localhost -X -qtA > /dev/null 2>&1 <<SQL &
set application_name = 'race-hide';
begin;
select set_config('request.jwt.claim.sub', '$MOD', true);
set local role authenticated;
select public.forum_mod_hide_post('$P_CARL', 'Hidden while Dora reports it', 'rules', 'Forum rule 1');
select pg_sleep(6);
commit;
SQL
if ! wait_sleeping race-hide; then echo "not ok - the hiding session never reached its open transaction"; fail=1; fi
t0=$(ms)
out="$(as_member "$DORA" "select public.forum_report_post('$P_CARL', 'Dora reports Carl')")"
waited=$(( $(ms) - t0 ))
wait
open=$(q "select count(*) from forum.reports where post_id = '$P_CARL' and resolved_at is null")
if echo "$out" | grep -q "forum:not_found" && [ "$open" = "0" ] && [ "$waited" -ge 2000 ]; then
  echo "ok - a notice filed while a moderator hides the post waits (${waited} ms), and no notice is left open"
else
  echo "not ok - a notice during a hide: waited ${waited} ms, open notices=$open: $out"; fail=1
fi

# ---------------------------------------------------------------------------
# 4. The erasure holds a member: deleting their own post meanwhile (a
#    self-service write, allowed even while suspended) waits and is refused.
# ---------------------------------------------------------------------------
docker exec -i "$C" psql -U postgres -h localhost -X -qtA > /dev/null 2>&1 <<SQL &
set application_name = 'race-erase-eve';
begin;
select forum.erase_member('eve@race.test');
select pg_sleep(6);
commit;
SQL
if ! wait_sleeping race-erase-eve; then echo "not ok - the erasure of Eve never reached its open transaction"; fail=1; fi
t0=$(ms)
out="$(as_member "$EVE" "select public.forum_delete_post('$P_EVE')")"
waited=$(( $(ms) - t0 ))
wait
if echo "$out" | grep -q "forum:not_member" && [ "$waited" -ge 2000 ]; then
  echo "ok - a self-service write during a held erasure waits (${waited} ms) and is refused"
else
  echo "not ok - a self-service write during a held erasure: waited ${waited} ms: $out"; fail=1
fi

# ---------------------------------------------------------------------------
# 5. A notice about a member's post is being filed (transaction open) when
#    that member is erased: the erasure waits for it and then decides it as
#    removed, so the notifier gets a decision.
# ---------------------------------------------------------------------------
docker exec -i "$C" psql -U postgres -h localhost -X -qtA > /dev/null 2>&1 <<SQL &
set application_name = 'race-report-fay';
begin;
select set_config('request.jwt.claim.sub', '$DORA', true);
set local role authenticated;
select public.forum_report_post('$P_FAY', 'Dora reports Fay');
select pg_sleep(6);
commit;
SQL
if ! wait_sleeping race-report-fay; then echo "not ok - Dora's notice never reached its open transaction"; fail=1; fi
t0=$(ms)
q "select forum.erase_member('fay@race.test')" > /dev/null
waited=$(( $(ms) - t0 ))
wait
decided=$(q "select string_agg(coalesce(resolution_action, 'open'), ',') from forum.reports where post_id = '$P_FAY'")
if [ "$decided" = "removed" ] && [ "$waited" -ge 2000 ]; then
  echo "ok - a notice in flight when its post's author is erased is decided as removed (the erasure waited ${waited} ms)"
else
  echo "not ok - a notice in flight during an erasure: waited ${waited} ms, notices: ${decided:-none}"; fail=1
fi

exit "$fail"
