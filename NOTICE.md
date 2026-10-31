# Notice

## Upstream software

This repository contains Railway configuration and small wrapper scripts only. The n8n software is pulled at build time from n8n's official images; it is not stored in this repository.

| Software | License | Images used (publisher) |
|---|---|---|
| n8n (main, webhook, worker) | Sustainable Use License 1.0 (fair-code); files with `.ee` in the name or directory under the n8n Enterprise License | `n8nio/n8n:2.45.7` (n8n GmbH) |
| n8n task runners and task runner launcher | Same as n8n (license files of the launcher are kept in the worker image under `/usr/share/licenses/n8n-task-runner-launcher/`) | `n8nio/runners:2.45.7` (n8n GmbH); files copied into the worker image at build time, unmodified |
| Python 3.13 (inside the runners image) | Python Software Foundation License | from `n8nio/runners:2.45.7` |
| nginx | BSD-2-Clause | `nginx:1.30.6-alpine` (Docker Official Image) |
| PostgreSQL | PostgreSQL License | `ghcr.io/railwayapp-templates/postgres-ssl:18` (Railway); `postgresql18-client` (Alpine) |
| Redis | RSALv2 / SSPLv1 / AGPLv3 (Redis 8 tri-license) | `redis:8.2.11` (Docker Official Image) |
| rclone | MIT | Alpine package `rclone` 1.74.1 |
| Alpine Linux | various (per package) | `alpine:3.24.3` |

### n8n Sustainable Use License: what it means for this template (summary, not legal advice)

The license text is at https://github.com/n8n-io/n8n/blob/n8n%402.45.7/LICENSE.md. In short:

- **Allowed:** using, modifying and self-hosting n8n for your own internal business purposes, or for non-commercial or personal use. Running this template in your own Railway project to automate your own work falls here.
- **Allowed with conditions:** distributing n8n or making it available to others only free of charge and for non-commercial purposes, keeping n8n's license and copyright notices.
- **Not allowed without a separate agreement with n8n:** selling n8n as a hosted service, or offering it to customers for a fee (for example a paid "n8n hosting" product or embedding n8n in a paid product for third parties). Enterprise features in `.ee` files need an n8n Enterprise license.
- This template is a community configuration that points at n8n's official images; it does not sell or relicense n8n. Whether a particular commercial or customer-facing use is permitted depends on the details: read the license and ask n8n GmbH or a lawyer.

## Verified against

| What | Upstream file | Ref | URL | Checked |
|---|---|---|---|---|
| Stable channel | npm dist-tags (`stable` = `latest` = 2.45.7, `beta` = 2.46.3), Docker Hub tags (`stable` digest = `2.45.7` digest), GitHub release | `n8n@2.45.7` | https://github.com/n8n-io/n8n/releases/tag/n8n%402.45.7 | 2026-10-31 |
| Owner from variables (names, bcrypt check, overwrite on every start) | `packages/@n8n/config/src/configs/instance-settings-loader.config.ts`, `packages/cli/src/instance-settings-loader/loaders/owner.instance-settings-loader.ts`, `packages/cli/src/services/ownership.service.ts` | `n8n@2.45.7` | https://github.com/n8n-io/n8n/tree/n8n%402.45.7 | 2026-10-31 |
| Loader runs on main before the HTTP server | `packages/cli/src/commands/start.ts` (`init()` → `initInstanceSettingsLoader()`, `run()` → `server.start()`) | `n8n@2.45.7` | same repo | 2026-10-31 |
| UI/API lock for an env-managed owner | `packages/cli/src/controllers/me.controller.ts`, `packages/cli/src/services/email-change.service.ts`, `packages/cli/src/services/user.service.ts` | `n8n@2.45.7` | same repo | 2026-10-31 |
| Password hashing library and cost | `packages/cli/src/services/password.utility.ts`, `packages/cli/package.json` (`bcryptjs` 2.4.3) | `n8n@2.45.7` | same repo | 2026-10-31 |
| Owner setup endpoint | `packages/cli/src/controllers/owner.controller.ts` (`POST /rest/owner/setup`, skipAuth) | `n8n@2.45.7` | same repo | 2026-10-31 |
| Login email validation | `packages/cli/src/controllers/auth.controller.ts` (`isEmail`), `packages/@n8n/api-types/src/dto/auth/login-request.dto.ts` | `n8n@2.45.7` | same repo | 2026-10-31 |
| Image layout, users, entrypoints | `docker/images/n8n/Dockerfile`, `docker/images/n8n/docker-entrypoint.sh`, `docker/images/n8n-base/Dockerfile`, `docker/images/runners/Dockerfile`, `docker/images/runners/n8n-task-runners.json` | `n8n@2.45.7` | same repo | 2026-10-31 |
| Image contents (amd64 layers: package versions, ELF dependencies, venv layout, launcher, `bcryptjs` path) | registry layers of `n8nio/n8n:2.45.7` (`sha256:8e7fd6d6…` amd64) and `n8nio/runners:2.45.7` (`sha256:1df8be32…` amd64) | 2.45.7 | Docker Hub registry API | 2026-10-31 |
| Task runner settings and deprecations | `packages/@n8n/config/src/configs/runners.config.ts`, `packages/cli/src/task-runners/task-runner-module.ts`, `packages/cli/src/deprecation/deprecation.service.ts` | `n8n@2.45.7` | same repo | 2026-10-31 |
| Worker concurrency, health server, shutdown | `packages/cli/src/commands/worker.ts`, `packages/cli/src/commands/base-command.ts`, `packages/@n8n/config/src/configs/scaling-mode.config.ts`, `generic.config.ts` | `n8n@2.45.7` | same repo | 2026-10-31 |
| Webhook endpoints, metrics, proxy hops, cookies, pruning, DB pool, binary data | `packages/@n8n/config/src/configs/endpoints.config.ts`, `src/index.ts`, `auth.config.ts`, `executions.config.ts`, `database.config.ts`, `packages/core/src/binary-data/binary-data.config.ts` | `n8n@2.45.7` | same repo | 2026-10-31 |
| Encryption keys in the database (restore needs `N8N_ENCRYPTION_KEY`) | `packages/cli/src/encryption/key-manager.service.ts` | `n8n@2.45.7` | same repo | 2026-10-31 |
| Python Code node availability | `packages/nodes-base/nodes/Code/Code.node.ts`, `packages/@n8n/task-runner-python` (`src/config`, `src/constants.py`) | `n8n@2.45.7` | same repo | 2026-10-31 |
| Launcher arguments, environment, config path, graceful shutdown | `cmd/launcher/main.go`, `internal/config/config.go`, `docs/setup.md` | `1.5.1` | https://github.com/n8n-io/task-runner-launcher/tree/1.5.1 | 2026-10-31 |
| Postgres `max_connections` (500) | `wrapper.sh` | Railway `postgres-ssl` | https://github.com/railwayapp-templates/postgres-ssl | 2026-10-31 |
| Alpine packages for the backup job | APKINDEX v3.24 main/community (`postgresql18-client` 18.6-r0, `rclone` 1.74.1-r3) | v3.24 | https://dl-cdn.alpinelinux.org/alpine/v3.24/ | 2026-10-31 |
| Railway cron run on demand, replica limits | Railway docs (cron jobs; plans) | — | https://docs.railway.com/reference/cron-jobs, https://docs.railway.com/pricing/plans | 2026-10-31 |

## Adapted code

| Our file | Source | Copyright / license | Changes |
|---|---|---|---|
| `services/gateway/*` | Our own `10-n8n-ai-starter` template (baranberkay96/n8n-ai-stack-railway), written from n8n's documented queue-mode routing | — | nginx 1.30.6; `/metrics` blocked; `POST /rest/owner/setup` refused; `server_tokens off` |
| `services/backup/*` | Our own `56-pgvector` template (baranberkay96/pgvector-railway) | — | `BACKUP_ACTION` (backup, list, restore); guarded, transactional restore; Alpine 3.24.3 |
| `services/n8n/*`, `services/n8n-worker/*` | Written for this template | — | — |
| `/etc/n8n-task-runners.json` in the worker image | Copied at build time from `n8nio/runners` of the same tag (not stored here) | n8n GmbH, Sustainable Use License | None in the file; optional allow-list overrides are applied to a runtime copy in `/tmp` |

## Reference only (not copied)

- Marketplace templates `n8n-with-workers`, `n8n`, `MRazvG`, `n8n-with-webhook-processors`: no license; reviewed for structure and gaps. No files or text copied.

## Trademarks

"n8n" is a trademark of n8n GmbH; "Railway", "Redis", "PostgreSQL", "nginx" and "Python" belong to their respective owners. This is a community template and is not affiliated with or endorsed by them.
