#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose -f docker-compose.replication.yml)
cleanup(){ "${compose[@]}" logs --no-color || true; "${compose[@]}" down -v || true; }
trap cleanup EXIT
wait_http(){ local u="$1"; shift; for _ in $(seq 1 120); do curl -fsS "$@" "$u" >/dev/null && return 0; sleep 1; done; echo "timed out waiting for $u" >&2; return 1; }
replicate_a_to_b(){ curl -fsS -u admin:admin -X POST http://127.0.0.1:5984/_replicate -H 'content-type: application/json' -d '{"source":"prolog_kb","target":"http://admin:admin@couchdb-b:5984/prolog_kb","create_target":true}'; }
replicate_b_to_a(){ curl -fsS -u admin:admin -X POST http://127.0.0.1:5985/_replicate -H 'content-type: application/json' -d '{"source":"prolog_kb","target":"http://admin:admin@couchdb-a:5984/prolog_kb","create_target":true}'; }

resolve_losing_revisions(){
  local port="$1" id="$2"
  local doc body
  doc=$(curl -fsS -u admin:admin "http://127.0.0.1:${port}/prolog_kb/${id}?conflicts=true")
  body=$(printf '%s' "$doc" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"docs":[{"_id":d["_id"],"_rev":r,"_deleted":True} for r in d.get("_conflicts",[])]}))')
  curl -fsS -u admin:admin -X POST "http://127.0.0.1:${port}/prolog_kb/_bulk_docs" -H 'content-type: application/json' -d "$body" >/dev/null
}

"${compose[@]}" up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:5985/_up -u admin:admin
wait_http http://127.0.0.1:8080/health
wait_http http://127.0.0.1:8081/health

# Start both sites from the exact same fact revision and load B's runtime.
curl -fsS http://127.0.0.1:8080/v1/bulk -H 'content-type: application/json' \
  -d '{"documents":[{"_id":"conflicted-fact","type":"prolog_fact","kb":"conflict-policy","predicate":"status","args":["base"]}]}' >/dev/null
replicate_a_to_b >/dev/null
baseline=$(curl -fsS http://127.0.0.1:8081/v1/query -H 'content-type: application/json' \
  -d '{"kb":"conflict-policy","goal":{"predicate":"status","args":[{"var":"X"}]}}')
printf '%s' "$baseline" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["solutions"][0]["bindings"]["X"]=="base"'

base=$(curl -fsS 'http://127.0.0.1:8080/v1/document?id=conflicted-fact')
base_rev=$(printf '%s' "$base" | python3 -c 'import json,sys; print(json.load(sys.stdin)["document"]["_rev"])')
patch_a=$(python3 -c 'import json,sys; print(json.dumps({"_id":"conflicted-fact","_rev":sys.argv[1],"args":["from-a-secret"]}))' "$base_rev")
patch_b=$(python3 -c 'import json,sys; print(json.dumps({"_id":"conflicted-fact","_rev":sys.argv[1],"args":["from-b-secret"]}))' "$base_rev")
curl -fsS -X PATCH http://127.0.0.1:8080/v1/document -H 'content-type: application/json' -d "$patch_a" >/dev/null
curl -fsS -X PATCH http://127.0.0.1:8081/v1/document -H 'content-type: application/json' -d "$patch_b" >/dev/null
replicate_a_to_b >/dev/null

# Inventory is metadata-only and remains available while inference fails closed.
conflicts=$(curl -fsS 'http://127.0.0.1:8081/v1/conflicts?kb=conflict-policy')
printf '%s' "$conflicts" > /tmp/conflicts.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/conflicts.json'))
assert x['count']==1
c=x['conflicts'][0]
assert c['id']=='conflicted-fact'
assert c['kind']=='fact'
assert c['release']=='legacy'
assert isinstance(c['winning_rev'],str)
assert len(c['conflicts'])>=1
text=json.dumps(x)
assert 'from-a-secret' not in text
assert 'from-b-secret' not in text
assert 'status' not in text
PY

incremental_code=$(curl -sS -o /tmp/incremental-conflict.json -w '%{http_code}' http://127.0.0.1:8081/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"conflict-policy","goal":{"predicate":"status","args":[{"var":"X"}]}}')
[[ "$incremental_code" == 409 ]]

# Restart proves initial/full snapshot loading also rejects the unresolved conflict.
"${compose[@]}" restart prolog-b
wait_http http://127.0.0.1:8081/health
full_code=$(curl -sS -o /tmp/full-conflict.json -w '%{http_code}' http://127.0.0.1:8081/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"conflict-policy","goal":{"predicate":"status","args":[{"var":"X"}]}}')
[[ "$full_code" == 409 ]]

# Delete losing leaves at CouchDB, then normal synchronization/inference resumes.
resolve_losing_revisions 5985 conflicted-fact
resolved_inventory=$(curl -fsS 'http://127.0.0.1:8081/v1/conflicts?kb=conflict-policy')
printf '%s' "$resolved_inventory" | python3 -c 'import json,sys; assert json.load(sys.stdin)["count"]==0'
resolved_doc=$(curl -fsS -u admin:admin 'http://127.0.0.1:5985/prolog_kb/conflicted-fact?conflicts=true')
winner=$(printf '%s' "$resolved_doc" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d.get("_conflicts"); print(d["args"][0])')
resolved_query=$(curl -fsS http://127.0.0.1:8081/v1/query -H 'content-type: application/json' \
  -d '{"kb":"conflict-policy","goal":{"predicate":"status","args":[{"var":"X"}]}}')
printf '%s' "$resolved_query" | python3 -c 'import json,sys; expected=sys.argv[1]; d=json.load(sys.stdin); assert d["solutions"][0]["bindings"]["X"]==expected' "$winner"

# Replicate the resolution back and prove A is no longer conflicted either.
replicate_b_to_a >/dev/null
a_inventory=$(curl -fsS 'http://127.0.0.1:8080/v1/conflicts?kb=conflict-policy')
printf '%s' "$a_inventory" | python3 -c 'import json,sys; assert json.load(sys.stdin)["count"]==0'

# Manifest conflict: two sites activate different children of the same manifest revision.
for port in 8080 8081; do
  curl -fsS "http://127.0.0.1:${port}/v1/facts" -H 'content-type: application/json' \
    -d '{"kb":"manifest-conflict","release":"alpha","predicate":"version","args":["alpha"]}' >/dev/null || true
done
# Re-establish one common alpha manifest from A.
curl -fsS http://127.0.0.1:8080/v1/releases/activate -H 'content-type: application/json' \
  -d '{"kb":"manifest-conflict","release":"alpha"}' >/dev/null
replicate_a_to_b >/dev/null
manifest=$(curl -fsS 'http://127.0.0.1:8080/v1/releases?kb=manifest-conflict')
manifest_rev=$(printf '%s' "$manifest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["manifest"]["_rev"])')

curl -fsS http://127.0.0.1:8080/v1/facts -H 'content-type: application/json' \
  -d '{"kb":"manifest-conflict","release":"beta","predicate":"version","args":["beta"]}' >/dev/null
curl -fsS http://127.0.0.1:8081/v1/facts -H 'content-type: application/json' \
  -d '{"kb":"manifest-conflict","release":"gamma","predicate":"version","args":["gamma"]}' >/dev/null
beta_body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"manifest-conflict","release":"beta","_rev":sys.argv[1]}))' "$manifest_rev")
gamma_body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"manifest-conflict","release":"gamma","_rev":sys.argv[1]}))' "$manifest_rev")
curl -fsS http://127.0.0.1:8080/v1/releases/activate -H 'content-type: application/json' -d "$beta_body" >/dev/null
curl -fsS http://127.0.0.1:8081/v1/releases/activate -H 'content-type: application/json' -d "$gamma_body" >/dev/null
replicate_a_to_b >/dev/null

manifest_inventory=$(curl -fsS 'http://127.0.0.1:8081/v1/conflicts?kb=manifest-conflict')
printf '%s' "$manifest_inventory" | python3 -c 'import json,sys; d=json.load(sys.stdin); manifests=[c for c in d["conflicts"] if c["kind"]=="manifest"]; assert len(manifests)==1; assert len(manifests[0]["conflicts"])>=1'
release_code=$(curl -sS -o /tmp/manifest-release-conflict.json -w '%{http_code}' 'http://127.0.0.1:8081/v1/releases?kb=manifest-conflict')
[[ "$release_code" == 409 ]]
default_query_code=$(curl -sS -o /tmp/manifest-query-conflict.json -w '%{http_code}' http://127.0.0.1:8081/v1/query \
  -H 'content-type: application/json' -d '{"kb":"manifest-conflict","goal":{"predicate":"version","args":[{"var":"X"}]}}')
[[ "$default_query_code" == 409 ]]

echo "fail-closed CouchDB knowledge conflict suite passed"
