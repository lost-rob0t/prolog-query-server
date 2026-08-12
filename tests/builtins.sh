#!/usr/bin/env bash
set -euo pipefail

cleanup(){ docker compose logs --no-color || true; docker compose down -v || true; }
trap cleanup EXIT
wait_http(){ local u="$1"; shift; for _ in $(seq 1 90); do curl -fsS "$@" "$u" >/dev/null && return 0; sleep 1; done; return 1; }
assert_400(){ local b="$1"; local code; code=$(curl -sS -o /tmp/builtin-error.json -w '%{http_code}' http://127.0.0.1:8080/v1/query -H 'content-type: application/json' -d "$b"); [[ "$code" == 400 ]]; }

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

catalog=$(curl -fsS http://127.0.0.1:8080/v1/builtins)
printf '%s' "$catalog" | python3 -c 'import json,sys; d=json.load(sys.stdin); names={x["name"] for x in d["builtins"]}; assert {"calc","gte","is_number"} <= names; ops={x["op"] for x in d["arithmetic_operators"]}; assert {"add","sub","mul","div","mod","abs","min","max"} <= ops'

curl -fsS http://127.0.0.1:8080/v1/facts -H 'content-type: application/json' -d '{"kb":"scores","predicate":"score","args":["alice",72]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/facts -H 'content-type: application/json' -d '{"kb":"scores","predicate":"score","args":["bob",50]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"scores","head":{"predicate":"qualified","args":[{"var":"X"},{"var":"Adjusted"}]},"body":[{"predicate":"score","args":[{"var":"X"},{"var":"S"}]},{"predicate":"is_number","args":[{"var":"S"}]},{"predicate":"calc","args":[{"var":"Adjusted"},{"functor":"add","args":[{"var":"S"},10]}]},{"predicate":"gte","args":[{"var":"Adjusted"},80]},{"predicate":"lt","args":[{"var":"Adjusted"},100]}]}' >/dev/null

explain=$(curl -fsS http://127.0.0.1:8080/v1/explain -H 'content-type: application/json' -d '{"kb":"scores","goal":{"predicate":"qualified","args":[{"var":"Who"},{"var":"Adjusted"}]}}')
printf '%s' "$explain" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==1; s=d["solutions"][0]; assert s["bindings"]=={"Who":"alice","Adjusted":82}; p=[x["predicate"] for x in s["proof"]["children"] if x["kind"]=="builtin"]; assert p==["is_number","calc","gte","lt"]'

calc=$(curl -fsS http://127.0.0.1:8080/v1/query -H 'content-type: application/json' -d '{"kb":"empty","goal":{"predicate":"calc","args":[{"var":"R"},{"functor":"mul","args":[{"functor":"add","args":[2,3]},4]}]}}')
printf '%s' "$calc" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["solutions"][0]["bindings"]["R"]==20'

assert_400 '{"kb":"empty","goal":{"predicate":"calc","args":[{"var":"R"},{"functor":"div","args":[1,0]}]}}'
assert_400 '{"kb":"empty","goal":{"predicate":"calc","args":[{"var":"R"},{"functor":"shell","args":["id"]}]}}'

code=$(curl -sS -o /tmp/reserved.json -w '%{http_code}' http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"scores","head":{"predicate":"calc","args":[1,2]},"body":[]}')
[[ "$code" == 400 ]]

echo "safe builtin registry suite passed"
