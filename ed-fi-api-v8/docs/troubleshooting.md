# Troubleshooting

Companion to the [main README](../README.md). Covers port conflicts, certificate trust failures,
startup timeouts and failures, volume reset, switching templates, and bootstrapping failures.

## Port conflicts

The kit binds `HTTP_PORT` (default `80`), `HTTPS_PORT` (default `443`), and `POSTGRES_PORT`
(default `5435`) on `BIND_ADDRESS` (default `127.0.0.1`). If one of those is already in use on your
host, Compose will fail to bring up `nginx` or `db`. Change the conflicting value(s) in `.env` before
starting -- or before re-running `start` if you already have a `.env` -- and start again. No other
host port is published by this kit.

Changing `HTTPS_PORT` also requires changing `PUBLIC_ORIGIN`, because the printed URLs, the saved
credential files (token URL and `apiBaseUrl`), and the CORS origins are all built from
`PUBLIC_ORIGIN`. For example, with `HTTPS_PORT=8443` set `PUBLIC_ORIGIN=https://localhost:8443`; with
the default `443`, leave the port off (or write `:443`). `start` stops with an error that names the
exact value to set if the two disagree.

## Certificate trust failures

- **A client rejects the certificate as untrusted:** see [Trusting the certificate from your own
  client code](../README.md#trusting-the-certificate-from-your-own-client-code) in the main README
  for the `curl`/.NET/Python/Node approaches.
- **You changed the hostname you use to reach the kit** (something other than `localhost`): the
  shipped certificate's Subject Alternative Names are only `localhost`, `nginx`, and `127.0.0.1`.
  Regenerate it to include your hostname:

  ```shell
  # Bash
  ./ssl/generate-certificate.sh --force
  docker compose restart nginx

  # PowerShell
  ./ssl/generate-certificate.ps1 -Force
  docker compose restart nginx
  ```

- **`ssl/generate-certificate.(sh | ps1)` refuses to run:** it won't overwrite an existing `server.crt` or
  `server.key` without `--force`/`-Force`. That's deliberate -- confirm you actually want to replace
  the certificate (every client that trusted the old one will need to trust the new one too) before
  passing it.
- **NGINX fails to start citing a missing certificate:** `start` generates one automatically if
  `ssl/server.crt` or `ssl/server.key` is missing, so this should only happen if certificate
  generation itself failed. Re-run `./ssl/generate-certificate.sh` directly and read its error
  output; it requires `openssl` on `PATH` (or PowerShell 7 for the `.ps1` version).

## Startup timeouts and failures

`start` runs `docker compose up -d --build --wait` and waits on service health rather than just
container creation (FR-LIFE-7). If any service doesn't become healthy, or a one-shot
initialization step exits non-zero, `start` prints something like:

```text
Startup did not complete.
Compose reported:
  container edfi-pilot-init-bootstrap-1 has no healthcheck configured

Checking service status...
FAILED: <service> (<reason>)

----- last 20 lines of '<service>' -----
  ...
Full logs: (cd "<path>" && docker compose logs <service>)

Inspect further with:
  (cd "<path>" && docker compose ps -a)
  (cd "<path>" && docker compose logs)
```

and exits non-zero. "Compose reported" repeats Compose's own `--wait` error (if it doesn't print a
recognizable one, `start` shows Compose's last few output lines instead). Each `FAILED` service is
one that error names, or one that `docker compose ps -a` shows as:

- `unhealthy`, or `exited with code <n>` for a non-zero exit code.
- `never started`: the container was created but never started, usually because a service it
  depends on failed first.
- A one-shot `init-` service that `exited with code 0` (or is `still running`), with a note that
  Compose `--wait` may have checked it as a long-running service. Compose does that for any service
  that no other service depends on with `condition: service_completed_successfully`, and then fails
  because a finished one-shot container can never become healthy.

Run the printed `docker compose logs <service>` command for the full history. If no failing service
can be identified, use the two inspect commands at the end of the report.

`start.sh` and `start.ps1` copy Compose's output as it streams in order to report this, so Compose
shows its plain, line-by-line progress output rather than its interactive progress display.

**Expected startup order**, if you're trying to figure out where a failure sits in the chain: `db`
and `config` (CMS) become healthy first, then identity seeding, then the schema and data store
init steps, then the template load, then `dms`, then bootstrapping. A failure early in that chain
(for example, `init-identity`) usually means a problem with a secret in `.env` -- `init-identity`
validates each CMS client secret (32-128 characters, with a lowercase letter, an uppercase letter, a
digit, and a special character) before touching the database, and fails naming the `.env` variable
if one is invalid.

The first `up` on a clean host also builds the `tools` image (a locally built image used by every
one-shot init step) and, on `DATABASE_TEMPLATE=populated`, loads the sample data set -- budget
several minutes for a clean first start before concluding something has hung.

## Volume reset

Use `./reset.sh` / `.ps1` to return to a clean state -- for a corrupted environment, or because you
want to switch templates (see below). It requires `--force`/`-Force` or an interactive "yes"
confirmation; without either, it changes nothing and exits non-zero:

```bash
./reset.sh            # prompts for confirmation, shows exactly what will be removed
./reset.sh --force     # skips the prompt (for scripts and CI)
./reset.sh --force --start   # reset, then start again immediately
```

It removes the database volume, the ApiSchema volume, the Data Standard download cache, PGAdmin's
data volume, and every file under `.runtime/` except `.gitkeep` (so the bootstrap credential and any
credentials you provisioned with `new-credential` stop working). It keeps `.env` and the TLS
certificate -- only data, not configuration, is destroyed.

## Switching templates

`DATABASE_TEMPLATE` (`minimal` or `populated`) only takes effect the **first** time a database is
initialized. If you change it in `.env` -- or run `./start.sh --template populated` -- against a
database that was already initialized with the other template, nothing reloads. The template
loader detects the mismatch and logs:

```text
WARNING: this database was initialized with DATABASE_TEMPLATE='<old>', but .env now sets
DATABASE_TEMPLATE='<new>'. Changing the template on an existing database requires a reset: run
'docker compose down -v' and start again. Leaving the database as it is.
```

To actually switch, reset first:

```bash
./reset.sh --force --start
```

(`start` will pick up whatever `DATABASE_TEMPLATE` is currently set to in `.env`, or pass
`--template` again to be explicit.)

## Bootstrapping failures

Bootstrapping (the bootstrap credential and the baseline education organization hierarchy) runs as
part of `start`, and fails startup with a message naming the specific step that failed rather than
reporting success with a partially prepared environment. The step names you'll see in
`docker compose logs init-bootstrap` (each wrapped in `[brackets]`) are, in order:
`validate-env`, `validate-baseline-file`, `cms-token`, `bootstrap-credential`, `credentials-file`,
`dms-token`, `baseline-records`, and `summary`. A failure naming:

- `validate-env` or `cms-token` usually points at a CMS secret problem in `.env`, or CMS not yet
  being reachable.
- `validate-baseline-file` means `bootstrap/baseline-edorgs.json` is missing or malformed -- this
  should only happen if the repository checkout itself is damaged.
- `baseline-records` names the specific education organization resource and natural key that failed,
  with the HTTP status and response body CMS or DMS returned.

To retry bootstrapping on its own, without a destructive reset, once the underlying problem is
fixed:

```shell
# Bash
./bootstrap.sh

# PowerShell
.\bootstrap.ps1
```

This requires the stack to already be running (`./start.sh` first) -- otherwise it fails fast with
a message telling you to start the stack first, rather than letting `docker compose run` silently
bring up every dependency on its own.
