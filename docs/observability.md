# Runtime observability

`prolog-query-server` exposes low-cardinality operational metrics and structured request logs without exporting knowledge content.

## Prometheus endpoint

`GET /metrics` requires read capability when API authentication is enabled.

The endpoint uses the Prometheus text exposition format and reports:

- HTTP request counts by fixed endpoint and success/error outcome
- HTTP duration count and sum by fixed endpoint
- expert-system query count, returned-solution count, and solution-limit hits
- full KB reload count
- incremental CouchDB `_changes` sync count and applied/removed change totals
- coarse API error classes
- CouchDB error and revision-conflict counts
- knowledge mutation counts by fixed mutation kind
- low-cardinality gauges for the most recent query/snapshot/sync size

## Privacy and cardinality boundary

Metrics labels are selected from fixed internal endpoint, outcome, error-class, and mutation-kind names.

Metrics never label or emit:

- predicate names
- fact values
- rule bodies
- query bindings
- CouchDB document IDs or revisions
- bearer tokens
- KB names or release IDs

This is enforced by `tests/metrics.sh`, which creates a unique secret fact value and captures its CouchDB ID, then fails if either value, the predicate name, or either bearer token appears in the metrics output.

## Request logs

Every observed HTTP request gets a generated correlation ID such as `req_42`. A structured log record is written to stderr with only:

- event name
- request ID
- fixed endpoint name
- required capability (`public`, `read`, or `write`)
- success/error outcome and HTTP status
- request duration
- Unix timestamp

Request bodies and credentials are never included.

## Query/runtime counters

A traced or ordinary query contributes the same operational counters. Proof trees and solution payloads remain in the API response only and are not copied into metrics.

`refresh.sync_mode` drives runtime counters:

- `full` increments full-snapshot reload metrics
- `changes` increments incremental synchronization and applied/removed change metrics

## Deployment

Scrape `/metrics` with a read-capability credential when `PQS_AUTH_MODE=required`. Keep the endpoint behind the same TLS boundary as the rest of the authenticated API.
