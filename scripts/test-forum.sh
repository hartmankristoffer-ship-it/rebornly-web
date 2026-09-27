#!/usr/bin/env bash
# WEB-02: run the forum's pgTAP suite in a throwaway supabase/postgres
# container. Nothing touches a shared database or a hosted project.
#
#   scripts/test-forum.sh            # start, test, remove the container
#   KEEP=1 scripts/test-forum.sh     # leave the container running afterwards
set -euo pipefail
export MSYS_NO_PATHCONV=1

NAME="${FORUM_TEST_CONTAINER:-rebornly-forum-test}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"   # relative paths: docker cp cannot read MSYS-style /c/... paths

# supabase/postgres 17.6.1.171, pinned by digest: the same image on Docker Hub
# and on AWS ECR Public. ECR refused CI's anonymous pulls with "toomanyrequests"
# (rebornly-web PR #15), so Docker Hub comes first, ECR second, a few tries each.
DIGEST=sha256:658d1c9b09ae4f61b8e95087b6859181b4b7d6940d769cf7b605609c8aad43e9
IMAGE="${FORUM_TEST_IMAGE:-}"
if [ -z "$IMAGE" ]; then
  for attempt in 1 2 3; do
    for ref in "supabase/postgres:17.6.1.171@$DIGEST" "public.ecr.aws/supabase/postgres:17.6.1.171@$DIGEST"; do
      if docker pull -q "$ref" >/dev/null; then IMAGE="$ref"; break 2; fi
    done
    sleep $((attempt * 20))
  done
  [ -n "$IMAGE" ] || { echo "not ok - the test image could not be pulled from Docker Hub or ECR"; exit 1; }
fi

cleanup() { [ "${KEEP:-0}" = "1" ] || docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null

# The image restarts Postgres once after its init scripts; wait until a query
# succeeds twice in a row a moment apart.
ready=0
for _ in $(seq 1 90); do
  if docker exec "$NAME" psql -U postgres -h localhost -tAc 'select 1' >/dev/null 2>&1; then
    sleep 2
    if docker exec "$NAME" psql -U postgres -h localhost -tAc 'select 1' >/dev/null 2>&1; then
      ready=1; break
    fi
  fi
  sleep 1
done
[ "$ready" = "1" ] || { echo "database did not start"; docker logs "$NAME" | tail -20; exit 1; }

for f in supabase/migrations/*.sql; do
  docker cp "$f" "$NAME:/tmp/migration.sql"
  docker exec "$NAME" psql -U postgres -h localhost -v ON_ERROR_STOP=1 -q -f /tmp/migration.sql
done

status=0
# The rules version the page shows must be the one the database accepts.
js_rules="$(grep -oE "const RULES_VERSION = '[0-9.]+'" forum/forum.js | grep -oE "[0-9]+\.[0-9]+" || true)"
sql_rules="$(grep -h -A1 "rules_version() returns text" supabase/migrations/*.sql \
             | grep -oE "select '[0-9]+\.[0-9]+'" | grep -oE "[0-9]+\.[0-9]+" | tail -1 || true)"
if [ -z "$js_rules" ] || [ "$js_rules" != "$sql_rules" ]; then
  echo "not ok - rules version mismatch: forum.js=$js_rules migration=$sql_rules"; status=1
else
  echo "ok - rules version $js_rules agrees in forum.js and the migration"
fi

for f in supabase/tests/*.test.sql; do
  docker cp "$f" "$NAME:/tmp/test.sql"
  out="$(docker exec "$NAME" psql -U postgres -h localhost -X -f /tmp/test.sql 2>&1)" || status=1
  echo "$out"
  if echo "$out" | grep -Eq '^not ok|Looks like|ERROR'; then status=1; fi
  echo "$out" | grep -Eq '^1\.\.[0-9]+' || status=1
done

# Every read-only function in a real read-only transaction, as the Data API
# runs it.
bash supabase/tests/read_only_calls.sh "$NAME" || status=1

# Two sessions at once: an erasure against a member who is writing.
bash supabase/tests/erase_race.sh "$NAME" || status=1

if [ "$status" = "0" ]; then echo "forum tests: PASS"; else echo "forum tests: FAIL"; fi
exit "$status"
