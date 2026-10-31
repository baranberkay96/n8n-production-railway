# Deploy and Host n8n with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/n8n-2-production-stack-queue-mode-worker?referralCode=20H68q)

n8n is a fair-code workflow automation platform with a visual editor, 400+ integrations and AI agent nodes. This community template runs n8n 2.45.7 in queue mode with a webhook processor, scalable workers that run JavaScript and Python Code nodes, Postgres, Redis and daily backups, ready to log in right after deploy.

## About Hosting n8n

A single n8n container is fine for trying things out. In production it runs the editor, every trigger, every webhook and every Code node in one process, keeps no backups, and its first visitor becomes the owner. This template splits the work the way n8n documents for scale: the editor (main) enqueues executions in Redis, workers run them, a webhook processor takes production traffic, and n8n's task runners execute Code nodes outside the n8n process. One public gateway keeps everything on one domain. The owner account is created from generated variables before the editor goes online, Postgres is backed up to a Railway Bucket every night, and all n8n services share one version variable for upgrades.

## Common Use Cases

- Webhook and API automations that must keep up under load (scale workers with Railway replicas)
- Data pipelines and scheduled syncs that use JavaScript or Python Code nodes
- AI agent workflows, chat triggers and MCP servers backed by your own database
- Internal tools and approval flows with n8n forms
- Replacing a single n8n container that has outgrown one process

## Dependencies for n8n Hosting

- n8n main, webhook processor and worker (`n8nio/n8n` 2.45.7)
- n8n task runners for JavaScript and Python (`n8nio/runners` 2.45.7, inside each worker)
- PostgreSQL 18 (workflows, credentials, executions, binary data)
- Redis 8.2 (execution queue)
- nginx gateway (one public domain)
- Railway Bucket (backups)

### Deployment Dependencies

- n8n source and releases: https://github.com/n8n-io/n8n
- Queue mode: https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/enable-queue-mode
- Task runners: https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-task-runners
- Environment variables: https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables
- License (Sustainable Use License): https://github.com/n8n-io/n8n/blob/master/LICENSE.md

### Implementation Details

| Service | Role | Public |
|---|---|---|
| Gateway | nginx: production webhooks, forms, chat, MCP to n8n Webhook; editor and API to n8n Main; blocks `/metrics` | **yes** |
| n8n Main | Editor, REST API, triggers, execution pruning | no |
| n8n Webhook | Production webhooks, forms, chat and MCP triggers | no |
| n8n Worker | Runs executions (concurrency 10) plus JavaScript and Python task runners; scale with replicas | no |
| Postgres | Database, private only | no |
| Redis | Queue, password, AOF persistence, private only | no |
| Postgres Backup | Daily `pg_dump` to the Bucket, 14-day retention, restore tool | no |

**What is different from a single n8n container**

- Editor stays responsive: executions, including manual test runs, happen on workers.
- Production webhooks go to their own process on the same domain as the editor.
- Code nodes run in n8n's task runners (n8n's recommended setup in v2) as a separate user that cannot read your database or encryption secrets. Python Code nodes work out of the box.
- No setup page: nobody can claim your instance before you log in.
- Nightly backups with retention, and a restore that runs inside Railway.
- Pinned version, execution pruning (7 days or 10,000 runs), private Prometheus metrics, health checks, graceful shutdown, telemetry off, no public database ports.

**First login**

1. Wait until n8n Main is healthy (first boot builds the images and runs database migrations, a few minutes).
2. Open n8n Main → Variables. The login is `N8N_INSTANCE_OWNER_EMAIL` (default `admin@example.com`) and `N8N_OWNER_PASSWORD` (generated).
3. Open the Gateway's URL and sign in. To use your own email, change `N8N_INSTANCE_OWNER_EMAIL` on n8n Main and redeploy it.

The owner is managed by these variables: n8n re-applies them on every start and locks the profile and password in the UI. To change the password, edit `N8N_OWNER_PASSWORD` and redeploy n8n Main. To manage the owner in n8n instead, set `N8N_INSTANCE_OWNER_MANAGED_BY_ENV=false` after your first login.

**Scaling workers**

Open n8n Worker → Settings → Replicas (Hobby allows up to 6, Pro up to 42). Each replica is a full worker with its own task runners, 10 parallel executions and 10 database connections. For fewer, bigger workers raise `N8N_CONCURRENCY_PRODUCTION_LIMIT` and the service's resources instead. n8n Webhook can also run several replicas (keep one if you use MCP Server Trigger over SSE). n8n Main stays single (multi-main is an n8n Enterprise feature). Main's `/metrics` reports queue depth (`n8n_scaling_mode_queue_jobs_waiting`) as a scaling signal.

**Python and JavaScript Code nodes**

Both languages run in n8n's sandboxed task runners inside n8n Worker. Defaults are n8n's: JavaScript may `require('crypto')` and `moment`; Python may not import modules. To allow more, set on n8n Worker `CODE_JS_ALLOW_BUILTIN` (Node.js built-ins, e.g. `crypto,url`) or `CODE_PY_STDLIB_ALLOW` (Python standard library, e.g. `json,datetime,re,math`), comma-separated or `*`. Code nodes have no network access; use the HTTP Request node for calls.

**Backups and restore**

Postgres Backup runs daily at 03:15 UTC and stores `postgres/{timestamp}/` (roles, one verified dump per database, `MANIFEST.txt`) in the Bucket, keeping 14 days and at least 3 runs. Run one now with `railway cron run --service "Postgres Backup"`.

Credentials in n8n are encrypted with `N8N_ENCRYPTION_KEY` (on n8n Main). A backup is useless without it: copy it to your password manager now.

To restore into this project:

1. Stop n8n Main, n8n Webhook and n8n Worker (remove their active deployments).
2. On Postgres Backup set `BACKUP_ACTION=restore`, `BACKUP_RESTORE_CONFIRM=railway` and optionally `BACKUP_RESTORE_RUN={timestamp}` (default: latest), then run the cron job. The restore is one transaction: it either completes or changes nothing, and it refuses while n8n is still connected.
3. Set `BACKUP_ACTION=backup` again and redeploy the three n8n services.

For a new project, set the old `N8N_ENCRYPTION_KEY` on n8n Main and the old Bucket's credentials on Postgres Backup before restoring.

**Upgrades**

All n8n services build from the official images of one tag: `N8N_IMAGE_TAG` on n8n Main (pinned to `2.45.7`, n8n's `stable` channel; n8n Webhook and n8n Worker reference it, and the runners use the same tag). To upgrade: run a backup, read the n8n release notes, set the new stable tag, deploy the staged changes of all three n8n services together. Never mix versions between main, webhook and workers. Postgres, Redis and nginx are pinned separately.

**Monitoring**

Prometheus metrics are on each n8n service's private port: `http://{service}.railway.internal:5678/metrics` (Gateway returns 404 publicly). Health: `/healthz/readiness` on every n8n service, `/gateway-healthz` on the Gateway.

**Custom domain**

Add it to the Gateway, then set `N8N_EDITOR_BASE_URL` and `N8N_WEBHOOK_URL` on n8n Main to `https://{your-domain}` (the other services reference them).

**Costs**

Estimated at Railway usage prices: about $10/month idle and $30/month for steady automations with one worker; each extra worker replica adds roughly $13/month under load. Hobby plan recommended (5 GB volumes, up to 6 replicas). Email nodes: outbound SMTP needs Railway Pro, so prefer an HTTP email API.

**License**

n8n is fair-code under the Sustainable Use License. In short: you may self-host and modify it for your own internal business, non-commercial or personal use; you may not sell n8n as a hosted service or offer it to others for a fee. Files marked `.ee` (Enterprise features) need an n8n license. This is a summary, not legal advice; read the license and ask n8n or a lawyer if your use is commercial or customer-facing.

### Why Deploy n8n on Railway?

Railway runs the whole n8n queue-mode stack, its database, queue, backups and gateway in one project on a private network, with HTTPS, volumes and logs handled for you. You add workers with a replica setting instead of new servers, upgrade by changing one variable, and roll back any deploy in a click. This is a community template and is not affiliated with or endorsed by n8n GmbH.
