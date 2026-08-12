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

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","predicate":"human","args":["socrates"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}' >/dev/null

initial=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$initial" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 1; assert d["refresh"]["sync_mode"] == "full"; assert d["refresh"]["full_reload"] is True'

plato_response=$(curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","predicate":"human","args":["plato"]}')
plato_id=$(printf '%s' "$plato_response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["id"])')
plato_rev=$(printf '%s' "$plato_response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["rev"])')

incremental_add=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$incremental_add" | python3 -c 'import json,sys; d=json.load(sys.stdin); names={s["bindings"]["Who"] for s in d["solutions"]}; assert names == {"socrates","plato"}; r=d["refresh"]; assert r["sync_mode"] == "changes"; assert r["full_reload"] is False; assert r["synced"] is True; assert r["knowledge_applied"] >= 1'

update_body=$(python3 -c 'import json,sys; print(json.dumps({"_rev":sys.argv[1],"type":"prolog_fact","kb":"sync","release":"legacy","enabled":True,"predicate":"human","args":["plato-updated"]}))' "$plato_rev")
update_response=$(curl -fsS -u admin:admin -X PUT \
  "http://127.0.0.1:5984/prolog_kb/$plato_id" \
  -H 'content-type: application/json' \
  -d "$update_body")
updated_rev=$(printf '%s' "$update_response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rev"])')

incremental_update=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$incremental_update" | python3 -c 'import json,sys; d=json.load(sys.stdin); names={s["bindings"]["Who"] for s in d["solutions"]}; assert names == {"socrates","plato-updated"}; r=d["refresh"]; assert r["sync_mode"] == "changes"; assert r["full_reload"] is False; assert r["knowledge_applied"] >= 1'

curl -fsS -u admin:admin -X DELETE \
  "http://127.0.0.1:5984/prolog_kb/$plato_id?rev=$updated_rev" >/dev/null

incremental_delete=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$incremental_delete" | python3 -c 'import json,sys; d=json.load(sys.stdin); names={s["bindings"]["Who"] for s in d["solutions"]}; assert names == {"socrates"}; r=d["refresh"]; assert r["sync_mode"] == "changes"; assert r["full_reload"] is False; assert r["knowledge_removed"] >= 1'

no_op=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$no_op" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["refresh"]; assert r["sync_mode"] == "changes"; assert r["full_reload"] is False; assert r["changes_seen"] == 0'

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"unrelated","predicate":"human","args":["elsewhere"]}' >/dev/null
unrelated=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$unrelated" | python3 -c 'import json,sys; d=json.load(sys.stdin); names={s["bindings"]["Who"] for s in d["solutions"]}; assert names == {"socrates"}; r=d["refresh"]; assert r["sync_mode"] == "changes"; assert r["ignored_changes"] >= 1'

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","release":"alpha","predicate":"human","args":["hypatia"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","release":"alpha","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","release":"alpha"}' >/dev/null

release_switch=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$release_switch" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["count"] == 1; assert d["solutions"][0]["bindings"]["Who"] == "hypatia"; r=d["refresh"]; assert r["sync_mode"] == "full"; assert r["full_reload"] is True'

legacy_pin=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","release":"legacy","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$legacy_pin" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "legacy"; assert d["count"] == 1; assert d["solutions"][0]["bindings"]["Who"] == "socrates"; assert d["refresh"]["sync_mode"] == "changes"'

docker compose restart prolog-query-server
wait_http http://127.0.0.1:8080/health
restart=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"sync","refresh":false,"goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$restart" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["solutions"][0]["bindings"]["Who"] == "hypatia"; assert d["refresh"]["sync_mode"] == "full"; assert d["refresh"]["full_reload"] is True'

echo "CouchDB incremental changes synchronization suite passed"
