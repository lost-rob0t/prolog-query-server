# prolog-query-server

A CouchDB-backed SWI-Prolog query server and expert-system runtime.

The core idea is simple: **CouchDB is the durable knowledge store; Prolog is the inference engine.** Facts and rules are ordinary CouchDB documents. A query refreshes a named knowledge base from CouchDB, compiles those documents into an isolated in-memory Prolog clause set, and executes a bounded meta-interpreter over it.

This gives you durable, replicable expert-system knowledge without storing executable `.pl` source in CouchDB or calling arbitrary Prolog predicates from JSON.

## What it supports

- CouchDB-persisted facts
- CouchDB-persisted rules
- Multiple named knowledge bases in one CouchDB database
- Safe JSON AST for variables and compound terms
- Backward chaining through a Prolog meta-interpreter
- Negation-as-failure in rule bodies
- Built-in `eq/2` and `neq/2`
- Bounded query depth and solution count
- Explanation traces that return the CouchDB document IDs used to prove a result
- Per-knowledge-base mutexes so concurrent HTTP requests do not reload the same runtime while it is being queried
- Mango index creation for `kb` + `type`
- Native CouchDB `language: "prolog"` query-server support for map/reduce views
- Docker Compose for CouchDB + the expert-system API
- Prolog unit tests and GitHub Actions CI

## Architecture

```text
                CouchDB
                  |
          prolog_fact documents
          prolog_rule documents
                  |
          POST /v1/query
                  |
          refresh KB snapshot
                  |
       safe JSON AST -> terms
                  |
        bounded meta-interpreter
                  |
       bindings + source trace
```

CouchDB remains the source of truth. By default every query refreshes the requested KB before inference. Set `"refresh": false` to reuse the current in-process snapshot.

The same repository also provides a native CouchDB external query server. CouchDB launches SWI-Prolog for design documents whose language is `prolog`; that runtime handles view map/reduce requests using a deliberately small, whitelisted Prolog DSL.

## Run it

```bash
docker compose up --build
```

Then:

```bash
curl http://localhost:8080/health
```

Default service configuration:

| Variable | Default |
|---|---|
| `PORT` | `8080` |
| `COUCHDB_URL` | `http://127.0.0.1:5984` |
| `COUCHDB_DATABASE` | `prolog_kb` |
| `COUCHDB_USER` | unset |
| `COUCHDB_PASSWORD` | unset |

## Document model

### Fact

```json
{
  "type": "prolog_fact",
  "kb": "medical-demo",
  "enabled": true,
  "predicate": "human",
  "args": ["socrates"],
  "provenance": {
    "source": "example"
  }
}
```

Facts must be ground. Variables in facts are rejected.

### Rule

Variables are represented as `{"var":"Name"}`. The same variable name inside one rule refers to the same Prolog variable.

```json
{
  "type": "prolog_rule",
  "kb": "medical-demo",
  "enabled": true,
  "head": {
    "predicate": "mortal",
    "args": [{"var": "X"}]
  },
  "body": [
    {
      "predicate": "human",
      "args": [{"var": "X"}]
    }
  ]
}
```

Negation-as-failure is represented explicitly:

```json
{
  "not": {
    "predicate": "blocked",
    "args": [{"var": "X"}]
  }
}
```

Compound terms can be represented without accepting raw Prolog source:

```json
{
  "functor": "point",
  "args": [10, 20]
}
```

An explicit Prolog atom can be represented as:

```json
{"atom": "alice"}
```

Plain JSON strings remain Prolog strings.

## Store a fact

```bash
curl -sS http://localhost:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{
    "kb": "demo",
    "predicate": "human",
    "args": ["socrates"],
    "provenance": {"source": "manual"}
  }'
```

The service adds `type: "prolog_fact"` and persists the result in CouchDB.

## Store a rule

```bash
curl -sS http://localhost:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{
    "kb": "demo",
    "head": {
      "predicate": "mortal",
      "args": [{"var": "X"}]
    },
    "body": [
      {
        "predicate": "human",
        "args": [{"var": "X"}]
      }
    ]
  }'
```

Add a second rule to show chained inference:

```bash
curl -sS http://localhost:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{
    "kb": "demo",
    "head": {
      "predicate": "needs_coffee",
      "args": [{"var": "X"}]
    },
    "body": [
      {
        "predicate": "mortal",
        "args": [{"var": "X"}]
      }
    ]
  }'
```

## Run the expert system

```bash
curl -sS http://localhost:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{
    "kb": "demo",
    "goal": {
      "predicate": "needs_coffee",
      "args": [{"var": "Who"}]
    },
    "max_depth": 32,
    "max_solutions": 100,
    "refresh": true
  }'
```

Example result:

```json
{
  "kb": "demo",
  "count": 1,
  "solutions": [
    {
      "bindings": {
        "Who": "socrates"
      }
    }
  ],
  "refresh": {
    "reloaded": true,
    "documents": 3,
    "facts": 1,
    "rules": 2,
    "skipped_disabled": 0
  }
}
```

## Explain a result

`POST /v1/explain` is the same query interface with traces forced on:

```bash
curl -sS http://localhost:8080/v1/explain \
  -H 'content-type: application/json' \
  -d '{
    "kb": "demo",
    "goal": {
      "predicate": "needs_coffee",
      "args": [{"var": "Who"}]
    }
  }'
```

Each solution contains `sources`, a proof path made from CouchDB `_id` values. This makes the expert system auditable instead of returning a bare yes/no.

## Other endpoints

- `GET /health` — server + CouchDB health
- `GET /v1/knowledge?kb=demo` — list persisted fact/rule documents for a KB
- `POST /v1/reload` with `{"kb":"demo"}` — rebuild a KB snapshot from CouchDB
- `POST /v1/query` — query a KB
- `POST /v1/explain` — query with proof-source traces

## Security boundary

This service intentionally does **not** accept raw Prolog source or arbitrary predicate calls over HTTP. JSON is converted through a small AST, predicate names are restricted to lowercase identifiers, and inference can only use stored clauses plus the explicitly implemented `eq/2` and `neq/2` built-ins.

That boundary matters if CouchDB documents come from untrusted or semi-trusted ingest pipelines.

## CouchDB semantics

Knowledge documents are normal CouchDB documents, so they keep CouchDB `_id`/`_rev` semantics and can participate in normal replication. The runtime uses Mango `_find` to retrieve all fact/rule documents for a named KB and creates the supporting JSON index automatically.

CouchDB bulk operations are not transactions across all documents, so applications that publish a large rule-set update should use ordinary CouchDB revision/version fields or an application-level release marker if they need atomic knowledge-base cutovers.

## Native CouchDB Prolog query server

This repo also implements the term **query server** in CouchDB's native sense. CouchDB can spawn `couchdb_query_server.pl` as an external language runtime and communicate with it over the newline-delimited JSON stdin/stdout query-server protocol.

The supplied CouchDB image sets:

```text
COUCHDB_QUERY_SERVER_PROLOG=/usr/bin/swipl -q -s /opt/prolog-query-server/couchdb_query_server.pl --
```

That makes design documents with `"language": "prolog"` available when using the Docker Compose stack.

Implemented protocol commands:

- `reset`
- `add_lib` (accepted and cached; the safe DSL does not execute library code)
- `add_fun`
- `map_doc`
- `reduce`
- `rereduce`
- `ddoc new` registration

Other `ddoc` execution functions currently return an explicit unsupported-function error rather than silently behaving incorrectly.

### Safe map DSL

A design-document map function is written as a **ground Prolog term**. The query server parses the term but never executes it with arbitrary `call/1`. Only a small whitelisted DSL is interpreted.

Example design document:

```bash
curl -sS -u admin:admin -X PUT \
  http://localhost:5984/prolog_kb/_design/by_type \
  -H 'content-type: application/json' \
  -d '{
    "language": "prolog",
    "views": {
      "by_type": {
        "map": "emit(field(\"type\"), field(\"_id\"))."
      }
    }
  }'
```

Query it normally through CouchDB:

```bash
curl -sS -u admin:admin \
  'http://localhost:5984/prolog_kb/_design/by_type/_view/by_type'
```

Conditional map example:

```prolog
where(
  gt(field("score"), 50),
  emit(field("name"), object([
    "score"-field("score"),
    "kind"-field("type")
  ]))
).
```

Supported map DSL forms:

```prolog
emit(KeyExpr, ValueExpr).
where(Condition, Action).
all([Action1, Action2, ...]).
```

Expressions:

```prolog
field("name")
field(["profile", "name"])
object(["name"-field("name"), "score"-field("score")])
array([field("x"), field("y")])
"literal string"
42
true
false
null
```

Conditions:

```prolog
exists(Expr)
eq(A, B)
neq(A, B)
gt(A, B)
gte(A, B)
lt(A, B)
lte(A, B)
and([Cond1, Cond2])
or([Cond1, Cond2])
not(Cond)
```

### Reduce DSL

Custom reduce functions are intentionally tiny and deterministic:

```text
sum.
count.
min.
max.
stats.
```

`count.` handles rereduce by summing partial counts. `stats.` emits and combines CouchDB-style numeric summary objects containing `sum`, `count`, `min`, `max`, and `sumsqr`.

## Why the two runtimes are separate

The native CouchDB query server is for **views/indexing and CouchDB design-language integration**. The HTTP expert-system service is for **logical inference over fact/rule documents**.

Trying to force recursive expert-system inference into the view indexer would be the wrong abstraction: CouchDB feeds view query servers one document at a time while building indexes, whereas the expert system needs a coherent set of clauses. The expert-system API therefore refreshes a KB snapshot from CouchDB before proving a goal, while CouchDB's own Prolog query server handles per-document view evaluation.

## Tests

```bash
make test
```

The unit suite covers multi-hop inference, shared variables, disabled documents, negation-as-failure, trace source IDs, fact validation, safe map execution, map object emission, reduce, rereduce, and rejection of arbitrary callable map terms.
