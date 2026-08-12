#!/usr/bin/env bash
set -euo pipefail

output=$(
  printf '%s\n' \
    '["reset"]' \
    '["add_fun","emit(field(\"type\"),field(\"_id\"))."]' \
    '["map_doc",{"_id":"doc-1","type":"person"}]' \
    '["add_fun","call(shell(\"id\"))."]' \
  | swipl -q -s couchdb_query_server.pl --
)

line1=$(printf '%s\n' "$output" | sed -n '1p')
line2=$(printf '%s\n' "$output" | sed -n '2p')
line3=$(printf '%s\n' "$output" | sed -n '3p')
line4=$(printf '%s\n' "$output" | sed -n '4p')

[[ "$line1" == "true" ]]
[[ "$line2" == "true" ]]
[[ "$line3" == '[[["person","doc-1"]]]' ]]
[[ "$line4" == *'"error"'* ]]
[[ "$line4" == *'prolog_query_server'* ]]

printf '%s\n' "query-server process protocol passed"
