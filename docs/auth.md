# API authentication and authorization

The service supports two modes through `PQS_AUTH_MODE`:

- `required` — default when the service is launched without explicit configuration
- `off` — explicit local-development mode

The provided Docker Compose file uses `${PQS_AUTH_MODE:-off}` so the local stack remains easy to run while a standalone/production launch fails closed by default.

## Credentials

Required mode expects two bearer tokens:

- `PQS_READ_TOKEN` — query/read capability
- `PQS_WRITE_TOKEN` — mutation capability; also accepted for reads

Example:

```bash
export PQS_AUTH_MODE=required
export PQS_READ_TOKEN='replace-with-a-random-read-token'
export PQS_WRITE_TOKEN='replace-with-a-random-write-token'
```

Send a token as:

```http
Authorization: Bearer <token>
```

Token values are never returned by the health endpoint or application responses. Comparisons hash both values with SHA-256 and compare the fixed-length digests with a constant-time loop.

## Public endpoints

- `GET /`
- `GET /health`

`/health` reports only whether required credentials are configured. Missing credentials produce `status: "degraded"`; secured API calls fail with HTTP `503` until configuration is complete.

## Read capability

A read token or write token may call:

- `POST /v1/query`
- `POST /v1/explain`
- `POST /v1/reload`
- `GET /v1/knowledge`
- `GET /v1/document`
- `GET /v1/builtins`
- `GET /v1/releases`

## Write capability

Only the write token may call:

- `POST /v1/facts`
- `POST /v1/rules`
- `PUT/PATCH/DELETE /v1/document`
- `POST /v1/bulk`
- `POST /v1/releases/activate`

A valid read token on a write endpoint receives HTTP `403`.

Missing or invalid bearer credentials receive HTTP `401`.

## TLS

Bearer tokens must be protected in transit. Put the service behind TLS in any non-loopback deployment, typically with a reverse proxy or ingress. Do not expose plaintext HTTP carrying production bearer credentials across an untrusted network.

The service deliberately does not terminate TLS itself in this version; deployment infrastructure owns certificates and HTTPS policy.
