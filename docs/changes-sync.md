# Incremental CouchDB knowledge synchronization

After a knowledge-base release is loaded once, normal `refresh: true` queries synchronize it from CouchDB's `_changes` feed instead of rebuilding the runtime from a full Mango scan.

## Runtime checkpoint

Each loaded `(kb, release)` runtime stores the CouchDB database `update_seq` captured before its full snapshot load. Capturing the sequence first is deliberate: writes that race with the snapshot can be replayed on the next `_changes` synchronization rather than being missed.

A refresh response reports the path used:

```json
{
  "refresh": {
    "reloaded": true,
    "synced": true,
    "full_reload": false,
    "sync_mode": "changes",
    "changes_seen": 1,
    "knowledge_applied": 1,
    "knowledge_removed": 0,
    "ignored_changes": 0,
    "changes_batches": 1,
    "changes_batch_size": 100,
    "last_seq": "..."
  }
}
```

`reloaded` is retained as the compatibility signal that the in-memory runtime was refreshed. `full_reload` and `sync_mode` distinguish a full snapshot rebuild from an incremental changes application.

## Bounded catch-up

The synchronization path fetches `_changes` with `include_docs=true` in bounded pages rather than materializing the complete backlog. `PQS_CHANGES_BATCH_SIZE` controls the maximum requested page size and defaults to `100`.

Each page is applied under the existing per-KB mutex and inside a SWI-Prolog transaction. Runtime clause mutations, loaded-KB byte accounting, and the in-memory CouchDB checkpoint therefore commit together. The checkpoint advances to that page's `last_seq` only after the entire page succeeds.

If a later page fails validation, hits a loaded-KB resource limit, encounters a fail-closed conflict, or is cancelled, that page is rolled back and remains replayable. Pages that completed before a synchronous failure stay committed. Async queries retain the stronger outer query transaction: cancellation rolls back the query's refresh work so no cancelled query exposes a partially applied page or a checkpoint beyond unapplied changes.

Memory used for CouchDB catch-up is proportional to the configured page plus the loaded runtime, not to the total historical changes backlog. The hard `PQS_MAX_KB_DOCUMENTS`, `PQS_MAX_KB_BYTES`, per-document, and rule limits remain authoritative for every page because each matching document still passes through the normal incremental validation/capacity path.

## Change handling

For each bounded page:

- matching fact/rule insert or update: validate, replace any clause from the same CouchDB `_id`, then install the new clause
- disabled matching document: remove any currently loaded clause for that `_id`
- deleted document: remove the clause for that `_id`
- document that no longer belongs to the runtime's KB/release/type: remove any old clause with that `_id` and otherwise ignore it
- unrelated database changes: ignore them after the page commits and its checkpoint advances

Updates are idempotent by CouchDB document ID and duplicated/replayed changes do not accumulate duplicate Prolog clauses.

## Full rebuild fallback

A full snapshot is still used when:

- a `(kb, release)` has not been loaded in the current process
- the service restarts and has no in-memory checkpoint
- a default query resolves to a newly activated release
- `/v1/reload` is called explicitly
- `_changes` synchronization returns a CouchDB error

This keeps CouchDB as the durable source of truth while avoiding a full knowledge scan for normal steady-state queries.

## `refresh: false`

`refresh: false` retains the existing semantics: if the runtime is already loaded, no CouchDB synchronization is attempted. If the runtime is absent, a full snapshot is required to construct it.

## Testing

The required CI matrix covers both supported SWI-Prolog variants plus CouchDB E2E behavior. `tests/changes_sync.sh` retains the steady-state synchronization suite and `tests/changes_streaming.sh` verifies:

- multi-page catch-up with a two-row page budget
- successful-page commit followed by a later-page rollback
- replay from the last successful checkpoint after the bad document is corrected
- final inference equivalence with a fresh full reload

`tests/changes_streaming_tests.pl` deterministically verifies page checkpointing plus conflict and resource-limit rollback. `tests/cancellation_atomicity.sh` uses one-row pages and a long catch-up backlog so async cancellation exercises the changes path while preserving the existing atomicity guarantee. The existing conflict-policy required lane continues to prove unresolved replicated knowledge conflicts fail closed.
