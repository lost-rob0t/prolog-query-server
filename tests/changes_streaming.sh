#!/usr/bin/env bash
set -euo pipefail

export PQS_CHANGES_BATCH_SIZE=2

cleanup() {
  docker compose logs --no-color || true
  docker compose down -v || true
}
trap cleanup EXIT

wait_http() {
  local url="$1"
  shift
  for _ in $(seq 1 90); do
    if curl -fsS "$@" "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "timed out waiting for $url" >&2
  return 1
}

put_couch_doc() {
  local id="$1" body="$2"
  curl -fsS -u admin:admin -X PUT "http://127.0.0.1:5984/prolog_kb/${id}" \
    -H 'content-type: application/json' \
    -d "$body" >/dev/null
}

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

# Establish the initial full snapshot and checkpoint before creating the backlog.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"stream-catchup","predicate":"item","args":["baseline"]}' >/dev/null
warm=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"stream-catchup","goal":{"predicate":"item","args":[{"var":"X"}]}}')
printf '%s' "$warm" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["refresh"]["sync_mode"]=="full"; assert {s["bindings"]["X"] for s in d["solutions"]}=={"baseline"}'

# Five CouchDB-only changes force three pages at batch size 2. The fourth
# document is intentionally malformed so page 1 commits while page 2 rolls back.
put_couch_doc stream-page1-a '{"type":"prolog_fact","kb":"stream-catchup","release":"legacy","enabled":true,"predicate":"item","args":["page1-a"]}'
put_couch_doc stream-page1-b '{"type":"prolog_fact","kb":"stream-catchup","release":"legacy","enabled":true,"predicate":"item","args":["page1-b"]}'
put_couch_doc stream-page2-a '{"type":"prolog_fact","kb":"stream-catchup","release":"legacy","enabled":true,"predicate":"item","args":["page2-a"]}'
put_couch_doc stream-page2-bad '{"type":"prolog_fact","kb":"stream-catchup","release":"legacy","enabled":true,"args":["page2-bad"]}'
put_couch_doc stream-page3-a '{"type":"prolog_fact","kb":"stream-catchup","release":"legacy","enabled":true,"predicate":"item","args":["page3-a"]}'

failure_code=$(curl -sS -o /tmp/stream-catchup-failure.json -w '%{http_code}' \
  http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"stream-catchup","goal":{"predicate":"item","args":[{"var":"X"}]}}')
[[ "$failure_code" != "200" ]]

# The first page is committed. The second page must be atomic: page2-a cannot
# leak even though it precedes the malformed document in that page.
partial=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"stream-catchup","refresh":false,"goal":{"predicate":"item","args":[{"var":"X"}]}}')
printf '%s' "$partial" | python3 -c 'import json,sys; d=json.load(sys.stdin); got={s["bindings"]["X"] for s in d["solutions"]}; assert got=={"baseline","page1-a","page1-b"}, got; assert d["refresh"]["sync_mode"]=="none"'

# Correct the bad CouchDB revision. The next refresh must resume from the last
# successfully committed page and replay every unapplied change.
bad=$(curl -fsS -u admin:admin http://127.0.0.1:5984/prolog_kb/stream-page2-bad)
fixed=$(printf '%s' "$bad" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"_rev":d["_rev"],"type":"prolog_fact","kb":"stream-catchup","release":"legacy","enabled":True,"predicate":"item","args":["page2-bad"]}))')
put_couch_doc stream-page2-bad "$fixed"

resumed=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"stream-catchup","goal":{"predicate":"item","args":[{"var":"X"}]}}')
printf '%s' "$resumed" | python3 -c '
import json,sys
d=json.load(sys.stdin)
got={s["bindings"]["X"] for s in d["solutions"]}
expected={"baseline","page1-a","page1-b","page2-a","page2-bad","page3-a"}
assert got==expected, got
r=d["refresh"]
assert r["sync_mode"]=="changes"
assert r["changes_batch_size"]==2
assert r["changes_batches"]>=2
'

# A fresh process performs a full reload from CouchDB truth. Its inference must
# match the result obtained through the multi-page catch-up path.
docker compose restart prolog-query-server
wait_http http://127.0.0.1:8080/health
reloaded=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"stream-catchup","refresh":false,"goal":{"predicate":"item","args":[{"var":"X"}]}}')
printf '%s' "$reloaded" | python3 -c '
import json,sys
d=json.load(sys.stdin)
got={s["bindings"]["X"] for s in d["solutions"]}
expected={"baseline","page1-a","page1-b","page2-a","page2-bad","page3-a"}
assert got==expected, got
assert d["refresh"]["sync_mode"]=="full"
'

echo "bounded CouchDB changes catch-up suite passed"
