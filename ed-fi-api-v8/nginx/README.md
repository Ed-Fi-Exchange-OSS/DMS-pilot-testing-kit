# NGINX ingress (maintainer notes)

NGINX is the kit's single HTTPS ingress. It uses the official `nginx` image (1.25.1 or later, for
`http2 on`) with no custom build. Configuration comes from two places:

1. `templates/` is rendered by the image's `20-envsubst-on-templates.sh` into `/etc/nginx/conf.d/`.
   `default.conf.template` holds the routes, the JSON log format, and the 503/504/429 handlers.
   `snippets/kit-proxy.conf.template` holds the shared `proxy_pass` and forwarded headers.
2. `entrypoint.d/40-kit-features.sh` runs next, because the image runs `/docker-entrypoint.d/` files
   in `sort -V` order. It validates the settings, checks for the certificate, and writes the toggle
   files: `conf.d/kit/*.conf` (server level) and `conf.d/kit-rate-limit.conf` (http level, only
   when rate limiting is on). A `.sh` hook runs as a child process, so it cannot export defaults
   for the template step. That is why the toggles are written as finished files and not as
   template variables. Any invalid value stops the container before NGINX starts, with a message
   naming the setting.

## Routes

| Path | Upstream | Prefix |
| --- | --- | --- |
| `/${DMS_PATH_BASE}` and `/${DMS_PATH_BASE}/` | `dms:8080` | kept (DMS runs with `PathBase`) |
| `/${DMS_PATH_BASE}/management/reload-claimsets` (POST) and `/management/view-claimsets` (GET) | `dms:8080` | kept; no special handling -- matched by the `/${DMS_PATH_BASE}/` prefix location above like any other DMS path, so it gets the same rate limiting (when `RATE_LIMIT_ENABLED=true`) as the rest of DMS traffic and is untouched by the `/data/v3` rewrite (Task 18) |
| `/${CMS_PATH_BASE}` and `/${CMS_PATH_BASE}/` | `config:8081` | kept (CMS runs with `PathBase`) |
| `/swagger/` (`/swagger` 301s) | `swagger-ui:80` | stripped; `X-Forwarded-Prefix: /swagger` |
| `/pgadmin/` (`/pgadmin` 301s) | `pgadmin:80` | kept (pgAdmin runs with `SCRIPT_NAME=/pgadmin`); WebSockets |
| `/data/v3/...` | `dms:8080` as `/${DMS_PATH_BASE}/data/...` | rewritten if enabled; else JSON 404 |
| `/nginx-health` | none | returns 200; for the container health check |
| anything else | none | JSON 404 listing the routes |

Port 80 answers every request with a 301 to `https://<host>[:HTTPS_PORT]<uri>`.

Upstream names are resolved per request through Docker's DNS (`127.0.0.11`), so NGINX starts
even when a backend is down.

## Environment contract

| Variable | Default | Used by | Notes |
| --- | --- | --- | --- |
| `HTTPS_PORT` | none (required) | template | External port: redirects, `X-Forwarded-Port`/`-Host`. |
| `DMS_PATH_BASE` | none (required) | template, script | Matches DMS `AppSettings__PathBase`. |
| `CMS_PATH_BASE` | none (required) | template | Must match the CMS path base. Single segment. |
| `DATA_V3_REWRITE_ENABLED` | `true` | script | `true` or `false`, case-insensitive. |
| `RATE_LIMIT_ENABLED` | `false` | script | `true` or `false`. Limits DMS routes (and `/data/v3`) only. |
| `RATE_LIMIT_RATE` | `50r/s` | script | `^[1-9][0-9]*r/[sm]$` |
| `RATE_LIMIT_BURST` | `100` | script | Whole number; `0` = no burst. Excess gets 429 at once. |
| `CLIENT_MAX_BODY_SIZE` | `100m` | script | NGINX size, such as `100m`. |
| `PROXY_CONNECT_TIMEOUT` | `5s` | script | NGINX time. Short, so a paused backend fails fast. |
| `PROXY_SEND_TIMEOUT` | `300s` | script | NGINX time. |
| `PROXY_READ_TIMEOUT` | `300s` | script | NGINX time. Longer requests get a JSON 504. |

"Required" means Compose must pass the variable, for example with `${DMS_PATH_BASE:-api}`. If it is
missing, `envsubst` leaves `${NAME}` in the output and the script stops with that name.

## Mounts

| Host (relative to `ed-fi-api-v8/`) | Container | Mode |
| --- | --- | --- |
| `nginx/templates` | `/etc/nginx/templates` | `ro` |
| `nginx/entrypoint.d/40-kit-features.sh` | `/docker-entrypoint.d/40-kit-features.sh` | `ro`; executable |
| `ssl` | `/ssl` | `ro`; `server.crt` and `server.key` |
| `${LOG_DIR:-./logs}/nginx` | `/var/log/nginx/kit` | read-write |

The image ignores a `.sh` hook that is not executable. Keep the Git mode at `100755`
(`git add --chmod=+x`), because this repository has `core.fileMode=false`.

## Error handling

`proxy_intercept_errors` is off, so every status and body that DMS, CMS, Swagger UI, or PGAdmin
returns passes through unchanged. That includes DMS's own 503 and problem-details responses.
`error_page` only applies to errors NGINX generates itself:

- 502 (name not resolved, or connection refused) becomes a 503 `application/problem+json` body
  naming the Compose service, with `Retry-After: 10` (FR-ROUTE-9).
- 504 (the upstream did not answer within `PROXY_READ_TIMEOUT`) stays 504, with a JSON body
  naming the service. A slow request is not an unavailable service.
- 429 from the kit's rate limit gets a JSON body and `Retry-After: 1`.

## Logging

- `/var/log/nginx/kit/access.json` has one JSON object per request (`log_format kit_json`). It
  includes the time, request and correlation IDs, client address, method, raw request URI, the
  final `uri` and `args`, status, sizes, `request_time`, the upstream service, address, status, and
  time, DMS's `Total-Count` header, whether the `/data/v3` rewrite applied, and the user agent.
  Query strings are logged, and they can contain identifiers. Authorization headers are not logged.
- `/var/log/nginx/kit/error.log` has warnings and errors. Both logs also go to `docker logs`
  (access in the image's default text format).
- The `correlationid` request header passes through to every upstream. If it is missing, NGINX
  sends `$request_id`. DMS must run with `AppSettings__CorrelationIdHeader=correlationid`.

## Certificates

`ssl/generate-certificate.sh` (bash with OpenSSL) and `ssl/generate-certificate.ps1` (PowerShell 7;
uses OpenSSL if it is on `PATH`, otherwise .NET) write `ssl/server.crt` and `ssl/server.key`. They
create RSA 2048, valid 365 days, with SANs `localhost`, `nginx`, and `127.0.0.1`, as an end-entity
certificate for server authentication. They refuse to overwrite unless given `--force` or `-Force`.
The TLS configuration is TLS 1.2 and 1.3 only, with no `dhparam`. HSTS is not sent, because
browsers would then remember it for every `localhost` port.

## Validation status

Tested without Docker: the pinned `nginx:1.28.0-alpine` root file system was run under a user
namespace, with a stub DNS server on `127.0.0.11` and stub backends. Tested behavior:

- routing, forwarded headers, and correlation IDs
- the `/data/v3` rewrite on and off, and rate limiting with and without burst
- 503 for an unresolvable host and for a refused connection; 504 on timeout; pass-through of
  backend 502 and 503 responses
- redirects that keep a non-443 port; HTTP/2; a 2 MB request body
- every validation failure, and a missing certificate
- that every access log line parses as JSON
- both certificate scripts (OpenSSL and .NET paths), with Python 3.14 strict X.509 verification

Not tested:

- real DMS, CMS, Swagger UI, and PGAdmin behind the proxy. In particular, Discovery URLs with a
  non-443 `HTTPS_PORT`: `X-Forwarded-Host` then includes the port, and `X-Forwarded-Port` is also
  sent.
- PGAdmin WebSockets
- Docker Desktop on Windows and macOS: bind-mount permissions for the hook and the log directory
- `generate-certificate.ps1` on Windows. It was run with PowerShell 7 on Linux only.
