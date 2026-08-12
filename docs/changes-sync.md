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
    "last_seq": "..."
  }
}
```

`reloaded` is retained as the compatibility signal that the in-memory runtime was refreshed. `full_reload` and `sync_mode` distinguish a full snapshot rebuild from an incremental changes application.

## Change handling

The synchronization path requests `_changes` with `include_docs=true` and applies changes under the existing per-KB mutex.

- matching fact/rule insert or update: validate, replace any clause from the same CouchDB `_id`, then install the new clause
- disabled matching document: remove any currently loaded clause for that `_id`
- deleted document: remove the clause for that `_id`
- document that no longer belongs to the runtime's KB/release/type: remove any old clause with that `_id` and otherwise ignore it
- unrelated database changes: ignored after advancing the checkpoint

Updates are therefore idempotent by CouchDB document ID and duplicated/replayed changes do not accumulate duplicate Prolog clauses.

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

`tests/changes_sync.sh` runs as its own required CI lane and covers:

- initial full snapshot
- incremental insert
- direct CouchDB revision update
- direct CouchDB deletion
- no-op synchronization from an up-to-date sequence
- unrelated database changes
- release switch requiring a new full snapshot
- synchronization of a previously loaded pinned release
- restart reconstruction from CouchDB
