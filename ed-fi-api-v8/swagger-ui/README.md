# Swagger UI (interim)

These static files serve the Ed-Fi API v8 (DMS) OpenAPI documentation at `https://<host>/swagger/`.
They are adapted from the DMS repository's `eng/docker-compose/custom-swagger-ui` (copied into this
repo's git-ignored `dms-compose/` for reference).

**This is an interim choice** (plan Decision 7). A published Ed-Fi Swagger UI image is still being
researched and may replace this directory later.

## What changed from the DMS original

- **No host names or ports.** The original fetched `http://localhost:${DMS_HTTP_PORTS}/metadata/...`.
  All DMS URLs are now built from the page's own origin plus a configurable base path:
  `${window.location.origin}${DMS_BASE_PATH}/metadata/specifications`, which resolves to
  `https://localhost/api/metadata/specifications` behind the kit's NGINX. `DMS_HTTP_PORTS` is gone.
- **Token URL.** Each spec's OAuth2 `clientCredentials.tokenUrl` is set to
  `<origin><DMS_BASE_PATH>/oauth/token`, which is `https://localhost/api/oauth/token`.
- **Internal origins are rewritten.** A server URL, spec `endpointUri`, token URL, or "Try it out"
  request URL may point at an internal origin, for example `http://dms:8080/api/...` when
  forwarded headers aren't honored. If its path is under `DMS_BASE_PATH`, the origin is replaced
  with the page's origin. This replaces the original's `ed-fi-api-config` → `localhost` rewrite.
  The helpers live in `edfi-common-helper.js` (`dmsUrl`, `dmsTokenUrl`, `toSameOrigin`).
- Everything else is unchanged: custom fields, custom domains, route-context plugins, and the
  single-operation grouping. The tenant and route-qualifier logic stays but is inert, because the
  kit uses neither.

Because Swagger UI and DMS now share one origin, DMS needs no CORS configuration for Swagger UI.

## Variables (substituted into `index.html` at container start)

| Variable | Default | Meaning |
| --- | --- | --- |
| `DMS_BASE_PATH` | `/api` | Path of DMS on the NGINX origin. Should equal `/` + the DMS `PATH_BASE`. `/` means DMS is at the site root. Leading and trailing slashes are normalized. If empty or unsubstituted, `/api` is used. |
| `DMS_SWAGGER_UI_ENABLE_CUSTOM_DOMAINS` | `true` | `true` groups endpoints by Ed-Fi domain (`edfi-custom-domains.js`); anything else disables it. |

Only these two variables are substituted. `envsubst` is given an explicit list, so no other `$`
text in the files is touched.

## Compose service (for `compose.yml`)

Serve the files with any static NGINX image. Reuse the kit's pinned NGINX image (for example
`${NGINX_IMAGE}`) rather than adding another pin. The command below is adapted from DMS
`swagger-ui.yml`:

```yaml
  swagger-ui:
    image: ${NGINX_IMAGE}
    environment:
      DMS_BASE_PATH: ${SWAGGER_DMS_BASE_PATH:-/api}
      DMS_SWAGGER_UI_ENABLE_CUSTOM_DOMAINS: ${DMS_SWAGGER_UI_ENABLE_CUSTOM_DOMAINS:-true}
    volumes:
      - ./swagger-ui:/tmp/swagger-template:ro
    command: >
      sh -c "envsubst '$$DMS_BASE_PATH $$DMS_SWAGGER_UI_ENABLE_CUSTOM_DOMAINS'
             < /tmp/swagger-template/index.html > /usr/share/nginx/html/index.html &&
             cp /tmp/swagger-template/*.js /tmp/swagger-template/favicon.png /usr/share/nginx/html/ &&
             exec nginx -g 'daemon off;'"
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 6
      start_period: 5s
    # No ports: reachable only through the ingress at /swagger/.
```

Notes:

- `$$` escapes `$` for Compose, so `envsubst` receives the literal list
  `'$DMS_BASE_PATH $DMS_SWAGGER_UI_ENABLE_CUSTOM_DOMAINS'`.
- Using `sh -c` bypasses the official image's `/docker-entrypoint.sh` template processing, which is
  intentional here. The stock `default.conf` serves `/usr/share/nginx/html` on port 80.
- `wget` in the health check is BusyBox `wget` in the alpine image. For a Debian-based NGINX image,
  use `curl -fsS http://127.0.0.1/ >/dev/null` instead.

## Ingress requirements (NGINX `default.conf.template`)

- Proxy `/swagger/` to the container **with the prefix stripped**, for example
  `location /swagger/ { proxy_pass http://swagger-ui:80/; }`, with a trailing slash on `proxy_pass`.
- Redirect the bare path so relative assets resolve under `/swagger/`:
  `location = /swagger { return 301 /swagger/; }`. All asset references in `index.html` are
  relative (`favicon.png`, `edfi-*.js`, `swagger-initializer.js`), so they work under `/swagger/`.
  An absolute path such as `/swagger-initializer.js` would not.
- DMS must be reachable on the same origin at `DMS_BASE_PATH`, including `/api/metadata/...` and
  `/api/oauth/token`.
- `oauth2-redirect.html` is not shipped or needed: the kit uses only the client-credentials flow,
  which doesn't redirect.

## Outbound browser requests (NFR-SEC-6)

`index.html` loads `swagger-ui-dist@5.25.2` (CSS, bundle, and standalone preset) from
`https://unpkg.com`, pinned with Subresource Integrity (`sha384`) hashes. The participant's
**browser** therefore contacts unpkg.com when `/swagger/` is opened. No containers make these
requests. If a participant's network blocks unpkg.com, Swagger UI won't render. The rest of the kit
is unaffected. Vendoring the three files into this directory would remove that dependency; it was
not done for this interim copy.
