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

assert_status() {
  local expected="$1"
  local url="$2"
  local body="$3"
  local status
  status=$(curl -sS -o /tmp/error-response.json -w '%{http_code}' \
    "$url" -H 'content-type: application/json' -d "$body")
  if [[ "$status" != "$expected" ]]; then
    cat /tmp/error-response.json >&2
    echo "expected HTTP $expected, got $status" >&2
    return 1
  fi
}

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

health=$(curl -fsS http://127.0.0.1:8080/health)
printf '%s' "$health" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"] == "ok"'

fact_response=$(curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","predicate":"human","args":["socrates"],"provenance":{"source":"integration"}}')
printf '%s' "$fact_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["couchdb"]["ok"] is True; assert d["document"]["release"] == "legacy"'

rule_response=$(curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}')
printf '%s' "$rule_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["couchdb"]["ok"] is True; assert d["document"]["release"] == "legacy"'

query_response=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$query_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 1; assert d["solutions"][0]["bindings"]["Who"] == "socrates"; assert d["release"] == "legacy"; assert d["refresh"]["reloaded"] is True'

# Prove CouchDB is the source of truth: save a new fact without refreshing the
# in-memory snapshot. refresh=false must stay stale; refresh=true must observe it.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","predicate":"human","args":["plato"]}' >/dev/null

stale=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","refresh":false,"goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$stale" | python3 -c 'import json,sys; d=json.load(sys.stdin); names={s["bindings"]["Who"] for s in d["solutions"]}; assert names == {"socrates"}; assert d["refresh"]["reloaded"] is False'

fresh=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","refresh":true,"goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$fresh" | python3 -c 'import json,sys; d=json.load(sys.stdin); names={s["bindings"]["Who"] for s in d["solutions"]}; assert names == {"socrates","plato"}; assert d["refresh"]["reloaded"] is True'

explain=$(curl -fsS http://127.0.0.1:8080/v1/explain \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$explain" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 2; assert all(len(s["sources"]) == 2 for s in d["solutions"]); assert all(all(src != "unsaved" for src in s["sources"]) for s in d["solutions"])'

knowledge=$(curl -fsS 'http://127.0.0.1:8080/v1/knowledge?kb=ci')
printf '%s' "$knowledge" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "legacy"; assert d["count"] == 3; assert {x["type"] for x in d["documents"]} == {"prolog_fact","prolog_rule"}'

# shellcheck disable=SC2016
find_response=$(curl -fsS -u admin:admin \
  http://127.0.0.1:5984/prolog_kb/_find \
  -H 'content-type: application/json' \
  -d '{"selector":{"kb":"ci","type":{"$in":["prolog_fact","prolog_rule"]}},"limit":100}')
printf '%s' "$find_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["docs"]) == 3'

# Disabled knowledge persists in CouchDB but must never enter the inference set.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","enabled":false,"predicate":"ghost","args":["hidden"]}' >/dev/null
reload=$(curl -fsS http://127.0.0.1:8080/v1/reload \
  -H 'content-type: application/json' -d '{"kb":"ci"}')
printf '%s' "$reload" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["refresh"]["release"] == "legacy"; assert d["refresh"]["documents"] == 4; assert d["refresh"]["skipped_disabled"] == 1'
ghost=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","refresh":false,"goal":{"predicate":"ghost","args":[{"var":"X"}]}}')
printf '%s' "$ghost" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 0'

# Bad ASTs and unsafe predicate syntax are rejected at the HTTP boundary.
assert_status 400 http://127.0.0.1:8080/v1/facts \
  '{"kb":"ci","predicate":"human","args":[{"var":"X"}]}'
assert_status 400 http://127.0.0.1:8080/v1/facts \
  '{"kb":"ci","predicate":"Shell","args":["id"]}'
assert_status 400 http://127.0.0.1:8080/v1/query \
  '{"kb":"ci","max_depth":0,"goal":{"predicate":"human","args":[]}}'

# Hammer the per-KB lock with concurrent refresh+query requests.
pids=()
for i in $(seq 1 12); do
  curl -fsS http://127.0.0.1:8080/v1/query \
    -H 'content-type: application/json' \
    -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}' \
    >"/tmp/concurrent-$i.json" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done
for i in $(seq 1 12); do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["count"] == 2' \
    "/tmp/concurrent-$i.json"
done

# Kill only the Prolog runtime. CouchDB survives. A refresh=false request from a
# fresh process must reconstruct the KB from persisted CouchDB documents.
docker compose restart prolog-query-server
wait_http http://127.0.0.1:8080/health
after_restart=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","refresh":false,"goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$after_restart" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"] == 2; assert d["release"] == "legacy"; assert d["refresh"]["reloaded"] is True'

# Exercise CouchDB's native external query-server path, including reduce.
curl -fsS -u admin:admin -X PUT \
  http://127.0.0.1:5984/prolog_kb/_design/by_type \
  -H 'content-type: application/json' \
  -d '{"language":"prolog","views":{"by_type":{"map":"emit(field(\"type\"), 1).","reduce":"count."}}}' \
  >/dev/null

view_response=$(curl -fsS -u admin:admin \
  'http://127.0.0.1:5984/prolog_kb/_design/by_type/_view/by_type?reduce=false')
printf '%s' "$view_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); keys=[r["key"] for r in d["rows"]]; assert keys.count("prolog_fact") == 3; assert keys.count("prolog_rule") == 1'

reduce_response=$(curl -fsS -u admin:admin \
  'http://127.0.0.1:5984/prolog_kb/_design/by_type/_view/by_type?group=true')
printf '%s' "$reduce_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); counts={r["key"]:r["value"] for r in d["rows"]}; assert counts == {"prolog_fact":3,"prolog_rule":1}'

# Versioned KB releases: staged documents are invisible to default queries until
# one manifest revision atomically changes the active release.
release_status=$(curl -fsS 'http://127.0.0.1:8080/v1/releases?kb=ci')
printf '%s' "$release_status" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["active_release"] == "legacy"; assert d["manifest"] is None; assert d["legacy_fallback"] is True'

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","release":"alpha","predicate":"human","args":["aristotle"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","release":"alpha","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}' >/dev/null

alpha_pinned=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","release":"alpha","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$alpha_pinned" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["count"] == 1; assert d["solutions"][0]["bindings"]["Who"] == "aristotle"'

legacy_default=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$legacy_default" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "legacy"; assert d["count"] == 2'

activate_alpha=$(curl -fsS http://127.0.0.1:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","release":"alpha"}')
alpha_rev=$(printf '%s' "$activate_alpha" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["rev"])')
printf '%s' "$activate_alpha" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["active_release"] == "alpha"; assert d["couchdb"]["ok"] is True'

alpha_default=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$alpha_default" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["count"] == 1; assert d["solutions"][0]["bindings"]["Who"] == "aristotle"'

# Active non-legacy releases are immutable, and implicit writes are rejected so
# callers must stage a different release explicitly.
assert_status 409 http://127.0.0.1:8080/v1/facts \
  '{"kb":"ci","release":"alpha","predicate":"human","args":["blocked-write"]}'
assert_status 400 http://127.0.0.1:8080/v1/facts \
  '{"kb":"ci","predicate":"human","args":["ambiguous-write"]}'

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","release":"beta","predicate":"human","args":["hypatia"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","release":"beta","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}' >/dev/null

alpha_still_active=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$alpha_still_active" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["solutions"][0]["bindings"]["Who"] == "aristotle"'

activate_beta_body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"ci","release":"beta","_rev":sys.argv[1]}))' "$alpha_rev")
activate_beta=$(curl -fsS http://127.0.0.1:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d "$activate_beta_body")
beta_rev=$(printf '%s' "$activate_beta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["rev"])')

# The old manifest revision is stale after the beta cutover.
stale_manifest_body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"ci","release":"alpha","_rev":sys.argv[1]}))' "$alpha_rev")
assert_status 409 http://127.0.0.1:8080/v1/releases/activate "$stale_manifest_body"

beta_default=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$beta_default" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "beta"; assert d["count"] == 1; assert d["solutions"][0]["bindings"]["Who"] == "hypatia"'

alpha_history=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","release":"alpha","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$alpha_history" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["solutions"][0]["bindings"]["Who"] == "aristotle"'

beta_knowledge=$(curl -fsS 'http://127.0.0.1:8080/v1/knowledge?kb=ci')
printf '%s' "$beta_knowledge" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "beta"; assert d["count"] == 2'
alpha_knowledge=$(curl -fsS 'http://127.0.0.1:8080/v1/knowledge?kb=ci&release=alpha')
printf '%s' "$alpha_knowledge" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["count"] == 2'

# Restart reconstruction resolves the active manifest before rebuilding the
# runtime, so beta remains active without any in-process state.
docker compose restart prolog-query-server
wait_http http://127.0.0.1:8080/health
beta_after_restart=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","refresh":false,"goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$beta_after_restart" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "beta"; assert d["refresh"]["reloaded"] is True; assert d["solutions"][0]["bindings"]["Who"] == "hypatia"'

# Rollback is another single manifest revision update; the old release remains
# queryable and becomes active again without rewriting its knowledge documents.
rollback_body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"ci","release":"alpha","_rev":sys.argv[1]}))' "$beta_rev")
curl -fsS http://127.0.0.1:8080/v1/releases/activate \
  -H 'content-type: application/json' -d "$rollback_body" >/dev/null
rollback_query=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$rollback_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"] == "alpha"; assert d["solutions"][0]["bindings"]["Who"] == "aristotle"'

echo "extended CouchDB expert-system integration suite passed"
