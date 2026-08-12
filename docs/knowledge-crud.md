# Knowledge document CRUD

Facts and rules can be managed through revision-aware endpoints without bypassing the expert-system validation boundary.

## Read one document

```bash
curl -sS 'http://localhost:8080/v1/document?id=<couchdb-id>'
```

Only `prolog_fact` and `prolog_rule` documents are returned through this endpoint. Missing knowledge documents return HTTP `404`.

## Replace a document

`PUT /v1/document` requires the current `_id` and `_rev` plus the complete fact/rule document.

```json
{
  "_id": "abc",
  "_rev": "2-current",
  "type": "prolog_fact",
  "kb": "risk",
  "release": "legacy",
  "enabled": true,
  "predicate": "exposed",
  "args": ["asset-42"]
}
```

A stale revision returns HTTP `409` from CouchDB.

`type`, `kb`, and `release` form the document identity and cannot be changed in place.

## Patch a document

`PATCH /v1/document` requires `_id` and `_rev`; other supplied fields are merged into the current CouchDB document and the result is validated before it is written.

```json
{
  "_id": "abc",
  "_rev": "2-current",
  "enabled": false
}
```

Setting `enabled: false` is the non-destructive way to remove a fact/rule from inference while retaining its CouchDB history.

## Delete a document

```bash
curl -sS -X DELETE \
  'http://localhost:8080/v1/document?id=abc&rev=2-current'
```

The current CouchDB revision is mandatory. Stale revisions return `409`.

## Release immutability

A non-legacy release becomes immutable after it is activated. PUT, PATCH, DELETE, and bulk updates against documents in the active release return HTTP `409`.

Stage changes in a new release and atomically activate that release instead.

The `legacy` release remains mutable for backward compatibility.

## Bulk create/update

`POST /v1/bulk` accepts full knowledge documents and delegates the write to CouchDB `_bulk_docs` after validation.

```json
{
  "documents": [
    {
      "_id": "fact-a",
      "type": "prolog_fact",
      "kb": "risk",
      "predicate": "exposed",
      "args": ["asset-a"]
    },
    {
      "_id": "fact-b",
      "_rev": "3-current",
      "type": "prolog_fact",
      "kb": "risk",
      "release": "legacy",
      "predicate": "exposed",
      "args": ["asset-b"]
    }
  ]
}
```

The response preserves CouchDB's per-row results. A batch can therefore contain a successful update and a stale-revision conflict at the same time.

Malformed or unsafe fact/rule ASTs are rejected before `_bulk_docs` is invoked.

## Runtime visibility

CRUD writes are durable in CouchDB first. Loaded Prolog runtimes observe them through the normal `_changes` synchronization path on the next `refresh: true` query.
