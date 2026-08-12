#!/usr/bin/env bash
set -euo pipefail

cleanup(){ docker compose logs --no-color || true; docker compose down -v || true; }
trap cleanup EXIT
wait_http(){ local u="$1"; shift; for _ in $(seq 1 90); do curl -fsS "$@" "$u" >/dev/null && return 0; sleep 1; done; return 1; }
status(){ local url="$1" body="$2"; curl -sS -o /tmp/analysis-response.json -w '%{http_code}' "$url" -H 'content-type: application/json' -d "$body"; }

docker compose up -d --build
wait_http http://127.0.0.1:5984/_up -u admin:admin
wait_http http://127.0.0.1:8080/health

# Valid staged release with one user dependency and one builtin dependency.
curl -fsS http://127.0.0.1:8080/v1/facts -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"alpha","predicate":"score","args":["alice",72]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"alpha","head":{"predicate":"qualified","args":[{"var":"X"}]},"body":[{"predicate":"score","args":[{"var":"X"},{"var":"S"}]},{"predicate":"gte","args":[{"var":"S"},70]}]}' >/dev/null
alpha=$(curl -fsS http://127.0.0.1:8080/v1/analyze -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"alpha"}')
printf '%s' "$alpha" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["valid"] is True; assert d["errors"]==[]; assert len(d["dependency_graph"])==1; e=d["dependency_graph"][0]; assert e["from"]=={"predicate":"qualified","arity":1}; assert e["to"]=={"predicate":"score","arity":2}; assert d["unreachable_predicates"]==[]'

activated=$(curl -fsS http://127.0.0.1:8080/v1/releases/activate -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"alpha","strict":true}')
printf '%s' "$activated" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["active_release"]=="alpha"; assert d["analysis"]["valid"] is True; assert d["couchdb"]["ok"] is True'
alpha_rev=$(printf '%s' "$activated" | python3 -c 'import json,sys; print(json.load(sys.stdin)["couchdb"]["rev"])')

# User predicate arity mismatch must fail strict activation.
curl -fsS http://127.0.0.1:8080/v1/facts -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"beta","predicate":"person","args":["alice"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"beta","head":{"predicate":"answer","args":[]},"body":[{"predicate":"person","args":["alice","extra"]}]}' >/dev/null
beta=$(curl -fsS http://127.0.0.1:8080/v1/analyze -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"beta"}')
printf '%s' "$beta" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["valid"] is False; assert "arity_mismatch" in {e["code"] for e in d["errors"]}'
beta_body=$(python3 -c 'import json,sys; print(json.dumps({"kb":"analysis-e2e","release":"beta","strict":True,"_rev":sys.argv[1]}))' "$alpha_rev")
[[ "$(status http://127.0.0.1:8080/v1/releases/activate "$beta_body")" == 409 ]]
current=$(curl -fsS 'http://127.0.0.1:8080/v1/releases?kb=analysis-e2e')
printf '%s' "$current" | python3 -c 'import json,sys; assert json.load(sys.stdin)["active_release"]=="alpha"'

# Builtin arity mismatch is an error but not an undefined-user warning.
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"builtin-bad","head":{"predicate":"answer","args":[]},"body":[{"predicate":"gte","args":[1]}]}' >/dev/null
builtin_bad=$(curl -fsS http://127.0.0.1:8080/v1/analyze -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"builtin-bad"}')
printf '%s' "$builtin_bad" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "builtin_arity_mismatch" in {e["code"] for e in d["errors"]}; assert "undefined_predicate" not in {w["code"] for w in d["warnings"]}'

# Non-stratified negation cycle is invalid and visible as an SCC diagnostic.
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"neg-cycle","head":{"predicate":"a","args":[]},"body":[{"not":{"predicate":"b","args":[]}}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"neg-cycle","head":{"predicate":"b","args":[]},"body":[{"not":{"predicate":"a","args":[]}}]}' >/dev/null
neg=$(curl -fsS http://127.0.0.1:8080/v1/analyze -H 'content-type: application/json' -d '{"kb":"analysis-e2e","release":"neg-cycle"}')
printf '%s' "$neg" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["valid"] is False; assert "non_stratified_negation" in {e["code"] for e in d["errors"]}; assert len(d["recursion"])==1 and d["recursion"][0]["negative_cycle"] is True'

# Undefined positive predicates are warnings, and strict activation is allowed.
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"warn-only","release":"alpha","head":{"predicate":"answer","args":[]},"body":[{"predicate":"missing","args":[]}]}' >/dev/null
warn=$(curl -fsS http://127.0.0.1:8080/v1/analyze -H 'content-type: application/json' -d '{"kb":"warn-only","release":"alpha"}')
printf '%s' "$warn" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["valid"] is True; codes={w["code"] for w in d["warnings"]}; assert "undefined_predicate" in codes; assert "unreachable_rule" in codes'
warn_activate=$(curl -fsS http://127.0.0.1:8080/v1/releases/activate -H 'content-type: application/json' -d '{"kb":"warn-only","release":"alpha","strict":true}')
printf '%s' "$warn_activate" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["analysis"]["valid"] is True'

# Positive recursion is reported, remains valid, and becomes reachable through a base rule.
curl -fsS http://127.0.0.1:8080/v1/facts -H 'content-type: application/json' -d '{"kb":"recursive","release":"alpha","predicate":"edge","args":["a","b"]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"recursive","release":"alpha","head":{"predicate":"path","args":[{"var":"X"},{"var":"Y"}]},"body":[{"predicate":"edge","args":[{"var":"X"},{"var":"Y"}]}]}' >/dev/null
curl -fsS http://127.0.0.1:8080/v1/rules -H 'content-type: application/json' -d '{"kb":"recursive","release":"alpha","head":{"predicate":"path","args":[{"var":"X"},{"var":"Y"}]},"body":[{"predicate":"edge","args":[{"var":"X"},{"var":"Z"}]},{"predicate":"path","args":[{"var":"Z"},{"var":"Y"}]}]}' >/dev/null
recursive=$(curl -fsS http://127.0.0.1:8080/v1/analyze -H 'content-type: application/json' -d '{"kb":"recursive","release":"alpha"}')
printf '%s' "$recursive" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["valid"] is True; assert len(d["recursion"])==1; assert d["recursion"][0]["negative_cycle"] is False; assert d["unreachable_predicates"]==[]'

echo "knowledge-base static analysis suite passed"
