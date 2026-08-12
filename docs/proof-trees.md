# Structured proof trees

`POST /v1/explain` returns the same variable bindings and flat `sources` list as before, plus a machine-readable `proof` tree for each solution.

## Full mode

`explanation_mode: "full"` is the default.

```json
{
  "kb": "demo",
  "explanation_mode": "full",
  "goal": {
    "predicate": "mortal",
    "args": [{"var":"Who"}]
  }
}
```

A proof node produced by a stored rule or fact contains:

- `kind`: `rule` or `fact`
- `goal`: the proved, post-unification predicate and arguments
- `source.id`: CouchDB document `_id`
- `source.rev`: CouchDB document `_rev`
- `children`: ordered subgoal proofs

Example shape:

```json
{
  "kind": "rule",
  "goal": {"predicate":"mortal","args":["socrates"]},
  "source": {"id":"rule-id","rev":"1-..."},
  "children": [
    {
      "kind": "fact",
      "goal": {"predicate":"human","args":["socrates"]},
      "source": {"id":"fact-id","rev":"1-..."},
      "children": []
    }
  ]
}
```

This ties an explanation to exact CouchDB revisions, which is useful for audit logs and reproducible expert-system decisions.

## Builtins and negation

Safe builtins appear explicitly rather than disappearing from the trace:

```json
{
  "kind": "builtin",
  "predicate": "neq",
  "goal": {"predicate":"neq","args":["alice","bob"]},
  "decision": "succeeded",
  "children": []
}
```

A successful negation-as-failure step is represented as:

```json
{
  "kind": "negation",
  "goal": {"predicate":"blocked","args":["alice"]},
  "decision": "not_provable",
  "children": []
}
```

## Compact mode

Use `explanation_mode: "compact"` when a UI only needs proof topology and source IDs.

Compact nodes keep:

- `kind`
- `predicate`
- `source` as a CouchDB ID when applicable
- `decision` for builtin/negation nodes
- `children`

They omit goal argument payloads and CouchDB revisions.

## Compatibility

The existing flat `sources` array is retained for traced queries. It contains only persisted CouchDB document IDs in proof traversal order. Builtins and successful negation steps do not add source IDs.

Queries with tracing disabled still omit both `sources` and `proof`.
