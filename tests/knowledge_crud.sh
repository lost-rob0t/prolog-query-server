#!/usr/bin/env bash
set -euo pipefail

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

request_status() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -o /tmp/crud-response.json -w '%{http_code}' \
      -X "$method" "$url" -H 'content-type: application/json' -d "$body"
  else
    curl -sS -o /tmp/crud-response.json -w '%{http_code}' -X "$method" "$url"
  fi
}

assert_status() {
  local expected="$1"
  local method="$2"
  local url="$3"
  local body="${4:-}"
  local actual
  actual=$(request_status "$method" "$url" "$body")
  if [[ "$actual" != "$expected" ]]; then
    cat /tmp/crud-response.json >&2
    echo "expected HTTP $expected, got $actual for $method $url" >&2
    return 1
  fi
}

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

created=$(curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"crud","predicate":"human","args":["socrates"]}')
id=$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["id"])')
rev1=$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["rev"])')

fetched=$(curl -fsS "http://127.0.0.1:8080/v1/document?id=$id")
printf '%s' "$fetched" | python3 -c 'import json,sys; d=json.load(sys.stdin)["document"]; assert d["_id"] == sys.argv[1]; assert d["type"] == "prolog_fact"; assert d["kb"] == "crud"; assert d["release"] == "legacy"; assert d["args"] == ["socrates"]' "$id"

initial=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"crud","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$initial" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["solutions"][0]["bindings"]["Who"] == "socrates"'

patch_body=$(python3 -c 'import json,sys; print(json.dumps({"_id":sys.argv[1],"_rev":sys.argv[2],"args":["plato"]}))' "$id" "$rev1")
patched=$(curl -fsS -X PATCH http://127.0.0.1:8080/v1/document \
  -H 'content-type: application/json' -d "$patch_body")
rev2=$(printf '%s' "$patched" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["document"]["args"] == ["plato"]; print(d["couchdb"]["rev"])')

assert_status 409 PATCH http://127.0.0.1:8080/v1/document "$patch_body"

patched_query=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"crud","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$patched_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert {s["bindings"]["Who"] for s in d["solutions"]} == {"plato"}; assert d["refresh"]["sync_mode"] == "changes"'

disable_body=$(python3 -c 'import json,sys; print(json.dumps({"_id":sys.argv[1],"_rev":sys.argv[2],"enabled":False}))' "$id" "$rev2")
disabled=$(curl -fsS -X PATCH http://127.0.0.1:8080/v1/document \
  -H 'content-type: application/json' -d "$disable_body")
rev3=$(printf '%s' "$disabled" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["document"]["enabled"] is False; print(d["couchdb"]["rev"])')

disabled_query=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"crud","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$disabled_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 0'

put_body=$(python3 -c 'import json,sys; print(json.dumps({"_id":sys.argv[1],"_rev":sys.argv[2],"type":"prolog_fact","kb":"crud","release":"legacy","enabled":True,"predicate":"human","args":["aristotle"],"provenance":{"source":"crud-e2e"}}))' "$id" "$rev3")
put_response=$(curl -fsS -X PUT http://127.0.0.1:8080/v1/document \
  -H 'content-type: application/json' -d "$put_body")
rev4=$(printf '%s' "$put_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["document"]["args"] == ["aristotle"]; print(d["couchdb"]["rev"])')

identity_patch=$(python3 -c 'import json,sys; print(json.dumps({"_id":sys.argv[1],"_rev":sys.argv[2],"kb":"other"}))' "$id" "$rev4")
assert_status 409 PATCH http://127.0.0.1:8080/v1/document "$identity_patch"

put_query=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"crud","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$put_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert {s["bindings"]["Who"] for s in d["solutions"]} == {"aristotle"}'

assert_status 409 DELETE "http://127.0.0.1:8080/v1/document?id=$id&rev=$rev3"
deleted=$(curl -fsS -X DELETE "http://127.0.0.1:8080/v1/document?id=$id&rev=$rev4")
printf '%s' "$deleted" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["couchdb"]["ok"] is True'
assert_status 404 GET "http://127.0.0.1:8080/v1/document?id=$id"

deleted_query=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"crud","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$deleted_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 0; assert d["refresh"]["knowledge_removed"] >= 1'

bulk_create=$(curl -fsS http://127.0.0.1:8080/v1/bulk \
  -H 'content-type: application/json' \
  -d '{"documents":[{"_id":"bulk-a","type":"prolog_fact","kb":"crud","predicate":"human","args":["ada"]},{"_id":"bulk-b","type":"prolog_fact","kb":"crud","predicate":"human","args":["grace"]}]}')
printf '%s' "$bulk_create" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["results"]) == 2; assert all(r.get("ok") is True for r in d["results"])'

bulk_a=$(curl -fsS 'http://127.0.0.1:8080/v1/document?id=bulk-a')
bulk_a_rev=$(printf '%s' "$bulk_a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["document"]["_rev"])')
bulk_b=$(curl -fsS 'http://127.0.0.1:8080/v1/document?id=bulk-b')
bulk_b_rev=$(printf '%s' "$bulk_b" | python3 -c 'import json,sys; print(json.load(sys.stdin)["document"]["_rev"])')

bulk_update_body=$(python3 -c 'import json,sys; print(json.dumps({"documents":[{"_id":"bulk-a","_rev":sys.argv[1],"type":"prolog_fact","kb":"crud","release":"legacy","predicate":"human","args":["ada-updated"]},{"_id":"bulk-b","_rev":"1-stale-revision","type":"prolog_fact","kb":"crud","release":"legacy","predicate":"human","args":["should-conflict"]}]}))' "$bulk_a_rev")
bulk_update=$(curl -fsS http://127.0.0.1:8080/v1/bulk \
  -H 'content-type: application/json' -d "$bulk_update_body")
printf '%s' "$bulk_update" | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; assert r[0].get("ok") is True; assert r[1].get("error") == "conflict"'

bulk_query=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"crud","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$bulk_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert {s["bindings"]["Who"] for s in d["solutions"]} == {"ada-updated","grace"}'

assert_status 400 POST http://127.0.0.1:8080/v1/bulk \
  '{"documents":[{"type":"prolog_fact","kb":"crud","predicate":"human","args":[{"var":"X"}]}]}'

alpha_created=$(curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"locked","release":"alpha","predicate":"human","args":["immutable"]}')
alpha_id=$(printf '%s' "$alpha_created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["id"])')
alpha_rev=$(printf '%s' "$alpha_created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["rev"])')
curl -fsS http://127.0.0.1:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d '{"kb":"locked","release":"alpha"}' >/dev/null

active_patch=$(python3 -c 'import json,sys; print(json.dumps({"_id":sys.argv[1],"_rev":sys.argv[2],"enabled":False}))' "$alpha_id" "$alpha_rev")
assert_status 409 PATCH http://127.0.0.1:8080/v1/document "$active_patch"
assert_status 409 DELETE "http://127.0.0.1:8080/v1/document?id=$alpha_id&rev=$alpha_rev"

# Ensure the successful bulk update did not accidentally mutate the conflicted row.
bulk_b_after=$(curl -fsS 'http://127.0.0.1:8080/v1/document?id=bulk-b')
printf '%s' "$bulk_b_after" | python3 -c 'import json,sys; d=json.load(sys.stdin)["document"]; assert d["args"] == ["grace"]' "$bulk_b_rev"

echo "knowledge CRUD suite passed"
