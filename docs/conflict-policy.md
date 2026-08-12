# Fail-closed CouchDB knowledge conflicts

CouchDB replication can preserve multiple leaf revisions for the same document. CouchDB still exposes a deterministic winning revision, but the expert system treats unresolved knowledge conflicts as an explicit correctness failure instead of silently reasoning from that winner.

## Default policy

The default runtime policy is fail closed for conflicted:

- `prolog_fact` documents
- `prolog_rule` documents
- KB active-release manifests

A relevant unresolved conflict causes full snapshot loading or incremental `_changes` application to fail with HTTP `409`.

`refresh:false` remains an explicit request to use an already-loaded stale snapshot; it does not synchronize CouchDB and therefore does not discover newly arrived conflicts until the next refresh.

## Conflict inventory

Use the read-capability endpoint:

```bash
curl -sS 'http://localhost:8080/v1/conflicts?kb=risk'
```

Optionally restrict fact/rule conflict scanning to one release:

```bash
curl -sS 'http://localhost:8080/v1/conflicts?kb=risk&release=2026-08-11-b'
```

The response intentionally exposes only conflict metadata:

- CouchDB document ID
- document kind (`fact`, `rule`, or `manifest`)
- release identifier when applicable
- current winning revision ID
- losing/conflicting revision IDs

It never returns predicates, arguments, rule bodies, bindings, or provenance payloads.

## Full and incremental detection

Full CouchDB knowledge snapshots request conflict metadata and reject conflicted documents before replacing the in-memory Prolog KB.

Incremental `_changes` synchronization also requests conflict metadata. If a replicated fact/rule arrives with `_conflicts`, the change is rejected before it can replace the loaded clause.

Active-release manifest reads request conflict metadata too, so a conflicted manifest cannot silently select a release for an unpinned query.

## Resolution

Resolve the CouchDB conflict by choosing the intended branch and deleting the losing leaf revisions according to normal CouchDB conflict-resolution semantics. Once `_conflicts` is empty, the next refresh can synchronize the resolved winning document and inference resumes.

The required E2E suite proves both directions:

- a conflict arriving through replication blocks an already-loaded runtime on incremental refresh
- the same conflict blocks a fresh process during full snapshot reconstruction
- deleting losing leaves clears the conflict inventory and restores inference
- a conflicted active-release manifest blocks release resolution and default querying
