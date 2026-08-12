# Query resource limits, deadlines, and cancellation

The HTTP expert-system runtime enforces hard server-side resource ceilings around both knowledge loading and inference. Client-supplied limits can only tighten these ceilings; they cannot raise them.

## Query budget

`POST /v1/query` and `POST /v1/explain` accept a `budget` object:

```json
{
  "kb": "demo",
  "goal": {
    "predicate": "mortal",
    "args": [{"var": "Who"}]
  },
  "budget": {
    "timeout_ms": 5000,
    "max_depth": 32,
    "max_solutions": 100,
    "max_inference_steps": 100000,
    "max_proof_nodes": 10000,
    "max_proof_bytes": 1048576
  }
}
```

Precedence is deterministic:

1. a field inside `budget` wins;
2. otherwise the same top-level field is accepted for backward compatibility;
3. otherwise the configured server ceiling/default is used;
4. every requested value is clamped down to the corresponding server ceiling.

The existing top-level `max_depth` and `max_solutions` fields remain supported. Top-level `timeout_ms`, `max_inference_steps`, `max_proof_nodes`, and `max_proof_bytes` are also accepted so old clients can adopt limits incrementally.

`max_depth` preserves the existing branch-pruning behavior: branches that exceed it fail rather than turning the whole logical query into an error. Successful responses expose `limit_hits.max_depth` so callers and metrics can distinguish depth exhaustion from an ordinary logical miss. `max_solutions` returns at most the configured number and exposes an exact `limit_hits.max_solutions` flag.

Wall-clock and inference-step exhaustion are hard failures. The deadline is enforced around inference itself with SWI-Prolog's time-limit primitive, not merely at the HTTP transport layer. Inference-step accounting uses SWI-Prolog's inference-limit primitive.

A synchronous successful query includes an opaque `query_id`, the effective `budget`, `limit_hits`, and bounded `proof_usage` metadata.

## Stable resource failures

The resource boundary uses stable JSON errors and never returns a Prolog stack trace.

| Condition | HTTP | `error` |
|---|---:|---|
| wall-clock deadline | 504 | `query_timeout` |
| inference-step budget | 422 | `inference_budget_exhausted` |
| proof node/byte budget | 422 | `proof_limit_exhausted` |
| missing bounded JSON body length | 411 | `content_length_required` |
| raw HTTP request body | 413 | `payload_too_large` |
| individual knowledge document | 413 | `knowledge_document_too_large` |
| loaded KB document count | 422 | `kb_document_limit_exceeded` |
| loaded KB serialized bytes | 422 | `kb_size_limit_exceeded` |
| rule body goal count | 422 | `rule_goal_limit_exceeded` |
| async query capacity | 503 | `query_capacity_exhausted` |
| unknown query ID | 404 | `query_not_found` |
| cancellation after terminal state | 409 | `query_not_cancellable` |

Timeout example:

```json
{
  "error": "query_timeout",
  "query_id": "68ac6d44-9b67-4c7f-a20f-a56dbca0d6ef",
  "limit": {
    "timeout_ms": 5000
  }
}
```

## Cooperative cancellation

Normal HTTP requests remain synchronous by default. To make a running inference externally cancellable, submit it asynchronously:

```bash
curl -sS http://localhost:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{
    "kb": "demo",
    "async": true,
    "budget": {"timeout_ms": 5000},
    "goal": {"predicate": "mortal", "args": [{"var": "Who"}]}
  }'
```

The server returns `202` with an opaque UUID:

```json
{
  "query_id": "68ac6d44-9b67-4c7f-a20f-a56dbca0d6ef",
  "status": "queued"
}
```

Poll it with:

```text
GET /v1/query/status?id=68ac6d44-9b67-4c7f-a20f-a56dbca0d6ef
```

Cancel it with:

```bash
curl -sS http://localhost:8080/v1/query/cancel \
  -H 'content-type: application/json' \
  -d '{"query_id":"68ac6d44-9b67-4c7f-a20f-a56dbca0d6ef"}'
```

Cancellation is cooperative. The registry keeps the public UUID separate from SWI-Prolog's internal thread identifier and signals the worker at a Prolog safe point. Exceptions unwind the per-KB mutex normally; cancellation does not mutate the loaded knowledge base.

Terminal async results are retained for a bounded TTL so completed/failed/cancelled state can be observed. Cancelling an unknown ID returns deterministic `404`; cancelling an already terminal job returns deterministic `409`.

## Knowledge and request ceilings

The same hard limits protect full snapshot reloads and incremental changes synchronization. CouchDB snapshot paging accounts for each retained document while pages are fetched and stops as soon as the configured document-count, document-size, or cumulative byte ceiling would be exceeded; the existing in-memory runtime is not replaced by an oversized snapshot. Incremental upserts maintain per-document serialized-byte accounting so changes-sync cannot grow an already loaded KB past its configured document or byte ceiling.

Every JSON body handled by the API goes through one bounded reader before JSON decoding. The API requires a valid non-negative `Content-Length`; requests without bounded length are rejected with `411`. A declared body larger than `PQS_MAX_REQUEST_BYTES` is rejected with `413` before it is read or parsed. Otherwise the server reads exactly the validated byte count in octet mode and only then decodes UTF-8 JSON. This applies to facts, rules, bulk writes, document PUT/PATCH, query, explain, reload, analysis, cancellation, and release activation requests.

Proof output has independent node and serialized-byte ceilings. This implementation rejects an explanation that would exceed either ceiling; it does not return a silently truncated proof.

## Environment variables

| Variable | Default | Purpose |
|---|---:|---|
| `PQS_QUERY_TIMEOUT_MS` | `5000` | hard wall-clock query ceiling |
| `PQS_MAX_QUERY_DEPTH` | `32` | hard client-requestable depth ceiling |
| `PQS_MAX_QUERY_SOLUTIONS` | `100` | hard returned-solution ceiling |
| `PQS_MAX_INFERENCE_STEPS` | `1000000` | hard SWI inference-step ceiling |
| `PQS_MAX_PROOF_NODES` | `10000` | hard proof node ceiling |
| `PQS_MAX_PROOF_BYTES` | `1048576` | hard serialized proof-byte ceiling |
| `PQS_MAX_KB_DOCUMENTS` | `10000` | max knowledge documents per loaded KB/release |
| `PQS_MAX_KB_BYTES` | `16777216` | max serialized bytes per loaded KB/release |
| `PQS_MAX_DOCUMENT_BYTES` | `262144` | max serialized fact/rule document bytes |
| `PQS_MAX_RULE_GOALS` | `256` | max goals in one rule body |
| `PQS_MAX_REQUEST_BYTES` | `2097152` | max raw JSON request body bytes |
| `PQS_MAX_ACTIVE_QUERIES` | `8` | max queued/running/cancelling async queries |
| `PQS_QUERY_RESULT_TTL_SECONDS` | `300` | async terminal-result retention |

All resource-limit environment variables must be positive integers. Invalid configured values fail closed instead of silently selecting an unsafe value.

## Metrics and privacy

The Prometheus endpoint exports only coarse fixed-cardinality outcomes:

- `pqs_query_timeouts_total`
- `pqs_query_cancellations_total`
- `pqs_query_depth_limit_hits_total`
- `pqs_query_solution_limit_hits_total`
- `pqs_query_inference_limit_hits_total`
- `pqs_query_proof_limit_hits_total`
- `pqs_kb_size_rejections_total`
- `pqs_request_size_rejections_total`

These metrics never use query IDs, predicates, KB/release/document names, fact/rule values, or credentials as labels. Structured request logs remain payload-free.

## Security boundary

Resource control does not widen the inference language. Persisted knowledge still passes through the existing JSON AST decoder and allowlisted builtins. Rule data cannot invoke arbitrary `call/1`, module-qualified predicates, filesystem/process/network operations, or raw Prolog source.
