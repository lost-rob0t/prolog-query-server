# Knowledge-base release static analysis

Analyze a staged CouchDB release before activation:

```bash
curl -sS http://localhost:8080/v1/analyze \
  -H 'Authorization: Bearer <read-or-write-token>' \
  -H 'content-type: application/json' \
  -d '{"kb":"risk","release":"2026-08-11-b"}'
```

The analyzer operates on enabled `prolog_fact` and `prolog_rule` documents in one `(kb, release)` and returns:

- predicate dependency edges with source document IDs and positive/negative polarity
- predicate arity consistency diagnostics
- builtin arity diagnostics
- undefined positive-predicate warnings
- recursive strongly connected components
- non-stratified negation-cycle errors
- conservative reachability from facts and zero-user-dependency rules
- unreachable predicate/rule warnings

## Errors vs warnings

A release is `valid: false` when it has structural errors that can make the rule set ambiguous or unsafe to reason about:

- a user predicate is used with multiple arities
- a registered builtin is called with the wrong arity
- a recursive strongly connected component contains a negative dependency edge

Undefined positive predicates and unreachable rules are warnings. They can be intentional while a larger system is assembled, so they do not invalidate the release by themselves.

Positive recursion is reported but allowed.

## Strict activation

Add `"strict": true` to release activation:

```json
{
  "kb": "risk",
  "release": "2026-08-11-b",
  "_rev": "2-current-manifest-rev",
  "strict": true
}
```

Strict activation analyzes the staged release while holding the same per-KB mutex used by knowledge writes and manifest activation. If analysis contains errors, activation returns HTTP `409` and the existing active release is unchanged.

On success, the activation response includes the analysis that was used for the gate.

`strict` defaults to `false` for backward compatibility.
