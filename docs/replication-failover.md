# CouchDB replication and failover

The expert system treats CouchDB as the durable source of truth, so CouchDB replication can move complete knowledge-base releases—including fact/rule documents and the active-release manifest—between sites.

`docker-compose.replication.yml` defines a two-site test topology:

- `couchdb-a` + `prolog-a`
- `couchdb-b` + `prolog-b`

Each Prolog service talks only to its local CouchDB node. Replication is performed between CouchDB nodes with CouchDB's `_replicate` API.

## What the E2E suite proves

`tests/replication_failover.sh` verifies:

1. stage and strictly activate a release on site A
2. replicate A to B
3. reconstruct the same active release and inference result on B
4. stop both CouchDB A and Prolog A
5. continue inference entirely from site B
6. stage and activate a new release on B during the outage
7. restore CouchDB A and replicate B back to A
8. restart Prolog A and reconstruct the promoted release from replicated CouchDB state
9. restart Prolog B independently and reconstruct from local CouchDB state
10. create divergent document revisions on A and B
11. replicate the divergent revision tree
12. verify CouchDB exposes `_conflicts` and the losing revision remains directly retrievable
13. replicate the conflict tree back and verify both nodes converge on the same deterministic winner

## Conflict semantics

CouchDB replication preserves conflicting leaf revisions rather than dropping the losing branch. CouchDB selects a deterministic winning revision for ordinary document reads; requesting `conflicts=true` exposes the other leaf revisions through `_conflicts`.

The current expert-system API follows the CouchDB winning revision because its normal Mango/changes reads operate on the winning document. The replication suite therefore checks conflict metadata directly at the CouchDB boundary instead of claiming that inference currently fails closed on conflicts.

A future hardening step should make unresolved CouchDB conflicts an explicit expert-system policy decision—for example, reject a conflicted KB/release until the operator resolves it, or expose a configurable conflict strategy.

## Operational implication

A failover site does not need the original Prolog process or its in-memory snapshot. Once CouchDB knowledge and manifest documents are replicated, the local Prolog service can rebuild its runtime from that replicated state.
