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
  local actual
  actual=$(curl -sS -o /tmp/proof-error.json -w '%{http_code}' \
    "$url" -H 'content-type: application/json' -d "$body")
  if [[ "$actual" != "$expected" ]]; then
    cat /tmp/proof-error.json >&2
    echo "expected HTTP $expected, got $actual" >&2
    return 1
  fi
}

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

fact=$(curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"proof-http","predicate":"human","args":["socrates"]}')
fact_id=$(printf '%s' "$fact" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["id"])')

rule=$(curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"proof-http","head":{"predicate":"mortal","args":[{"var":"X"}]},"body":[{"predicate":"human","args":[{"var":"X"}]}]}')
rule_id=$(printf '%s' "$rule" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["id"])')

full=$(curl -fsS http://127.0.0.1:8080/v1/explain \
  -H 'content-type: application/json' \
  -d '{"kb":"proof-http","explanation_mode":"full","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$full" | python3 -c '
import json,sys
fact_id,rule_id=sys.argv[1:]
d=json.load(sys.stdin)
s=d["solutions"][0]
assert s["bindings"]["Who"] == "socrates"
assert s["sources"] == [rule_id,fact_id]
p=s["proof"]
assert p["kind"] == "rule"
assert p["goal"] == {"predicate":"mortal","args":["socrates"]}
assert p["source"]["id"] == rule_id
assert isinstance(p["source"]["rev"], str) and p["source"]["rev"]
assert len(p["children"]) == 1
f=p["children"][0]
assert f["kind"] == "fact"
assert f["goal"] == {"predicate":"human","args":["socrates"]}
assert f["source"]["id"] == fact_id
assert isinstance(f["source"]["rev"], str) and f["source"]["rev"]
' "$fact_id" "$rule_id"

compact=$(curl -fsS http://127.0.0.1:8080/v1/explain \
  -H 'content-type: application/json' \
  -d '{"kb":"proof-http","explanation_mode":"compact","goal":{"predicate":"mortal","args":[{"var":"Who"}]}}')
printf '%s' "$compact" | python3 -c '
import json,sys
rule_id=sys.argv[1]
d=json.load(sys.stdin)
p=d["solutions"][0]["proof"]
assert p["kind"] == "rule"
assert p["predicate"] == "mortal"
assert p["source"] == rule_id
assert "goal" not in p
assert p["children"][0]["predicate"] == "human"
' "$rule_id"

curl -fsS http://127.0.0.1:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{"kb":"proof-decisions","predicate":"person","args":["alice"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{"kb":"proof-decisions","head":{"predicate":"eligible","args":[{"var":"X"}]},"body":[{"predicate":"person","args":[{"var":"X"}]},{"predicate":"neq","args":[{"var":"X"},"bob"]},{"not":{"predicate":"blocked","args":[{"var":"X"}]}}]}' >/dev/null

decisions=$(curl -fsS http://127.0.0.1:8080/v1/explain \
  -H 'content-type: application/json' \
  -d '{"kb":"proof-decisions","goal":{"predicate":"eligible","args":[{"var":"Who"}]}}')
printf '%s' "$decisions" | python3 -c '
import json,sys
d=json.load(sys.stdin)
p=d["solutions"][0]["proof"]
children=p["children"]
assert [c["kind"] for c in children] == ["fact","builtin","negation"]
assert children[1]["predicate"] == "neq"
assert children[1]["decision"] == "succeeded"
assert children[2]["goal"]["predicate"] == "blocked"
assert children[2]["decision"] == "not_provable"
'

assert_status 400 http://127.0.0.1:8080/v1/explain \
  '{"kb":"proof-http","explanation_mode":"verbose","goal":{"predicate":"mortal","args":["socrates"]}}'

echo "structured proof tree suite passed"
