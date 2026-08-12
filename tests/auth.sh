#!/usr/bin/env bash
set -euo pipefail

cleanup(){ docker compose logs --no-color || true; docker compose down -v || true; }
trap cleanup EXIT
wait_http(){ local u="$1"; shift; for _ in $(seq 1 90); do curl -fsS "$@" "$u" >/dev/null && return 0; sleep 1; done; return 1; }
status(){ local method="$1" url="$2" token="${3:-}" body="${4:-}"; local args=(-sS -o /tmp/auth-response.json -w '%{http_code}' -X "$method" "$url"); [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token"); [[ -n "$body" ]] && args+=(-H 'content-type: application/json' -d "$body"); curl "${args[@]}"; }
assert_status(){ local expected="$1"; shift; local actual; actual=$(status "$@"); if [[ "$actual" != "$expected" ]]; then cat /tmp/auth-response.json >&2; echo "expected $expected got $actual" >&2; return 1; fi; }

export PQS_AUTH_MODE=required
export PQS_READ_TOKEN='reader-test-token-8f08d44f'
export PQS_WRITE_TOKEN='writer-test-token-7ca79972'
docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

health=$(curl -fsS http://127.0.0.1:8080/health)
printf '%s' "$health" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="ok"; assert d["auth"]=={"mode":"required","configured":True,"read_token_configured":True,"write_token_configured":True}'
[[ "$health" != *"$PQS_READ_TOKEN"* ]]
[[ "$health" != *"$PQS_WRITE_TOKEN"* ]]

assert_status 401 POST http://127.0.0.1:8080/v1/query '' '{"kb":"auth","goal":{"predicate":"human","args":[]}}'
assert_status 401 POST http://127.0.0.1:8080/v1/query wrong-token '{"kb":"auth","goal":{"predicate":"human","args":[]}}'
assert_status 403 POST http://127.0.0.1:8080/v1/facts "$PQS_READ_TOKEN" '{"kb":"auth","predicate":"human","args":["alice"]}'
assert_status 201 POST http://127.0.0.1:8080/v1/facts "$PQS_WRITE_TOKEN" '{"kb":"auth","predicate":"human","args":["alice"]}'

query_code=$(status POST http://127.0.0.1:8080/v1/query "$PQS_READ_TOKEN" '{"kb":"auth","goal":{"predicate":"human","args":[{"var":"Who"}]}}')
[[ "$query_code" == 200 ]]
python3 -c 'import json; d=json.load(open("/tmp/auth-response.json")); assert d["solutions"][0]["bindings"]["Who"]=="alice"'

assert_status 200 POST http://127.0.0.1:8080/v1/query "$PQS_WRITE_TOKEN" '{"kb":"auth","goal":{"predicate":"human","args":[{"var":"Who"}]}}'
assert_status 401 GET http://127.0.0.1:8080/v1/builtins
assert_status 200 GET http://127.0.0.1:8080/v1/builtins "$PQS_READ_TOKEN"
assert_status 200 GET 'http://127.0.0.1:8080/v1/knowledge?kb=auth' "$PQS_READ_TOKEN"

assert_status 201 POST http://127.0.0.1:8080/v1/facts "$PQS_WRITE_TOKEN" '{"kb":"release-auth","release":"alpha","predicate":"human","args":["hypatia"]}'
assert_status 403 POST http://127.0.0.1:8080/v1/releases/activate "$PQS_READ_TOKEN" '{"kb":"release-auth","release":"alpha"}'
assert_status 200 POST http://127.0.0.1:8080/v1/releases/activate "$PQS_WRITE_TOKEN" '{"kb":"release-auth","release":"alpha"}'
assert_status 200 GET 'http://127.0.0.1:8080/v1/releases?kb=release-auth' "$PQS_READ_TOKEN"

# Required mode with a missing credential is visibly degraded and secured calls fail closed.
docker compose down -v
unset PQS_WRITE_TOKEN
docker compose up -d
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health
health_degraded=$(curl -fsS http://127.0.0.1:8080/health)
printf '%s' "$health_degraded" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="degraded"; assert d["auth"]["configured"] is False; assert d["auth"]["write_token_configured"] is False'
assert_status 503 POST http://127.0.0.1:8080/v1/query "$PQS_READ_TOKEN" '{"kb":"auth","goal":{"predicate":"human","args":[]}}'

echo "API authentication and authorization suite passed"
