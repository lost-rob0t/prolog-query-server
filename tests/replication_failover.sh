#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose -f docker-compose.replication.yml)
cleanup(){ "${compose[@]}" logs --no-color || true; "${compose[@]}" down -v || true; }
trap cleanup EXIT

wait_http(){ local u="$1"; shift; for _ in $(seq 1 120); do curl -fsS "$@" "$u" >/dev/null && return 0; sleep 1; done; echo "timed out waiting for $u" >&2; return 1; }

replicate_a_to_b(){
  curl -fsS -u admin:admin -X POST http://127.0.0.1:5984/_replicate \
    -H 'content-type: application/json' \
    -d '{"source":"http://admin:admin@couchdb-a:5984/prolog_kb","target":"http://admin:admin@couchdb-b:5984/prolog_kb","create_target":true}'
}

replicate_b_to_a(){
  curl -fsS -u admin:admin -X POST http://127.0.0.1:5985/_replicate \
    -H 'content-type: application/json' \
    -d '{"source":"http://admin:admin@couchdb-b:5984/prolog_kb","target":"http://admin:admin@couchdb-a:5984/prolog_kb","create_target":true}'
}

"${compose[@]}" up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:5985/_up -u admin:admin
wait_http http://127.0.0.1:8080/health
wait_http http://127.0.0.1:8081/health

# Stage and activate alpha on site A.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","release":"alpha","predicate":"human","args":["hypatia"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","release":"alpha","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}' >/dev/null
alpha_activation=$(curl -fsS http://127.0.0.1:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","release":"alpha","strict":true}')
printf '%s' "$alpha_activation" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["active_release"]=="alpha"; assert d["analysis"]["valid"] is True'

rep_ab=$(replicate_a_to_b)
printf '%s' "$rep_ab" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True'

# Site B reconstructs the same active release and inference from replicated docs.
b_query=$(curl -fsS http://127.0.0.1:8081/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$b_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"]=="alpha"; assert d["count"]==1; assert d["solutions"][0]["bindings"]["Who"]=="hypatia"'

b_release=$(curl -fsS 'http://127.0.0.1:8081/v1/releases?kb=replication')
printf '%s' "$b_release" | python3 -c 'import json,sys; assert json.load(sys.stdin)["active_release"]=="alpha"'

# Simulate loss of site A. B must remain fully operational from its local CouchDB.
"${compose[@]}" stop prolog-a couchdb-a
b_failover=$(curl -fsS http://127.0.0.1:8081/v1/explain \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$b_failover" | python3 -c 'import json,sys; d=json.load(sys.stdin); s=d["solutions"][0]; assert s["bindings"]["Who"]=="hypatia"; assert len(s["sources"])==2'

# Promote a new beta release while B is the surviving site.
curl -fsS http://127.0.0.1:8081/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","release":"beta","predicate":"human","args":["ada"]}' >/dev/null
curl -fsS http://127.0.0.1:8081/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","release":"beta","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}' >/dev/null
manifest=$(curl -fsS 'http://127.0.0.1:8081/v1/releases?kb=replication')
manifest_rev=$(printf '%s' "$manifest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["manifest"]["_rev"])')
beta_body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"replication","release":"beta","strict":True,"_rev":sys.argv[1]}))' "$manifest_rev")
beta_activation=$(curl -fsS http://127.0.0.1:8081/v1/releases/activate \
  -H 'content-type: application/json' -d "$beta_body")
printf '%s' "$beta_activation" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["active_release"]=="beta"; assert d["analysis"]["valid"] is True'

b_beta=$(curl -fsS http://127.0.0.1:8081/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$b_beta" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"]=="beta"; assert d["solutions"][0]["bindings"]["Who"]=="ada"'

# Restore site A and replicate the promoted state back to it.
"${compose[@]}" start couchdb-a
wait_http http://127.0.0.1:5984/_up -u admin:admin
rep_ba=$(replicate_b_to_a)
printf '%s' "$rep_ba" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True'
"${compose[@]}" start prolog-a
wait_http http://127.0.0.1:8080/health

a_after=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$a_after" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"]=="beta"; assert d["solutions"][0]["bindings"]["Who"]=="ada"'

# Restart B's Prolog process and prove the replicated CouchDB state alone reconstructs it.
"${compose[@]}" restart prolog-b
wait_http http://127.0.0.1:8081/health
b_restart=$(curl -fsS http://127.0.0.1:8081/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"replication","refresh":false,"goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$b_restart" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["release"]=="beta"; assert d["solutions"][0]["bindings"]["Who"]=="ada"; assert d["refresh"]["full_reload"] is True'

# Conflict exercise: start from a common revision, diverge it independently, then replicate.
bulk=$(curl -fsS http://127.0.0.1:8080/v1/bulk \
  -H 'content-type: application/json' \
  -d '{"documents":[{"_id":"replicated-conflict-fact","type":"prolog_fact","kb":"conflict","predicate":"status","args":["base"]}]}')
printf '%s' "$bulk" | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; assert len(r)==1 and r[0].get("ok") is True'
replicate_a_to_b >/dev/null

base_doc=$(curl -fsS 'http://127.0.0.1:8080/v1/document?id=replicated-conflict-fact')
base_rev=$(printf '%s' "$base_doc" | python3 -c 'import json,sys; print(json.load(sys.stdin)["document"]["_rev"])')

patch_a=$(python3 -c 'import json,sys; print(json.dumps({"_id":"replicated-conflict-fact","_rev":sys.argv[1],"args":["from-a"]}))' "$base_rev")
patch_b=$(python3 -c 'import json,sys; print(json.dumps({"_id":"replicated-conflict-fact","_rev":sys.argv[1],"args":["from-b"]}))' "$base_rev")
curl -fsS -X PATCH http://127.0.0.1:8080/v1/document -H 'content-type: application/json' -d "$patch_a" >/dev/null
curl -fsS -X PATCH http://127.0.0.1:8081/v1/document -H 'content-type: application/json' -d "$patch_b" >/dev/null

replicate_a_to_b >/dev/null
conflict_doc=$(curl -fsS -u admin:admin 'http://127.0.0.1:5985/prolog_kb/replicated-conflict-fact?conflicts=true')
printf '%s' "$conflict_doc" > /tmp/conflict-doc.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/conflict-doc.json'))
assert x['args'][0] in {'from-a','from-b'}
assert isinstance(x.get('_conflicts'), list) and len(x['_conflicts']) >= 1
assert all(isinstance(r,str) and '-' in r for r in x['_conflicts'])
PY
winner=$(python3 -c 'import json; print(json.load(open("/tmp/conflict-doc.json"))["args"][0])')
losing_rev=$(python3 -c 'import json; print(json.load(open("/tmp/conflict-doc.json"))["_conflicts"][0])')
loser=$(curl -fsS -u admin:admin "http://127.0.0.1:5985/prolog_kb/replicated-conflict-fact?rev=$losing_rev")
printf '%s' "$loser" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["args"][0] in {"from-a","from-b"}'

# CouchDB still has a deterministic storage winner, but inference must fail closed
# while any relevant unresolved conflict remains.
b_conflict_code=$(curl -sS -o /tmp/b-conflict-query.json -w '%{http_code}' \
  http://127.0.0.1:8081/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"conflict","goal":{"predicate":"status","args":[{"var":"X"}]}}')
[[ "$b_conflict_code" == 409 ]]

inventory=$(curl -fsS 'http://127.0.0.1:8081/v1/conflicts?kb=conflict')
printf '%s' "$inventory" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]>=1; c=next(x for x in d["conflicts"] if x["id"]=="replicated-conflict-fact"); assert len(c["conflicts"])>=1; assert "args" not in c and "predicate" not in c'

# Replicate the conflicted revision tree back and verify both CouchDB nodes converge
# on the same winner while retaining conflict metadata. Storage convergence must not
# silently change the fail-closed inference policy.
replicate_b_to_a >/dev/null
a_conflict_doc=$(curl -fsS -u admin:admin 'http://127.0.0.1:5984/prolog_kb/replicated-conflict-fact?conflicts=true')
printf '%s' "$a_conflict_doc" | python3 -c 'import json,sys; expected=sys.argv[1]; d=json.load(sys.stdin); assert d["args"][0]==expected; assert len(d.get("_conflicts",[]))>=1' "$winner"
a_conflict_code=$(curl -sS -o /tmp/a-conflict-query.json -w '%{http_code}' \
  http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"conflict","goal":{"predicate":"status","args":[{"var":"X"}]}}')
[[ "$a_conflict_code" == 409 ]]

echo "CouchDB replication, failover, failback, and fail-closed conflict suite passed"
