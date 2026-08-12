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
  for _ in $(seq 1 60); do
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

fact_response=$(curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","predicate":"human","args":["socrates"]}')
echo "$fact_response" | grep -q '"ok":true'

rule_response=$(curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}')
echo "$rule_response" | grep -q '"ok":true'

query_response=$(curl -fsS http://127.0.0.1:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{"kb":"ci","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
echo "$query_response" | grep -q '"Who":"socrates"'

curl -fsS -u admin:admin -X PUT \
  http://127.0.0.1:5984/prolog_kb/_design/by_type \
  -H 'content-type: application/json' \
  -d '{"language":"prolog","views":{"by_type":{"map":"emit(field(\"type\"), field(\"_id\"))."}}}' \
  >/dev/null

view_response=$(curl -fsS -u admin:admin \
  'http://127.0.0.1:5984/prolog_kb/_design/by_type/_view/by_type')
echo "$view_response" | grep -q '"key":"prolog_fact"'
echo "$view_response" | grep -q '"key":"prolog_rule"'

echo "integration smoke test passed"
