# Versioned knowledge-base releases

`prolog-query-server` can publish a CouchDB-backed expert-system knowledge base as an atomic logical release.

## Model

Knowledge documents may carry a `release` string:

```json
{
  "type": "prolog_fact",
  "kb": "risk",
  "release": "2026-08-11-a",
  "predicate": "exposed",
  "args": ["asset-42"]
}
```

Rules use the same `kb` + `release` pair. Documents without a release are treated as the special `legacy` release for backward compatibility.

A single CouchDB manifest document controls the default release for a KB:

```json
{
  "_id": "prolog-kb-manifest:risk",
  "type": "prolog_kb_manifest",
  "kb": "risk",
  "active_release": "2026-08-11-a"
}
```

Default queries resolve that manifest first and then load only facts/rules from the selected release. Changing one manifest revision therefore switches the logical KB atomically from the runtime's perspective.

## Stage a release

Write facts and rules with an explicit release that is not currently active:

```bash
curl -sS http://localhost:8080/v1/facts \
  -H 'content-type: application/json' \
  -d '{
    "kb": "risk",
    "release": "2026-08-11-a",
    "predicate": "exposed",
    "args": ["asset-42"]
  }'
```

```bash
curl -sS http://localhost:8080/v1/rules \
  -H 'content-type: application/json' \
  -d '{
    "kb": "risk",
    "release": "2026-08-11-a",
    "head": {
      "predicate": "needs_review",
      "args": [{"var":"X"}]
    },
    "body": [
      {
        "predicate": "exposed",
        "args": [{"var":"X"}]
      }
    ]
  }'
```

Once a non-legacy release is active, writes to that release are rejected. Create a new release for changes.

## Inspect the active release

```bash
curl -sS 'http://localhost:8080/v1/releases?kb=risk'
```

Before the first manifest exists, the response reports `active_release: "legacy"` with `legacy_fallback: true`.

## Test a staged release before activation

Pin a query to the staged release:

```bash
curl -sS http://localhost:8080/v1/query \
  -H 'content-type: application/json' \
  -d '{
    "kb": "risk",
    "release": "2026-08-11-a",
    "goal": {
      "predicate": "needs_review",
      "args": [{"var":"Who"}]
    }
  }'
```

The same `release` field can be supplied to `/v1/explain` and `/v1/reload`. `GET /v1/knowledge?kb=risk&release=2026-08-11-a` inspects a particular release.

## Activate the first release

```bash
curl -sS http://localhost:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d '{
    "kb": "risk",
    "release": "2026-08-11-a"
  }'
```

The CouchDB response contains the new manifest revision in `couchdb.rev`.

After this succeeds, default queries use `2026-08-11-a`.

## Cut over to another release

Stage the next release, then activate it using the current manifest `_rev`:

```bash
curl -sS http://localhost:8080/v1/releases/activate \
  -H 'content-type: application/json' \
  -d '{
    "kb": "risk",
    "release": "2026-08-11-b",
    "_rev": "1-current-manifest-revision"
  }'
```

CouchDB returns HTTP `409` if `_rev` is stale. This prevents two publishers from silently overwriting each other's active-release decision.

## Roll back

Rollback uses the same operation: activate an older immutable release with the current manifest revision.

The old release documents are not rewritten, so historical/pinned queries remain reproducible as long as those documents are retained.

## Consistency boundary

The release manifest gives atomic *selection* of a coherent knowledge set. CouchDB still stores individual fact/rule documents independently. Producers should therefore stage the complete release first, validate it, and only then update the manifest.

A future release-validation/static-analysis gate can be placed immediately before activation without changing this storage model.
