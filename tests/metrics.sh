#!/usr/bin/env bash
set -euo pipefail

cleanup(){ docker compose logs --no-color || true; docker compose down -v || true; }
trap cleanup EXIT
wait_http(){ local u="$1"; shift; for _ in $(seq 1 90); do curl -fsS "$@" "$u" >/dev/null && return 0; sleep 1; done; return 1; }
auth(){ printf 'Authorization: Bearer %s' "$1"; }

export PQS_AUTH_MODE=required
export PQS_READ_TOKEN='metrics-reader-token-2ea97470'
export PQS_WRITE_TOKEN='metrics-writer-token-3d09815a'
docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

secret='TOP-SECRET-METRIC-VALUE-7d361e'
first=$(curl -fsS http://127.0.0.1:8080/v1/facts \
  -H "$(auth "$PQS_WRITE_TOKEN")" \
  -H 'content-type: application/json' \
  -d "{\"kb\":\"metrics-e2e\",\"predicate\":\"private_fact\",\"args\":[\"$secret\"]}")
first_id=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["id"])')
first_rev=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["rev"])')

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H "$(auth "$PQS_WRITE_TOKEN")" \
  -H 'content-type: application/json' \
  -d '{"kb":"metrics-e2e","predicate":"private_fact","args":["second"]}' >/dev/null

q1=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H "$(auth "$PQS_READ_TOKEN")" \
  -H 'content-type: application/json' \
  -d '{"kb":"metrics-e2e","max_solutions":1,"goal":{"predicate":"private_fact","args":[{"var":"X"}]}}')
printf '%s' "$q1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==1; assert d["refresh"]["sync_mode"]=="full"'

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H "$(auth "$PQS_WRITE_TOKEN")" \
  -H 'content-type: application/json' \
  -d '{"kb":"metrics-e2e","predicate":"private_fact","args":["third"]}' >/dev/null

q2=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H "$(auth "$PQS_READ_TOKEN")" \
  -H 'content-type: application/json' \
  -d '{"kb":"metrics-e2e","max_solutions":1,"goal":{"predicate":"private_fact","args":[{"var":"X"}]}}')
printf '%s' "$q2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==1; assert d["refresh"]["sync_mode"]=="changes"; assert d["refresh"]["changes_seen"]>=1'

patch_body=$(python3 -c 'import json,sys; print(json.dumps({"_id":sys.argv[1],"_rev":sys.argv[2],"args":["updated"]}))' "$first_id" "$first_rev")
patched=$(curl -fsS -X PATCH http://127.0.0.1:8080/v1/document \
  -H "$(auth "$PQS_WRITE_TOKEN")" \
  -H 'content-type: application/json' \
  -d "$patch_body")
printf '%s' "$patched" | python3 -c 'import json,sys; assert json.load(sys.stdin)["couchdb"]["ok"] is True'

conflict_code=$(curl -sS -o /tmp/metrics-conflict.json -w '%{http_code}' \
  -X PATCH http://127.0.0.1:8080/v1/document \
  -H "$(auth "$PQS_WRITE_TOKEN")" \
  -H 'content-type: application/json' \
  -d "$patch_body")
[[ "$conflict_code" == 409 ]]

bad_code=$(curl -sS -o /tmp/metrics-bad.json -w '%{http_code}' \
  http://127.0.0.1:8080/v1/query \
  -H "$(auth "$PQS_READ_TOKEN")" \
  -H 'content-type: application/json' \
  -d '{"kb":"metrics-e2e","max_depth":0,"goal":{"predicate":"private_fact","args":[]}}')
[[ "$bad_code" == 400 ]]

metrics=$(curl -fsS http://127.0.0.1:8080/metrics -H "$(auth "$PQS_READ_TOKEN")")
printf '%s' "$metrics" > /tmp/pqs-metrics.txt

python3 - "$secret" "$first_id" "$PQS_READ_TOKEN" "$PQS_WRITE_TOKEN" <<'PY'
import re, sys
text=open('/tmp/pqs-metrics.txt').read()
secret, doc_id, read_token, write_token = sys.argv[1:]

def metric(pattern):
    m=re.search(r'^'+pattern+r'\s+([0-9.eE+-]+)$', text, re.M)
    assert m, pattern
    return float(m.group(1))

assert metric(r'pqs_http_requests_total\{endpoint="query",outcome="success"\}') >= 2
assert metric(r'pqs_http_request_duration_seconds_count\{endpoint="query"\}') >= 2
assert metric(r'pqs_http_request_duration_seconds_sum\{endpoint="query"\}') >= 0
assert metric(r'pqs_query_requests_total') >= 2
assert metric(r'pqs_query_solutions_total') >= 2
assert metric(r'pqs_query_solution_limit_hits_total') >= 2
assert metric(r'pqs_kb_full_reloads_total') >= 1
assert metric(r'pqs_kb_changes_syncs_total') >= 1
assert metric(r'pqs_kb_changes_seen_total') >= 1
assert metric(r'pqs_knowledge_writes_total\{class="fact_create"\}') >= 3
assert metric(r'pqs_api_errors_total') >= 2
assert metric(r'pqs_couchdb_conflicts_total') >= 1
for forbidden in (secret, doc_id, read_token, write_token, 'private_fact'):
    assert forbidden not in text, forbidden
PY

unauth_metrics=$(curl -sS -o /tmp/metrics-unauth.json -w '%{http_code}' http://127.0.0.1:8080/metrics)
[[ "$unauth_metrics" == 401 ]]

echo "privacy-safe observability suite passed"
