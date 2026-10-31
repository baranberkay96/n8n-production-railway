# n8n 2 Production Stack (Queue Mode, Workers, Python) — Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **n8n 2 Production Stack (Queue Mode, Workers, Python)** (`2` = n8n major version; pinned release `2.45.7`) |
| Description | Scalable n8n with workers, webhook processors, Python Code and backups. (71 chars) |
| Category | Automation |
| Tags | n8n, automation, workflow-automation, queue-mode, workers, python, backups, production |
| Repo | `baranberkay96/n8n-production-railway`, services in `/services/<svc>` |
| User input at deploy | **None.** The owner account is created from generated variables; email defaults to `admin@example.com` (change it on n8n Main). |

The listing is delivered as written: "workers" = n8n Worker (scalable with Railway replicas), "webhook processors" = n8n Webhook behind the Gateway (replicas allowed), "Python Code" = native Python Code nodes through the n8n task runners inside each worker, "backups" = the daily `pg_dump` cron job to a Railway Bucket with retention and a guarded restore.

## Base market templates

Market data from Railway's public API, 2026-10-31 (supplied with the task). There is no `_market/` folder for this package; the leader's serialized config was read from `../10-n8n-ai-starter/_market/n8n-with-workers.json`.

| Template | Active projects | Deploys / 30 d | What it ships | Gaps this template closes |
|---|---|---|---|---|
| `n8n-with-workers` "N8N (w/ workers)" | 80.8k | 4.6k | Primary + Worker on unpinned `n8nio/n8n`, `railwayapp/redis` (Bitnami), `postgres-ssl:17` | `latest` tag; owner claimed by the first visitor; no task runners (no Python Code, Code nodes run in-process in internal mode, which n8n 2.45 logs as deprecated); public TCP proxies on Redis and Postgres; `N8N_TRUST_PROXY` (not an n8n variable); no worker healthcheck; `NODE_OPTIONS=--max_old_space_size=8192` on every service; broken `DATABASE_URL` (`${{{PSTGRES_DB}}`); no backups; no execution pruning settings |
| `n8n` (code n8n) | 14.1k | 3k | Single n8n on the third-party image `Shinyduo/n8n-railway-updated` + Postgres | Not queue mode, third-party image, no workers |
| `MRazvG` | 4.2k | — | Single n8n + Postgres | Not queue mode |
| `n8n-with-webhook-processors` | 1.6k | — | Webhook processors on a separate domain | Webhook URL differs from the editor URL; no runners |
| Ours: `10-n8n-ai-starter` "n8n 2 AI Agent Stack (Ollama + Qdrant)" | published, deploy-tested | — | Gateway + Main + Webhook + Worker + Task Runners sidecar, Postgres 18, Redis 8.2, Ollama, Qdrant | **Base of this package.** Kept: Gateway routing, queue mode, binary data in Postgres, shared keys by reference. Dropped: Ollama, Qdrant, demo seeding. Changed: owner from variables, worker + runners in one scalable service, backups, production defaults, single version knob |

No market files or text were copied (market templates carry no license); the gateway and n8n settings are our own from `10-n8n-ai-starter`.

## Pinned versions

| Service | Image / source | Tag | Released | Checked |
|---|---|---|---|---|
| n8n Main, n8n Webhook | `n8nio/n8n` (wrapped: `services/n8n`) | `2.45.7` (digest `sha256:9a8d8dce…57b5d`, identical to `stable`) | 2026-10-30 | 2026-10-31 |
| n8n Worker | `n8nio/n8n` + files from `n8nio/runners` (wrapped: `services/n8n-worker`) | `2.45.7` / `2.45.7` (runners digest `sha256:2f070888…9b300`) | 2026-10-30 | 2026-10-31 |
| Gateway | `nginx` (wrapped: `services/gateway`) | `1.30.6-alpine` | 2026-10-29 | 2026-10-31 |
| Postgres Backup | `alpine` + `postgresql18-client` 18.6-r0 + `rclone` 1.74.1-r3 (wrapped: `services/backup`) | `3.24.3` | 2026-10-23 | 2026-10-31 |
| Postgres | `ghcr.io/railwayapp-templates/postgres-ssl` | `18` | Railway base | 2026-10-31 |
| Redis | `redis` | `8.2.11` (Railway base uses the `8.2` line) | 2026-10-28 | 2026-10-31 |

- n8n channels on 2026-10-31: npm dist-tags `stable` = `latest` = `2.45.7`, `beta` = `next` = `2.46.3`; Docker Hub `stable` and `2.45.7` share one digest. GitHub release `n8n@2.45.7` (2026-10-30, tag commit `01cb29d8`).
- **One version knob:** `N8N_IMAGE_TAG` on n8n Main (default `2.45.7`); n8n Webhook and n8n Worker reference it. All three Dockerfiles declare `ARG N8N_IMAGE_TAG` before `FROM`, and Railway passes service variables to Docker builds as build arguments, so n8n and the runners always come from the same tag.

## Architecture

```
Internet ─HTTPS─▶ Gateway (nginx, the only public domain)
                   ├─ /webhook/ /webhook-waiting/ /form/ /form-waiting/ /mcp/ ─▶ n8n Webhook :5678 (replicas ok)
                   ├─ /metrics → 404, POST /rest/owner/setup → 403
                   └─ everything else (editor, /rest, push, *-test endpoints) ───▶ n8n Main :5678
n8n Main + n8n Webhook ──enqueue──▶ Redis 8.2 (BullMQ, AOF, password) ◀──jobs── n8n Worker × replicas
   n8n Worker container: supervisor (root, no user code)
     ├─ n8n worker (user node, concurrency 10, task broker on 127.0.0.1:5679)
     └─ task-runner-launcher (user runner, minimal env) ─▶ JavaScript runner / Python 3.13 runner (on demand)
all n8n processes ─▶ Postgres 18 (workflows, credentials, executions, binary data)
Postgres Backup (cron 03:15 UTC) ─pg_dump─▶ Bucket: postgres/{UTC timestamp}/{globals.sql, railway.dump, postgres.dump, MANIFEST.txt}
```

## Design decisions (verified in n8n 2.45.7 source and images)

### Owner account without a setup page

- n8n 2.45.7 has `N8N_INSTANCE_OWNER_MANAGED_BY_ENV`, `N8N_INSTANCE_OWNER_EMAIL`, `N8N_INSTANCE_OWNER_PASSWORD_HASH`, `N8N_INSTANCE_OWNER_FIRST_NAME`, `N8N_INSTANCE_OWNER_LAST_NAME` (`packages/@n8n/config/src/configs/instance-settings-loader.config.ts`). The loader (`owner.instance-settings-loader.ts`) requires the email and a bcrypt hash matching `^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$`, otherwise it throws and n8n does not start. It calls `ownershipService.setupOwner(..., { overwriteExisting: true, passwordIsHashed: true })` on **every** start, which also marks the instance as set up.
- It runs only on the main process, inside `Start.init()` before `server.start()` (`packages/cli/src/commands/start.ts`), so the editor is never served without an owner.
- n8n needs a hash, Railway can only generate plain secrets: `N8N_OWNER_PASSWORD = secret(24)` is hashed at boot by `services/n8n/hash-owner-password.cjs` with the `bcryptjs` 2.4.3 copy inside the n8n image (`/usr/local/lib/node_modules/n8n/node_modules/bcryptjs`, the library and cost factor 10 n8n's `PasswordUtility` uses). The plain password is unset before `exec n8n`. If hashing fails, the entrypoint exits (fail-closed). The Docker build runs a self-test of the hasher.
- While managed by variables, n8n refuses profile, email and password changes for that account through the API (`me.controller.ts`, `email-change.service.ts`), so rotation = change `N8N_OWNER_PASSWORD` and redeploy n8n Main. To manage the owner in the UI instead, set `N8N_INSTANCE_OWNER_MANAGED_BY_ENV=false` after the first boot (the account stays).
- Defense in depth: the Gateway answers `POST /rest/owner/setup` (`owner.controller.ts`, the only unauthenticated owner endpoint) with 403.

### Worker and task runners in one container (replicas scale both)

Railway replicas cannot be paired 1:1 with a separate runners service, so `services/n8n-worker` builds one image from both official images of the same tag. Verified statically from the registry layers of `n8nio/n8n:2.45.7` and `n8nio/runners:2.45.7` (amd64) and the Dockerfiles at `n8n@2.45.7`:

| Check | Evidence |
|---|---|
| Same OS base | n8n: Docker Hardened Image `node 26.12.1-alpine3.24`; runners: `alpine-minirootfs-3.24.3`. Package DBs: musl `1.2.6-r3`, libssl3/libcrypto3 `3.5.9-r0`, zlib `1.3.2-r1`, gcompat `1.1.0-r4` in **both** |
| Launcher loads | `task-runner-launcher` 1.5.1 is a dynamic ELF (interpreter `/lib64/ld-linux-x86-64.so.2`; NEEDED `libc.so.6`, `libpthread.so.0`, `libresolv.so.2`); the n8n image ships gcompat with all four. Build check: it must print `Missing runner-type` |
| JavaScript runner | `/opt/runners/task-runner-javascript` is plain JS (only optional Sentry profiler prebuilds); both images run Node 26.12.1; `/usr/local/bin/node` exists in the n8n image |
| Python runner | venv `python -> /usr/local/bin/python3.13` (`pyvenv.cfg home = /usr/local/bin`, Python 3.13.18). Interpreter, `libpython3.13.so.1.0` (RUNPATH `$ORIGIN/../lib`) and the stdlib are copied to the same paths. Extension-module deps: present in n8n (libssl, libcrypto, libz, libbz2, liblzma, gdbm, ncursesw, expat) or copied because missing (libffi, libsqlite3, libuuid, readline, panelw), resolved with `scanelf` at build time. Build check imports `asyncio, ctypes, hashlib, json, multiprocessing, sqlite3, ssl, uuid, zlib, urllib3, websockets` |
| Runner config | `/etc/n8n-task-runners.json` is taken from the runners image of the same tag (not stored in this repo); `/home/runner` and user `runner` (uid 1001) are created as in `n8nio/runners` |

Runtime (`worker-supervisor.cjs`, Node, under tini; Railway's podman-init is PID 1, no s6):
- n8n worker runs as `node` with the service environment and `N8N_RUNNERS_MODE=external`, broker forced to `127.0.0.1:5679` (not reachable from other services).
- The launcher runs as `runner` with only `N8N_RUNNERS_*`, `PATH`, `GENERIC_TIMEZONE`, `TZ`, `LANG` and its own `HOME`, so Code nodes cannot read the worker's database, Redis or encryption secrets (a different uid cannot read `/proc/<worker>/environ`). The launcher filters again per runner (`allowed-env`).
- Launcher crashes are restarted with backoff (2 s doubling to 30 s); if the worker exits, the launcher is stopped and the container exits with the worker's status (Railway restarts it, policy ALWAYS).
- SIGTERM: worker first (finishes running executions within `N8N_GRACEFUL_SHUTDOWN_TIMEOUT=60`), then the launcher (20 s, then SIGKILL); `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=90` covers both.
- Optional allow-lists without a custom image: `CODE_JS_ALLOW_BUILTIN` → `NODE_FUNCTION_ALLOW_BUILTIN`, `CODE_PY_STDLIB_ALLOW` → `N8N_RUNNERS_STDLIB_ALLOW` in a rendered copy of the runner config (empty = upstream defaults `crypto` / none).
- Locally tested with fake processes (24 checks: shutdown order, env filtering, backoff, crash propagation, config rendering, validation). The uid switch only runs as root and is part of the deploy test.

### Gateway, webhook processor, metrics

- n8n's queue-mode guide sends `/webhook*` to webhook processors; in 2.45 the webhook process also serves `/form/`, `/form-waiting/` and `/mcp/` (production form, chat and MCP Server triggers). Main has `N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true`. A Railway domain targets one service, hence the Gateway (from the deploy-tested base, nginx bumped to 1.30.6).
- `N8N_PROXY_HOPS=2`: Railway's edge and the Gateway both append to `X-Forwarded-For`; Express then reports the real client IP, and `X-Forwarded-Proto: https` makes the `Secure` session cookie (`N8N_SECURE_COOKIE=true`) work.
- `N8N_METRICS=true` on all n8n services (`/metrics` on port 5678, private), `N8N_METRICS_INCLUDE_QUEUE_METRICS=true` on main. The Gateway returns 404 for `/metrics`.

### Production defaults (no deprecation warnings at 2.45.7)

- `N8N_WEBHOOK_URL` instead of `WEBHOOK_URL` (deprecated in `deprecation.service.ts`); `N8N_RUNNERS_MODE=external` on every n8n service (internal mode is deprecated; main and webhook start no runner); explicit `N8N_RUNNERS_TASK_TIMEOUT=300`, `N8N_UNVERIFIED_PACKAGES_ENABLED=true` (both current defaults), `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES=268435456` and `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES=1000` (n8n's announced future defaults, protecting worker memory).
- Pruning: `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=168` h (n8n default 336), `EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000` — binary data lives in Postgres, so this caps volume growth.
- Binary data `database` mode (n8n's default in queue mode, set explicitly; filesystem does not work across services, S3 mode is an Enterprise feature).
- Postgres pools: main 10, webhook 5, each worker replica 10 (n8n default 2; Railway's Postgres allows 500 connections).
- Worker concurrency 10 via `N8N_CONCURRENCY_PRODUCTION_LIMIT` (`worker.ts`: the variable overrides `--concurrency`; n8n warns below 5).
- Telemetry off (`N8N_DIAGNOSTICS_ENABLED=false`), no onboarding survey, no hiring banner. Version notifications stay on (they only tell the owner about updates).
- Redis: password, AOF (`appendonly yes`, `appendfsync everysec`) plus RDB snapshots, `noeviction` (BullMQ requirement). Postgres and Redis have no TCP proxy.
- Health checks: Gateway `/gateway-healthz`; n8n Main, Webhook, Worker `/healthz/readiness` (DB + Redis). Postgres and Redis are TCP-only (Railway healthchecks are HTTP), the backup job is a cron job.

### Backups and restore

`services/backup` is the 56-pgvector backup job (published, deploy-tested) with two additions: `BACKUP_ACTION` (backup | list | restore) and a guarded restore that runs inside Railway (no TCP proxy or local tools needed):
- refuses unless `BACKUP_RESTORE_CONFIRM` equals the database name, the run is complete (has `MANIFEST.txt`), and no other client is connected (n8n must be stopped);
- downloads the dump, checks it with `pg_restore --list`, then in **one transaction** drops and recreates the `public` schema and replays the dump; `COMMIT` is only sent if `pg_restore` finished, so a failed restore leaves the database unchanged;
- if `BACKUP_ACTION=restore` is left set, the nightly run fails loudly (n8n is connected) instead of restoring again.

Tested locally against PostgreSQL 15 with a fake `rclone` (23 checks: backup layout, list, both guards, rollback on a truncated dump, successful restore incl. removal of tables created after the backup, bad inputs, retention). n8n credentials in a restored database are only readable with the same `N8N_ENCRYPTION_KEY` (2.45 stores data keys in the database, wrapped by that key: `packages/cli/src/encryption/key-manager.service.ts`).

## Services

Create in this order. Values are entered exactly as shown (Railway resolves `${{...}}`).

### Gateway

- **Source:** GitHub repo `baranberkay96/n8n-production-railway`, root directory `/services/gateway` (Dockerfile build)
- **Start command:** image default
- **Healthcheck:** `/gateway-healthz` (timeout 120 s)
- **Public domain:** yes, target port `8080`
- **TCP proxy:** none
- **Volume:** none
- **Restart policy:** ALWAYS
- **Replicas:** 1
- **Note:** Only public service. Routes production endpoints to n8n Webhook, everything else to n8n Main; returns 404 for /metrics and 403 for POST /rest/owner/setup.

| Variable | Value | Description |
|---|---|---|
| `PORT` | `8080` | Port nginx listens on (public domain target). |
| `N8N_GW_MAIN_UPSTREAM` | `${{n8n Main.RAILWAY_PRIVATE_DOMAIN}}:5678` | n8n Main (editor, REST API, push, test webhooks). |
| `N8N_GW_WEBHOOK_UPSTREAM` | `${{n8n Webhook.RAILWAY_PRIVATE_DOMAIN}}:5678` | n8n Webhook (/webhook, /webhook-waiting, /form, /form-waiting, /mcp). |
| `NGINX_CLIENT_MAX_BODY_SIZE` | `200M` | Max request size (form uploads, binary webhooks). |
| `NGINX_PROXY_TIMEOUT` | `3600s` | Proxy timeout for long webhook responses and the editor's push connection. |

### n8n Main

- **Source:** GitHub repo `baranberkay96/n8n-production-railway`, root directory `/services/n8n` (Dockerfile build)
- **Start command:** image default
- **Healthcheck:** `/healthz/readiness` (timeout 600 s)
- **Public domain:** no (private network only)
- **TCP proxy:** none
- **Volume:** none
- **Restart policy:** ALWAYS
- **Replicas:** 1
- **Note:** Owner account created/updated from variables before the HTTP server starts (fail-closed: no owner, no editor). Holds the shared n8n settings; the other n8n services reference them.

| Variable | Value | Description |
|---|---|---|
| `N8N_IMAGE_TAG` | `2.45.7` | n8n version (official image tag, `stable` channel) for every n8n service; Railway passes it to the Docker builds. Change it here to upgrade all n8n services together. |
| `N8N_RAILWAY_ROLE` | `main` | Process this service runs: main (editor, API, triggers). Do not change. |
| `PORT` | `5678` | Port Railway health-checks (n8n's HTTP port). |
| `N8N_PORT` | `5678` | n8n HTTP port (private; the Gateway is the public entry). |
| `N8N_LISTEN_ADDRESS` | `::` | Listen on IPv4+IPv6 (Railway private network). |
| `N8N_INSTANCE_OWNER_MANAGED_BY_ENV` | `true` | Create/update the owner account from the variables below at every boot, before the editor is served (no open setup page). Owner profile and password are then changed here, not in the UI. |
| `N8N_INSTANCE_OWNER_EMAIL` | `admin@example.com` | Owner login email. Change it to yours (takes effect on the next deploy of n8n Main). |
| `N8N_OWNER_PASSWORD` | `${{secret(24, "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")}}` | Owner login password, generated at deploy. Hashed (bcrypt) at boot into N8N_INSTANCE_OWNER_PASSWORD_HASH. Change it here and redeploy n8n Main to rotate it. |
| `N8N_INSTANCE_OWNER_FIRST_NAME` | `Instance` | Owner first name shown in n8n. |
| `N8N_INSTANCE_OWNER_LAST_NAME` | `Owner` | Owner last name shown in n8n. |
| `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS` | `true` | Editor/test executions also run on workers, so main never runs Code nodes. |
| `N8N_DISABLE_PRODUCTION_MAIN_PROCESS` | `true` | Production webhooks are served by n8n Webhook through the Gateway. |
| `N8N_SECURE_COOKIE` | `true` | Session cookie only over HTTPS (Railway domains are HTTPS). |
| `N8N_SAMESITE_COOKIE` | `lax` | SameSite policy of the session cookie. |
| `N8N_PERSONALIZATION_ENABLED` | `false` | Skip the onboarding survey. |
| `N8N_HIRING_BANNER_ENABLED` | `false` | No hiring banner in the logs. |
| `N8N_METRICS_INCLUDE_QUEUE_METRICS` | `true` | Queue depth and job counters in main's /metrics (scaling signal for workers). |
| `EXECUTIONS_DATA_PRUNE` | `true` | Delete old execution data automatically. |
| `EXECUTIONS_DATA_MAX_AGE` | `168` | Keep executions for this many hours (168 = 7 days). |
| `EXECUTIONS_DATA_PRUNE_MAX_COUNT` | `10000` | Keep at most this many executions (0 = no limit). |
| `DB_POSTGRESDB_POOL_SIZE` | `10` | Postgres connections for this service (n8n default 2). |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `30` | Seconds n8n gets to shut down on redeploy. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `45` | Seconds between SIGTERM and SIGKILL (longer than the n8n shutdown timeout). |
| `EXECUTIONS_MODE` | `queue` | Queue mode: main and webhook enqueue executions in Redis, workers run them. |
| `DB_TYPE` | `postgresdb` | Database type. |
| `DB_POSTGRESDB_HOST` | `${{Postgres.PGHOST}}` | Postgres private host. |
| `DB_POSTGRESDB_PORT` | `${{Postgres.PGPORT}}` | Postgres port. |
| `DB_POSTGRESDB_DATABASE` | `${{Postgres.PGDATABASE}}` | Postgres database. |
| `DB_POSTGRESDB_USER` | `${{Postgres.PGUSER}}` | Postgres user. |
| `DB_POSTGRESDB_PASSWORD` | `${{Postgres.PGPASSWORD}}` | Postgres password. |
| `QUEUE_BULL_REDIS_HOST` | `${{Redis.REDISHOST}}` | Redis private host. |
| `QUEUE_BULL_REDIS_PORT` | `${{Redis.REDISPORT}}` | Redis port. |
| `QUEUE_BULL_REDIS_USERNAME` | `${{Redis.REDISUSER}}` | Redis user. |
| `QUEUE_BULL_REDIS_PASSWORD` | `${{Redis.REDIS_PASSWORD}}` | Redis password. |
| `QUEUE_BULL_REDIS_DUALSTACK` | `true` | Resolve Redis over IPv4 and IPv6 (Railway private network). |
| `N8N_ENCRYPTION_KEY` | `${{secret(48, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")}}` | Encrypts stored credentials; identical on every n8n process. Never change it after first boot and keep a copy: restoring a backup needs it. |
| `N8N_USER_MANAGEMENT_JWT_SECRET` | `${{secret(48, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")}}` | Signs login sessions; identical on every n8n process. |
| `N8N_EDITOR_BASE_URL` | `https://${{Gateway.RAILWAY_PUBLIC_DOMAIN}}` | Public editor URL (links in emails, OAuth callbacks). Change it when you add a custom domain. |
| `N8N_WEBHOOK_URL` | `https://${{Gateway.RAILWAY_PUBLIC_DOMAIN}}/` | Public base for webhook, form, chat and MCP URLs (the Gateway). Change it when you add a custom domain. |
| `N8N_PROXY_HOPS` | `2` | Trusted proxies in front of n8n (Railway edge + Gateway), for client IPs and secure cookies. |
| `N8N_DEFAULT_BINARY_DATA_MODE` | `database` | Binary data in Postgres, shared by main, webhook and workers (filesystem mode does not work across services). |
| `N8N_RUNNERS_MODE` | `external` | Code nodes run in external task runners (inside n8n Worker); main and webhook run no code. |
| `N8N_RUNNERS_TASK_TIMEOUT` | `300` | Seconds a Code node may run (n8n's current default, set explicitly). |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` | `268435456` | Compression node: max unzipped size (256 MiB, n8n's announced future default; protects worker memory). |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` | `1000` | Compression node: max files per archive (n8n's announced future default). |
| `N8N_METRICS` | `true` | Prometheus /metrics on each n8n service's private port 5678 (the Gateway blocks it publicly). |
| `N8N_REINSTALL_MISSING_PACKAGES` | `true` | Reinstall community nodes on boot (services have no shared volume). |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | `true` | Allow community nodes that n8n has not verified (n8n's current default, set explicitly). |
| `N8N_DIAGNOSTICS_ENABLED` | `false` | Disable anonymous telemetry to n8n. |
| `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` | `true` | Strict permissions on the n8n settings file. |
| `GENERIC_TIMEZONE` | `Etc/UTC` | Default timezone for schedules and Code nodes (e.g. Europe/Istanbul). |
| `N8N_LOG_LEVEL` | `info` | Log level (error, warn, info, debug). |

### n8n Webhook

- **Source:** GitHub repo `baranberkay96/n8n-production-railway`, root directory `/services/n8n` (Dockerfile build)
- **Start command:** image default
- **Healthcheck:** `/healthz/readiness` (timeout 600 s)
- **Public domain:** no (private network only)
- **TCP proxy:** none
- **Volume:** none
- **Restart policy:** ALWAYS
- **Replicas:** 1
- **Note:** Same image as n8n Main (`/services/n8n`), started as `n8n webhook` via N8N_RAILWAY_ROLE. Stateless: replicas are fine.

| Variable | Value | Description |
|---|---|---|
| `N8N_IMAGE_TAG` | `${{n8n Main.N8N_IMAGE_TAG}}` | n8n version (official image tag, `stable` channel) for every n8n service; Railway passes it to the Docker builds. Change it here to upgrade all n8n services together. |
| `N8N_RAILWAY_ROLE` | `webhook` | Process this service runs: webhook (production webhooks, forms, chat, MCP). Do not change. |
| `PORT` | `5678` | Port Railway health-checks (n8n's HTTP port). |
| `N8N_PORT` | `5678` | n8n HTTP port (private; the Gateway routes production endpoints here). |
| `N8N_LISTEN_ADDRESS` | `::` | Listen on IPv4+IPv6 (Railway private network). |
| `DB_POSTGRESDB_POOL_SIZE` | `5` | Postgres connections for this service (n8n default 2). |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `30` | Seconds n8n gets to shut down on redeploy. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `45` | Seconds between SIGTERM and SIGKILL (longer than the n8n shutdown timeout). |
| `EXECUTIONS_MODE` | `${{n8n Main.EXECUTIONS_MODE}}` | Queue mode: main and webhook enqueue executions in Redis, workers run them. |
| `DB_TYPE` | `${{n8n Main.DB_TYPE}}` | Database type. |
| `DB_POSTGRESDB_HOST` | `${{n8n Main.DB_POSTGRESDB_HOST}}` | Postgres private host. |
| `DB_POSTGRESDB_PORT` | `${{n8n Main.DB_POSTGRESDB_PORT}}` | Postgres port. |
| `DB_POSTGRESDB_DATABASE` | `${{n8n Main.DB_POSTGRESDB_DATABASE}}` | Postgres database. |
| `DB_POSTGRESDB_USER` | `${{n8n Main.DB_POSTGRESDB_USER}}` | Postgres user. |
| `DB_POSTGRESDB_PASSWORD` | `${{n8n Main.DB_POSTGRESDB_PASSWORD}}` | Postgres password. |
| `QUEUE_BULL_REDIS_HOST` | `${{n8n Main.QUEUE_BULL_REDIS_HOST}}` | Redis private host. |
| `QUEUE_BULL_REDIS_PORT` | `${{n8n Main.QUEUE_BULL_REDIS_PORT}}` | Redis port. |
| `QUEUE_BULL_REDIS_USERNAME` | `${{n8n Main.QUEUE_BULL_REDIS_USERNAME}}` | Redis user. |
| `QUEUE_BULL_REDIS_PASSWORD` | `${{n8n Main.QUEUE_BULL_REDIS_PASSWORD}}` | Redis password. |
| `QUEUE_BULL_REDIS_DUALSTACK` | `${{n8n Main.QUEUE_BULL_REDIS_DUALSTACK}}` | Resolve Redis over IPv4 and IPv6 (Railway private network). |
| `N8N_ENCRYPTION_KEY` | `${{n8n Main.N8N_ENCRYPTION_KEY}}` | Encrypts stored credentials; identical on every n8n process. Never change it after first boot and keep a copy: restoring a backup needs it. |
| `N8N_USER_MANAGEMENT_JWT_SECRET` | `${{n8n Main.N8N_USER_MANAGEMENT_JWT_SECRET}}` | Signs login sessions; identical on every n8n process. |
| `N8N_EDITOR_BASE_URL` | `${{n8n Main.N8N_EDITOR_BASE_URL}}` | Public editor URL (links in emails, OAuth callbacks). Change it when you add a custom domain. |
| `N8N_WEBHOOK_URL` | `${{n8n Main.N8N_WEBHOOK_URL}}` | Public base for webhook, form, chat and MCP URLs (the Gateway). Change it when you add a custom domain. |
| `N8N_PROXY_HOPS` | `${{n8n Main.N8N_PROXY_HOPS}}` | Trusted proxies in front of n8n (Railway edge + Gateway), for client IPs and secure cookies. |
| `N8N_DEFAULT_BINARY_DATA_MODE` | `${{n8n Main.N8N_DEFAULT_BINARY_DATA_MODE}}` | Binary data in Postgres, shared by main, webhook and workers (filesystem mode does not work across services). |
| `N8N_RUNNERS_MODE` | `${{n8n Main.N8N_RUNNERS_MODE}}` | Code nodes run in external task runners (inside n8n Worker); main and webhook run no code. |
| `N8N_RUNNERS_TASK_TIMEOUT` | `${{n8n Main.N8N_RUNNERS_TASK_TIMEOUT}}` | Seconds a Code node may run (n8n's current default, set explicitly). |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` | `${{n8n Main.N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES}}` | Compression node: max unzipped size (256 MiB, n8n's announced future default; protects worker memory). |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` | `${{n8n Main.N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES}}` | Compression node: max files per archive (n8n's announced future default). |
| `N8N_METRICS` | `${{n8n Main.N8N_METRICS}}` | Prometheus /metrics on each n8n service's private port 5678 (the Gateway blocks it publicly). |
| `N8N_REINSTALL_MISSING_PACKAGES` | `${{n8n Main.N8N_REINSTALL_MISSING_PACKAGES}}` | Reinstall community nodes on boot (services have no shared volume). |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | `${{n8n Main.N8N_UNVERIFIED_PACKAGES_ENABLED}}` | Allow community nodes that n8n has not verified (n8n's current default, set explicitly). |
| `N8N_DIAGNOSTICS_ENABLED` | `${{n8n Main.N8N_DIAGNOSTICS_ENABLED}}` | Disable anonymous telemetry to n8n. |
| `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` | `${{n8n Main.N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}}` | Strict permissions on the n8n settings file. |
| `GENERIC_TIMEZONE` | `${{n8n Main.GENERIC_TIMEZONE}}` | Default timezone for schedules and Code nodes (e.g. Europe/Istanbul). |
| `N8N_LOG_LEVEL` | `${{n8n Main.N8N_LOG_LEVEL}}` | Log level (error, warn, info, debug). |

### n8n Worker

- **Source:** GitHub repo `baranberkay96/n8n-production-railway`, root directory `/services/n8n-worker` (Dockerfile build)
- **Start command:** image default
- **Healthcheck:** `/healthz/readiness` (timeout 600 s)
- **Public domain:** no (private network only)
- **TCP proxy:** none
- **Volume:** none
- **Restart policy:** ALWAYS
- **Replicas:** 1
- **Note:** Worker + task runner launcher (JavaScript, Python) in one container under a small supervisor; raise Replicas to scale (each replica brings its own runners).

| Variable | Value | Description |
|---|---|---|
| `N8N_IMAGE_TAG` | `${{n8n Main.N8N_IMAGE_TAG}}` | n8n version (official image tag, `stable` channel) for every n8n service; Railway passes it to the Docker builds. Change it here to upgrade all n8n services together. |
| `PORT` | `5678` | Port of the worker health server (Railway healthcheck, private /metrics). |
| `QUEUE_HEALTH_CHECK_ACTIVE` | `true` | Expose /healthz, /healthz/readiness and /metrics on the worker. |
| `QUEUE_HEALTH_CHECK_PORT` | `5678` | Worker health server port. |
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | `10` | Executions each worker replica runs in parallel (n8n reads this as the worker concurrency; keep it at 5 or more). |
| `N8N_RUNNERS_AUTH_TOKEN` | `${{secret(48, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")}}` | Shared secret between the worker's task broker (127.0.0.1 only) and its task runners. |
| `N8N_RUNNERS_MAX_CONCURRENCY` | `10` | Code-node tasks each runner (JavaScript, Python) runs in parallel. |
| `N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT` | `15` | Stop idle runners after N seconds to free RAM (restarted on demand). |
| `N8N_RUNNERS_LAUNCHER_LOG_LEVEL` | `info` | Task runner launcher log level. |
| `CODE_JS_ALLOW_BUILTIN` | (empty) | JavaScript Code nodes: Node.js built-in modules allowed in require(), comma-separated or * (empty = n8n default: crypto). |
| `CODE_PY_STDLIB_ALLOW` | (empty) | Python Code nodes: standard-library modules allowed in import, comma-separated or * (empty = n8n default: none). |
| `DB_POSTGRESDB_POOL_SIZE` | `10` | Postgres connections per worker replica (n8n default 2). |
| `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` | `60` | Seconds a worker gets to finish running executions on redeploy. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `90` | Seconds between SIGTERM and SIGKILL (worker drain + runner stop). |
| `EXECUTIONS_MODE` | `${{n8n Main.EXECUTIONS_MODE}}` | Queue mode: main and webhook enqueue executions in Redis, workers run them. |
| `DB_TYPE` | `${{n8n Main.DB_TYPE}}` | Database type. |
| `DB_POSTGRESDB_HOST` | `${{n8n Main.DB_POSTGRESDB_HOST}}` | Postgres private host. |
| `DB_POSTGRESDB_PORT` | `${{n8n Main.DB_POSTGRESDB_PORT}}` | Postgres port. |
| `DB_POSTGRESDB_DATABASE` | `${{n8n Main.DB_POSTGRESDB_DATABASE}}` | Postgres database. |
| `DB_POSTGRESDB_USER` | `${{n8n Main.DB_POSTGRESDB_USER}}` | Postgres user. |
| `DB_POSTGRESDB_PASSWORD` | `${{n8n Main.DB_POSTGRESDB_PASSWORD}}` | Postgres password. |
| `QUEUE_BULL_REDIS_HOST` | `${{n8n Main.QUEUE_BULL_REDIS_HOST}}` | Redis private host. |
| `QUEUE_BULL_REDIS_PORT` | `${{n8n Main.QUEUE_BULL_REDIS_PORT}}` | Redis port. |
| `QUEUE_BULL_REDIS_USERNAME` | `${{n8n Main.QUEUE_BULL_REDIS_USERNAME}}` | Redis user. |
| `QUEUE_BULL_REDIS_PASSWORD` | `${{n8n Main.QUEUE_BULL_REDIS_PASSWORD}}` | Redis password. |
| `QUEUE_BULL_REDIS_DUALSTACK` | `${{n8n Main.QUEUE_BULL_REDIS_DUALSTACK}}` | Resolve Redis over IPv4 and IPv6 (Railway private network). |
| `N8N_ENCRYPTION_KEY` | `${{n8n Main.N8N_ENCRYPTION_KEY}}` | Encrypts stored credentials; identical on every n8n process. Never change it after first boot and keep a copy: restoring a backup needs it. |
| `N8N_USER_MANAGEMENT_JWT_SECRET` | `${{n8n Main.N8N_USER_MANAGEMENT_JWT_SECRET}}` | Signs login sessions; identical on every n8n process. |
| `N8N_EDITOR_BASE_URL` | `${{n8n Main.N8N_EDITOR_BASE_URL}}` | Public editor URL (links in emails, OAuth callbacks). Change it when you add a custom domain. |
| `N8N_WEBHOOK_URL` | `${{n8n Main.N8N_WEBHOOK_URL}}` | Public base for webhook, form, chat and MCP URLs (the Gateway). Change it when you add a custom domain. |
| `N8N_PROXY_HOPS` | `${{n8n Main.N8N_PROXY_HOPS}}` | Trusted proxies in front of n8n (Railway edge + Gateway), for client IPs and secure cookies. |
| `N8N_DEFAULT_BINARY_DATA_MODE` | `${{n8n Main.N8N_DEFAULT_BINARY_DATA_MODE}}` | Binary data in Postgres, shared by main, webhook and workers (filesystem mode does not work across services). |
| `N8N_RUNNERS_MODE` | `${{n8n Main.N8N_RUNNERS_MODE}}` | Code nodes run in external task runners (inside n8n Worker); main and webhook run no code. |
| `N8N_RUNNERS_TASK_TIMEOUT` | `${{n8n Main.N8N_RUNNERS_TASK_TIMEOUT}}` | Seconds a Code node may run (n8n's current default, set explicitly). |
| `N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES` | `${{n8n Main.N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES}}` | Compression node: max unzipped size (256 MiB, n8n's announced future default; protects worker memory). |
| `N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES` | `${{n8n Main.N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES}}` | Compression node: max files per archive (n8n's announced future default). |
| `N8N_METRICS` | `${{n8n Main.N8N_METRICS}}` | Prometheus /metrics on each n8n service's private port 5678 (the Gateway blocks it publicly). |
| `N8N_REINSTALL_MISSING_PACKAGES` | `${{n8n Main.N8N_REINSTALL_MISSING_PACKAGES}}` | Reinstall community nodes on boot (services have no shared volume). |
| `N8N_UNVERIFIED_PACKAGES_ENABLED` | `${{n8n Main.N8N_UNVERIFIED_PACKAGES_ENABLED}}` | Allow community nodes that n8n has not verified (n8n's current default, set explicitly). |
| `N8N_DIAGNOSTICS_ENABLED` | `${{n8n Main.N8N_DIAGNOSTICS_ENABLED}}` | Disable anonymous telemetry to n8n. |
| `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` | `${{n8n Main.N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}}` | Strict permissions on the n8n settings file. |
| `GENERIC_TIMEZONE` | `${{n8n Main.GENERIC_TIMEZONE}}` | Default timezone for schedules and Code nodes (e.g. Europe/Istanbul). |
| `N8N_LOG_LEVEL` | `${{n8n Main.N8N_LOG_LEVEL}}` | Log level (error, warn, info, debug). |

### Postgres

- **Source:** Docker image `ghcr.io/railwayapp-templates/postgres-ssl:18`
- **Start command:** image default
- **Healthcheck:** none (no HTTP endpoint)
- **Public domain:** no (private network only)
- **TCP proxy:** none
- **Volume:** `/var/lib/postgresql/data`
- **Restart policy:** ON_FAILURE (max 10 retries)
- **Replicas:** 1
- **Note:** Copied unchanged from templates/_railway-base/postgres.json (no TCP proxy).

| Variable | Value | Description |
|---|---|---|
| `PGDATA` | `/var/lib/postgresql/data/pgdata` | Location where the database will be initialized |
| `PGHOST` | `${{RAILWAY_PRIVATE_DOMAIN}}` | Railway Private Domain Name. |
| `PGPORT` | `5432` | Port to connect to Postgres. |
| `PGUSER` | `${{ POSTGRES_USER }}` | Required variable for Data panel |
| `PGDATABASE` | `${{POSTGRES_DB}}` | Required variable for the data panel. |
| `PGPASSWORD` | `${{POSTGRES_PASSWORD}}` | Required variable for Data panel |
| `POSTGRES_DB` | `railway` | Default database created when image is started. |
| `DATABASE_URL` | `postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{PGDATABASE}}` | URL to connect to Postgres database. |
| `POSTGRES_USER` | `postgres` | User to connect to Postgres DB |
| `SSL_CERT_DAYS` | `820` | SSL certificate expiry in days. |
| `POSTGRES_PASSWORD` | `${{ secret(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") }}` | Password to connect to DB |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` | Allow Postgres to cleanly shut down |

### Redis

- **Source:** Docker image `redis:8.2.11`
- **Start command:** `/bin/sh -c "rm -rf $RAILWAY_VOLUME_MOUNT_PATH/lost+found/ && exec docker-entrypoint.sh redis-server --requirepass $REDIS_PASSWORD --appendonly yes --appendfsync everysec --save 60 1 --maxmemory-policy noeviction --dir $RAILWAY_VOLUME_MOUNT_PATH"`
- **Healthcheck:** none (no HTTP endpoint)
- **Public domain:** no (private network only)
- **TCP proxy:** none
- **Volume:** `/data`
- **Restart policy:** ON_FAILURE (max 10 retries)
- **Replicas:** 1
- **Note:** Railway base Redis with the patch tag pinned, AOF persistence (`appendonly yes`, `everysec`) and `maxmemory-policy noeviction` (required by BullMQ). No TCP proxy.

| Variable | Value | Description |
|---|---|---|
| `REDISHOST` | `${{RAILWAY_PRIVATE_DOMAIN}}` | Private network hostname of the Redis service, only resolvable from services in the same environment |
| `REDISPORT` | `6379` | Port that Redis listens on |
| `REDISUSER` | `default` | Username for authenticating with Redis |
| `REDIS_URL` | `redis://${{ REDISUSER }}:${{ REDIS_PASSWORD }}@${{ REDISHOST }}:${{ REDISPORT }}` | Connection string for connecting to Redis using the private network |
| `REDISPASSWORD` | `${{REDIS_PASSWORD}}` | Alias of REDIS_PASSWORD for clients that expect the unseparated name |
| `REDIS_PASSWORD` | `${{ secret(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") }}` | Randomly generated password for authenticating with Redis |

### Postgres Backup

- **Source:** GitHub repo `baranberkay96/n8n-production-railway`, root directory `/services/backup` (Dockerfile build)
- **Start command:** image default
- **Healthcheck:** none (no HTTP endpoint)
- **Public domain:** no (private network only)
- **TCP proxy:** none
- **Volume:** none
- **Restart policy:** NEVER
- **Cron schedule:** `15 3 * * *` (UTC)
- **Replicas:** 1
- **Note:** Cron job (03:15 UTC daily): `pg_dump` of every database + roles to the Bucket, verified, 14-day retention (minimum 3 runs). Also the restore tool (BACKUP_ACTION=restore).

| Variable | Value | Description |
|---|---|---|
| `BACKUP_ACTION` | `backup` | backup = daily dump to the Bucket; restore = restore BACKUP_RESTORE_RUN (see README); list = print the runs. Set it back to backup after a restore. |
| `PGHOST` | `${{Postgres.RAILWAY_PRIVATE_DOMAIN}}` | Postgres private hostname. |
| `PGPORT` | `${{Postgres.PGPORT}}` | Postgres port. |
| `PGUSER` | `${{Postgres.POSTGRES_USER}}` | Superuser, needed to dump roles and every database. |
| `PGPASSWORD` | `${{Postgres.POSTGRES_PASSWORD}}` | Password of that user. |
| `PGDATABASE` | `${{Postgres.POSTGRES_DB}}` | Database used to list the others (n8n's database). |
| `PGCONNECT_TIMEOUT` | `10` | Seconds before a connection attempt gives up (the job retries while Postgres starts). |
| `PGAPPNAME` | `n8n-backup` | application_name shown in pg_stat_activity while the job runs. |
| `BACKUP_S3_BUCKET` | `${{Bucket.BUCKET}}` | Railway Bucket that stores the backups. |
| `BACKUP_S3_ENDPOINT` | `${{Bucket.ENDPOINT}}` | Bucket S3 endpoint. |
| `BACKUP_S3_REGION` | `${{Bucket.REGION}}` | Bucket region. |
| `BACKUP_S3_ACCESS_KEY_ID` | `${{Bucket.ACCESS_KEY_ID}}` | Bucket access key. |
| `BACKUP_S3_SECRET_ACCESS_KEY` | `${{Bucket.SECRET_ACCESS_KEY}}` | Bucket secret key. |
| `BACKUP_S3_FORCE_PATH_STYLE` | `false` | Keep false: Railway Buckets use virtual-hosted-style URLs. true only for buckets whose Credentials tab says path-style. |
| `BACKUP_PREFIX` | `postgres` | Folder in the bucket; each run writes {prefix}/{UTC timestamp}/. |
| `BACKUP_RETENTION_DAYS` | `14` | Delete complete runs older than this many days. |
| `BACKUP_KEEP_MIN` | `3` | Always keep at least this many complete runs, whatever their age. |
| `BACKUP_COMPRESSION` | `zstd:3` | pg_dump --compress value for the custom-format dumps (zstd:3, gzip:6, lz4, none). |
| `BACKUP_DATABASES` | (empty) | Databases to dump, comma-separated. Empty = every database that accepts connections. |
| `BACKUP_WAIT_SECONDS` | `300` | How long a run waits for Postgres to accept connections before failing. |
| `BACKUP_RESTORE_RUN` | `latest` | Restore only: run folder to restore (e.g. 20261031T031500Z) or latest. |
| `BACKUP_RESTORE_DATABASE` | `${{Postgres.POSTGRES_DB}}` | Restore only: database to overwrite (n8n's database). |
| `BACKUP_RESTORE_CONFIRM` | (empty) | Restore only: must equal BACKUP_RESTORE_DATABASE, as confirmation that its contents are replaced. |

### Bucket

Railway Bucket named `Bucket` (private, S3-compatible, virtual-hosted URLs). Only the Postgres Backup job uses it (`BUCKET`, `ENDPOINT`, `REGION`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`). Buckets have no lifecycle rules, so retention lives in the job.

## Improvements over market templates

1. **No open setup page:** the owner is created from generated variables before n8n serves the editor (n8n 2.45 env-managed owner, password hashed at boot, fail-closed); the Gateway also blocks web-based owner setup. The leader leaves the instance to its first visitor.
2. **Pinned n8n `2.45.7`** (`stable`) with one variable (`N8N_IMAGE_TAG`) that upgrades main, webhook, worker and runners together; the leader runs `latest`.
3. **Python and JavaScript Code nodes in external task runners**, n8n's production setup for v2, inside every worker replica; secrets are not visible to Code nodes (separate user, filtered environment). The leader has no runners (deprecated internal mode, no Python).
4. **Workers scale with one setting** (Replicas on n8n Worker; each replica brings its runners). Our previous base needed a new Worker + Runners pair per worker.
5. **Webhook processor on the same domain** (Gateway): production webhooks, forms, chat and MCP triggers do not compete with the editor, and webhook URLs equal the editor domain.
6. **Daily verified backups** to a Railway Bucket with retention, plus an in-Railway, transactional restore. No n8n market template ships backups.
7. **Production defaults:** execution pruning (7 days / 10,000), Prometheus metrics kept private, health checks on every long-running HTTP service, graceful shutdown windows, `N8N_PROXY_HOPS=2`, secure cookies, telemetry off, DB pool sizes, Redis AOF + noeviction + password, no public Postgres/Redis, no deprecated variables at 2.45.7.
8. Fixed leader issues: `N8N_TRUST_PROXY` (not an n8n variable), broken `DATABASE_URL`, Bitnami-based Redis, 8 GB `NODE_OPTIONS` heap on every service, no worker healthcheck.

## Scaling

- **Workers:** n8n Worker → Settings → Replicas (Hobby up to 6, Pro up to 42 per service; each replica is billed for what it uses). Every replica runs its own worker (concurrency 10) and task runners. For heavier single workers raise `N8N_CONCURRENCY_PRODUCTION_LIMIT` and the service's RAM/CPU instead. Postgres connections: 10 per worker replica.
- **Webhook processor:** stateless; replicas are fine. Keep one replica if you use MCP Server Trigger over SSE (sessions live in one process).
- **Main:** single instance (multi-main is an n8n Enterprise feature).
- **Scaling signal:** `n8n_scaling_mode_queue_jobs_waiting` from main's `/metrics`.

## Resource estimate

Prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month, Bucket $0.015/GB-month, egress $0.05/GB. Not measured (no container run this round); based on n8n 2.x process footprints and the deploy-tested base.

| Service | Idle RAM / vCPU | Typical RAM / vCPU | Notes |
|---|---|---|---|
| Gateway | 15 MB / 0.005 | 30 MB / 0.02 | |
| n8n Main | 300 MB / 0.02 | 500 MB / 0.10 | editor, triggers, pruning |
| n8n Webhook | 230 MB / 0.01 | 350 MB / 0.05 | |
| n8n Worker (per replica) | 270 MB / 0.02 | 700 MB / 0.30 | runners start on demand, stop after 15 s idle |
| Postgres | 80 MB / 0.01 | 300 MB / 0.05 | volume 0.3 GB idle, ~3 GB typical (executions + binary data) |
| Redis | 10 MB / 0.005 | 40 MB / 0.01 | volume < 0.2 GB |
| Postgres Backup | 0 | ~0.1 GB for ~1 min/day | < $0.10/month |
| Bucket | ~0 | ~3 GB (14 daily dumps) | + ~6 GB/month upload egress for a 0.2 GB dump |

- **Idle ≈ $10.5/month** (0.9 GB × $10 + 0.07 vCPU × $20 + 0.35 GB × $0.15).
- **Typical, 1 worker ≈ $31/month** (1.92 GB × $10 + 0.53 vCPU × $20 + 3.2 GB × $0.15 + 3 GB × $0.015 + 6 GB × $0.05).
- **3 worker replicas ≈ $57/month** (+1.4 GB, +0.6 vCPU).
- **Minimum plan:** Trial boots it (every service stays under 1 GB, 2 replicas max) but its 0.5 GB volumes fill quickly; **Hobby** recommended (5 GB volumes, 6 replicas per service). Outbound SMTP needs Pro; prefer an HTTP email API in workflows.

## Verification checklist

1. Builds: n8n Main/Webhook log `bcryptjs from n8n works`; n8n Worker logs `python runner imports ok`, `task-runner-launcher loads`, `self-test ok: runners javascript, python`; Postgres Backup build passes its tool checks.
2. Health: `https://{gateway-domain}/gateway-healthz` → `ok`; n8n Main, n8n Webhook, n8n Worker pass `/healthz/readiness`.
3. Owner: n8n Main logs `owner account managed by variables (password hashed at boot)` and n8n's `Owner was set up successfully`. Opening `https://{gateway-domain}/` shows the **sign-in** page (not setup); log in with `N8N_INSTANCE_OWNER_EMAIL` / `N8N_OWNER_PASSWORD`. `curl -X POST https://{gateway-domain}/rest/owner/setup` → 403. Redeploy n8n Main → same login works.
4. Code nodes: a workflow with a JavaScript Code node (`return [{json:{ok:true}}]`) and a Python (Native) Code node (`return [{"json": {"ok": True}}]`) runs; worker logs show the launcher starting both runners as user `runner`. With `CODE_PY_STDLIB_ALLOW=json` a Python node can `import json`.
5. Webhook: activate a workflow with a Webhook trigger, `curl` its production URL → handled by n8n Webhook (its logs), executed by n8n Worker.
6. Scaling: set n8n Worker replicas to 2 → both replicas healthy; run 20 parallel webhook calls → executions spread over both (worker logs).
7. Metrics: from a Railway shell in any service, `curl http://n8n-main.railway.internal:5678/metrics` returns Prometheus text; `https://{gateway-domain}/metrics` → 404.
8. Backup: `railway cron run --service "Postgres Backup"` → Bucket has `postgres/{timestamp}/globals.sql`, `railway.dump`, `postgres.dump`, `MANIFEST.txt`.
9. Restore drill (optional): stop n8n services, set `BACKUP_ACTION=restore`, `BACKUP_RESTORE_CONFIRM=railway`, run the cron job, reset `BACKUP_ACTION=backup`, redeploy n8n → workflows and credentials are back.
10. Upgrade path: change `N8N_IMAGE_TAG` on n8n Main → n8n Main, n8n Webhook and n8n Worker show staged changes and rebuild on the new tag.
11. Redeploy every service → workflows, credentials, owner login and queued jobs persist.

## Open questions

- **Not deployed yet.** Everything above was verified statically (sources at `n8n@2.45.7`, registry layers, local tests of the scripts); no Docker build or container run was done this round.
- **Combined worker at runtime:** the uid switch (supervisor as root → `node`/`runner`), launcher ↔ broker handshake and Python runner start are only provable on Railway (checklist 4). If the Python runner fails there, the fallback is the base's separate Worker + Task Runners pair (documented in `10-n8n-ai-starter`).
- **Build arguments from references:** `N8N_IMAGE_TAG` on n8n Webhook/Worker is a reference to n8n Main; Railway resolves references before builds, but whether a change on n8n Main stages a rebuild of the referencing services automatically must be confirmed (checklist 10). Each Dockerfile defaults to `2.45.7` if the argument is missing.
- **Owner email default** `admin@example.com` is a placeholder login; password-reset emails need a real address and SMTP.
- **Allow-list semantics:** `CODE_PY_STDLIB_ALLOW` is passed to n8n's Python runner as `N8N_RUNNERS_STDLIB_ALLOW` (comma list or `*`); whether a module's own internal imports also need listing follows n8n's runner (`N8N_RUNNERS_ALLOW_TRANSITIVE_IMPORTS`, default off).
- **Future n8n tags:** the worker Dockerfile derives Python paths and libraries from the runners image; a change in that image's layout fails the build loudly rather than producing a broken worker.
- **Restore across projects:** restoring into a new project also needs the old Bucket's credentials on Postgres Backup and the old `N8N_ENCRYPTION_KEY` on n8n Main (README).
- **n8n license:** Sustainable Use License (fair-code); see NOTICE.md. Not legal advice.
