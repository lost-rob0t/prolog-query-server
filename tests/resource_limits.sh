#!/usr/bin/env bash
set -euo pipefail

export PQS_QUERY_TIMEOUT_MS=5000
export PQS_MAX_QUERY_DEPTH=1000000
export PQS_MAX_QUERY_SOLUTIONS=100
export PQS_MAX_INFERENCE_STEPS=100000000
export PQS_MAX_PROOF_NODES=100
export PQS_MAX_PROOF_BYTES=8192
export PQS_MAX_KB_DOCUMENTS=3
export PQS_MAX_KB_BYTES=1200
export PQS_MAX_DOCUMENT_BYTES=1024
export PQS_MAX_RULE_GOALS=4
export PQS_MAX_REQUEST_BYTES=2048
export PQS_MAX_ACTIVE_QUERIES=2
export PQS_QUERY_RESULT_TTL_SECONDS=300

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

post_status() {
  local expected="$1" url="$2" body="$3" output="$4"
  local status
  status=$(curl -sS -o "$output" -w '%{http_code}' \
    "$url" -H 'content-type: application/json' -d "$body")
  if [[ "$status" != "$expected" ]]; then
    cat "$output" >&2 || true
    echo "expected HTTP $expected from $url, got $status" >&2
    return 1
  fi
}

wait_query_state() {
  local query_id="$1" wanted="$2" output="$3"
  for _ in $(seq 1 100); do
    curl -fsS "http://127.0.0.1:8080/v1/query/status?id=${query_id}" >"$output"
    local state
    state=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$output")
    if [[ "$state" == "$wanted" ]]; then
      return 0
    fi
    if [[ "$state" == "failed" || "$state" == "completed" || "$state" == "cancelled" ]]; then
      cat "$output" >&2
      echo "query $query_id reached terminal state $state before $wanted" >&2
      return 1
    fi
    sleep 0.05
  done
  echo "timed out waiting for query $query_id -> $wanted" >&2
  return 1
}

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

# Normal inference and nested budget precedence.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-normal","predicate":"human","args":["socrates"]}' >/dev/null
normal=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-normal","max_depth":9,"budget":{"max_depth":4,"max_solutions":10,"timeout_ms":1000},"goal":{"predicate":"human","args":[{"var":"Who"}]}}')
printf '%s' "$normal" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==1; assert d["solutions"][0]["bindings"]["Who"]=="socrates"; assert d["budget"]["max_depth"]==4; assert isinstance(d["query_id"],str) and len(d["query_id"])>=32'

# Direct recursion and mutual recursion are bounded by depth.
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-depth","head":{"predicate":"loop","args":[{"var":"X"}]},"body":[{"predicate":"loop","args":[{"var":"X"}]}]}' >/dev/null
depth=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-depth","budget":{"max_depth":4,"max_inference_steps":100000,"timeout_ms":1000},"goal":{"predicate":"loop","args":["x"]}}')
printf '%s' "$depth" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==0; assert d["limit_hits"]["max_depth"] is True'

curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-mutual","head":{"predicate":"a","args":[{"var":"X"}]},"body":[{"predicate":"b","args":[{"var":"X"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-mutual","head":{"predicate":"b","args":[{"var":"X"}]},"body":[{"predicate":"a","args":[{"var":"X"}]}]}' >/dev/null
mutual=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-mutual","budget":{"max_depth":5,"max_inference_steps":100000,"timeout_ms":1000},"goal":{"predicate":"a","args":["x"]}}')
printf '%s' "$mutual" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==0; assert d["limit_hits"]["max_depth"] is True'

# Exact solution cap detection uses one bounded probe beyond the public limit.
for who in a b c; do
  curl -fsS http://127.0.0.1:8080/v1/facts \
    -H 'content-type: application/json' \
    -d "{\"kb\":\"resource-solutions\",\"predicate\":\"item\",\"args\":[\"$who\"]}" >/dev/null
done
solutions=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-solutions","budget":{"max_solutions":2},"goal":{"predicate":"item","args":[{"var":"X"}]}}')
printf '%s' "$solutions" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==2; assert d["limit_hits"]["max_solutions"] is True'

# Timeout and inference-step exhaustion are distinct stable failures.
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-runaway","head":{"predicate":"spin","args":[{"var":"X"}]},"body":[{"predicate":"spin","args":[{"var":"X"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-runaway","predicate":"healthy","args":["yes"]}' >/dev/null
post_status 504 http://127.0.0.1:8080/v1/query \
  '{"kb":"resource-runaway","budget":{"timeout_ms":20,"max_depth":1000000,"max_inference_steps":100000000},"goal":{"predicate":"spin","args":["x"]}}' \
  /tmp/timeout.json
python3 -c 'import json; d=json.load(open("/tmp/timeout.json")); assert d["error"]=="query_timeout"; assert d["limit"]["timeout_ms"]==20; assert isinstance(d["query_id"],str)' 

healthy_after_timeout=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-runaway","goal":{"predicate":"healthy","args":["yes"]}}')
printf '%s' "$healthy_after_timeout" | python3 -c 'import json,sys; assert json.load(sys.stdin)["count"]==1'

post_status 422 http://127.0.0.1:8080/v1/query \
  '{"kb":"resource-runaway","budget":{"timeout_ms":1000,"max_depth":1000000,"max_inference_steps":100},"goal":{"predicate":"spin","args":["x"]}}' \
  /tmp/inference.json
python3 -c 'import json; d=json.load(open("/tmp/inference.json")); assert d["error"]=="inference_budget_exhausted"'

# Active external cancellation uses an opaque query ID, not the SWI thread ID.
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-cancel","head":{"predicate":"spin","args":[{"var":"X"}]},"body":[{"predicate":"spin","args":[{"var":"X"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-cancel","predicate":"healthy","args":["yes"]}' >/dev/null
post_status 202 http://127.0.0.1:8080/v1/query \
  '{"kb":"resource-cancel","async":true,"budget":{"timeout_ms":5000,"max_depth":1000000,"max_inference_steps":100000000},"goal":{"predicate":"spin","args":["x"]}}' \
  /tmp/async.json
query_id=$(python3 -c 'import json; d=json.load(open("/tmp/async.json")); assert d["status"]=="queued"; print(d["query_id"])')
post_status 202 http://127.0.0.1:8080/v1/query/cancel \
  "{\"query_id\":\"$query_id\"}" /tmp/cancel.json
wait_query_state "$query_id" cancelled /tmp/cancel-status.json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d=={"query_id":sys.argv[2],"status":"cancelled"}' /tmp/cancel-status.json "$query_id"

healthy_after_cancel=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-cancel","goal":{"predicate":"healthy","args":["yes"]}}')
printf '%s' "$healthy_after_cancel" | python3 -c 'import json,sys; assert json.load(sys.stdin)["count"]==1'

post_status 404 http://127.0.0.1:8080/v1/query/cancel \
  '{"query_id":"00000000-0000-4000-8000-000000000000"}' /tmp/cancel-unknown.json
python3 -c 'import json; assert json.load(open("/tmp/cancel-unknown.json"))["error"]=="query_not_found"'

# Completed async jobs are retained briefly and have deterministic 409 cancellation.
post_status 202 http://127.0.0.1:8080/v1/query \
  '{"kb":"resource-normal","async":true,"goal":{"predicate":"human","args":["socrates"]}}' \
  /tmp/async-complete.json
completed_id=$(python3 -c 'import json; print(json.load(open("/tmp/async-complete.json"))["query_id"])')
wait_query_state "$completed_id" completed /tmp/completed-status.json
post_status 409 http://127.0.0.1:8080/v1/query/cancel \
  "{\"query_id\":\"$completed_id\"}" /tmp/cancel-completed.json
python3 -c 'import json; d=json.load(open("/tmp/cancel-completed.json")); assert d["error"]=="query_not_cancellable"; assert d["state"]=="completed"'

# Loaded snapshot document-count and byte limits fail before runtime replacement.
for n in 1 2 3 4; do
  curl -fsS http://127.0.0.1:8080/v1/facts \
    -H 'content-type: application/json' \
    -d "{\"kb\":\"resource-count\",\"predicate\":\"v\",\"args\":[\"$n\"]}" >/dev/null
done
post_status 422 http://127.0.0.1:8080/v1/query \
  '{"kb":"resource-count","goal":{"predicate":"v","args":[{"var":"X"}]}}' /tmp/kb-count.json
python3 -c 'import json; assert json.load(open("/tmp/kb-count.json"))["error"]=="kb_document_limit_exceeded"'

payload=$(python3 -c 'print("x"*400)')
for n in 1 2 3; do
  body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"resource-bytes","predicate":"payload","args":[sys.argv[1]+sys.argv[2]]}))' "$payload" "$n")
  curl -fsS http://127.0.0.1:8080/v1/facts -H 'content-type: application/json' -d "$body" >/dev/null
done
post_status 422 http://127.0.0.1:8080/v1/query \
  '{"kb":"resource-bytes","goal":{"predicate":"payload","args":[{"var":"X"}]}}' /tmp/kb-bytes.json
python3 -c 'import json; assert json.load(open("/tmp/kb-bytes.json"))["error"]=="kb_size_limit_exceeded"'

# Individual knowledge documents and raw HTTP request bodies are independently bounded.
big_doc=$(python3 -c 'import json; print(json.dumps({"kb":"resource-doc","predicate":"payload","args":["x"*1200]}))')
post_status 413 http://127.0.0.1:8080/v1/facts "$big_doc" /tmp/document-too-large.json
python3 -c 'import json; assert json.load(open("/tmp/document-too-large.json"))["error"]=="knowledge_document_too_large"'

huge_request=$(python3 -c 'import json; print(json.dumps({"kb":"resource-request","predicate":"payload","args":["x"*3000]}))')
post_status 413 http://127.0.0.1:8080/v1/facts "$huge_request" /tmp/request-too-large.json
python3 -c 'import json; assert json.load(open("/tmp/request-too-large.json"))["error"]=="payload_too_large"'

long_rule='{"kb":"resource-rule-goals","head":{"predicate":"long","args":[]},"body":[{"predicate":"a","args":[]},{"predicate":"b","args":[]},{"predicate":"c","args":[]},{"predicate":"d","args":[]},{"predicate":"e","args":[]}]}'
post_status 422 http://127.0.0.1:8080/v1/rules "$long_rule" /tmp/rule-goals.json
python3 -c 'import json; assert json.load(open("/tmp/rule-goals.json"))["error"]=="rule_goal_limit_exceeded"'

# Explanation construction has independent node and byte ceilings.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-proof","predicate":"base","args":["x"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-proof","head":{"predicate":"mid","args":[{"var":"X"}]},"body":[{"predicate":"base","args":[{"var":"X"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-proof","head":{"predicate":"top","args":[{"var":"X"}]},"body":[{"predicate":"mid","args":[{"var":"X"}]}]}' >/dev/null
post_status 422 http://127.0.0.1:8080/v1/explain \
  '{"kb":"resource-proof","budget":{"max_proof_nodes":2},"goal":{"predicate":"top","args":["x"]}}' /tmp/proof-nodes.json
python3 -c 'import json; assert json.load(open("/tmp/proof-nodes.json"))["error"]=="proof_limit_exhausted"'
post_status 422 http://127.0.0.1:8080/v1/explain \
  '{"kb":"resource-proof","budget":{"max_proof_nodes":100,"max_proof_bytes":80},"goal":{"predicate":"top","args":["x"]}}' /tmp/proof-bytes.json
python3 -c 'import json; assert json.load(open("/tmp/proof-bytes.json"))["error"]=="proof_limit_exhausted"'

# Release activation/reload remains healthy under the new boundaries.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-release","release":"alpha","predicate":"human","args":["ada"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-release","release":"alpha","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-release","release":"alpha"}' >/dev/null
reload=$(curl -fsS http://127.0.0.1:8080/v1/reload \
  -H 'content-type: application/json' -d '{"kb":"resource-release"}')
printf '%s' "$reload" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["refresh"]["release"]=="alpha"'
release_query=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"resource-release","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$release_query" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==1; assert d["solutions"][0]["bindings"]["Who"]=="ada"'

metrics=$(curl -fsS http://127.0.0.1:8080/metrics)
for name in \
  pqs_query_timeouts_total \
  pqs_query_cancellations_total \
  pqs_query_depth_limit_hits_total \
  pqs_query_solution_limit_hits_total \
  pqs_query_inference_limit_hits_total \
  pqs_query_proof_limit_hits_total \
  pqs_kb_size_rejections_total \
  pqs_request_size_rejections_total; do
  grep -q "^${name}" <<<"$metrics"
done

# Privacy: opaque IDs may be logged, but knowledge payloads and credentials may not be.
if docker compose logs --no-color prolog-query-server | grep -E 'socrates|from-a-secret|Bearer '; then
  echo "sensitive knowledge or credential payload leaked into structured logs" >&2
  exit 1
fi

echo "query resource limits, cancellation, KB/request bounds, and proof limits passed"
