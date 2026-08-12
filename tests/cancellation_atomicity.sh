#!/usr/bin/env bash
set -euo pipefail

export PQS_QUERY_TIMEOUT_MS=5000
export PQS_MAX_QUERY_DEPTH=1000000
export PQS_MAX_QUERY_SOLUTIONS=100
export PQS_MAX_INFERENCE_STEPS=100000000
export PQS_MAX_PROOF_NODES=1000
export PQS_MAX_PROOF_BYTES=1048576
export PQS_MAX_KB_DOCUMENTS=10
export PQS_MAX_KB_BYTES=1048576
export PQS_MAX_DOCUMENT_BYTES=65536
export PQS_MAX_RULE_GOALS=32
export PQS_MAX_REQUEST_BYTES=1048576
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

wait_state() {
  local query_id="$1" wanted="$2" output="$3"
  for _ in $(seq 1 100); do
    curl -fsS "http://127.0.0.1:8080/v1/query/status?id=${query_id}" >"$output"
    local state
    state=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$output")
    if [[ "$state" == "$wanted" ]]; then
      return 0
    fi
    if [[ "$state" == "completed" || "$state" == "failed" || "$state" == "cancelled" ]]; then
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

# Load a stable two-document runtime first.
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","head":{"predicate":"spin","args":[{"var":"X"}]},"body":[{"predicate":"spin","args":[{"var":"X"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","predicate":"healthy","args":["yes"]}' >/dev/null
warm=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","goal":{"predicate":"healthy","args":["yes"]}}')
printf '%s' "$warm" | python3 -c 'import json,sys; assert json.load(sys.stdin)["count"]==1'

# Add knowledge only in CouchDB. The next async query will sync it inside the
# same transaction as the runaway inference.
curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","predicate":"transient","args":["new"]}' >/dev/null

async=$(curl -fsS -X POST http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","async":true,"budget":{"timeout_ms":5000,"max_depth":1000000,"max_inference_steps":100000000},"goal":{"predicate":"spin","args":["x"]}}')
query_id=$(printf '%s' "$async" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="queued"; print(d["query_id"])')
wait_state "$query_id" running /tmp/cancel-atomic-running.json

# Give the fast one-document changes sync time to execute before signalling the
# intentionally non-terminating inference. The enclosing transaction must roll
# the synced runtime change back when cancellation is raised.
sleep 0.1
cancel=$(curl -fsS -X POST http://127.0.0.1:8080/v1/query/cancel \
  -H 'content-type: application/json' \
  -d "{\"query_id\":\"$query_id\"}")
printf '%s' "$cancel" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="cancelling"'
wait_state "$query_id" cancelled /tmp/cancel-atomic-cancelled.json

# With refresh explicitly disabled, the pre-cancellation runtime must remain
# intact and must not contain the CouchDB-only transient fact.
old_runtime=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","refresh":false,"goal":{"predicate":"transient","args":["new"]}}')
printf '%s' "$old_runtime" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==0; assert d["refresh"]["synced"] is False'

healthy=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","refresh":false,"goal":{"predicate":"healthy","args":["yes"]}}')
printf '%s' "$healthy" | python3 -c 'import json,sys; assert json.load(sys.stdin)["count"]==1'

# A later ordinary refresh applies the pending CouchDB fact normally.
refreshed=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"cancel-atomic","goal":{"predicate":"transient","args":["new"]}}')
printf '%s' "$refreshed" | python3 -c 'import json,sys; assert json.load(sys.stdin)["count"]==1'

echo "cancellation rollback leaves the loaded KB atomic and healthy"
