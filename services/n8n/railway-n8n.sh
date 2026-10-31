#!/bin/sh
# Entrypoint for n8n Main and n8n Webhook on Railway.
#
#   N8N_RAILWAY_ROLE=main     `n8n start`: editor, REST API, triggers, pruning.
#                             With N8N_INSTANCE_OWNER_MANAGED_BY_ENV=true, n8n creates or
#                             updates the owner account from variables before its HTTP
#                             server starts. n8n only accepts a bcrypt hash, so the
#                             generated N8N_OWNER_PASSWORD is hashed here on every boot.
#   N8N_RAILWAY_ROLE=webhook  `n8n webhook`: production webhooks, forms, chat and MCP triggers.
set -eu

log() { printf '[railway-n8n] %s\n' "$*"; }
die() { printf '[railway-n8n] ERROR: %s\n' "$*" >&2; exit 1; }

is_true() {
  case "$1" in
    true | TRUE | True | 1) return 0 ;;
    *) return 1 ;;
  esac
}

start_main() {
  if is_true "${N8N_INSTANCE_OWNER_MANAGED_BY_ENV:-false}"; then
    [ -n "${N8N_INSTANCE_OWNER_EMAIL:-}" ] \
      || die "N8N_INSTANCE_OWNER_EMAIL is empty; set the owner's login email on n8n Main"
    if [ -n "${N8N_INSTANCE_OWNER_PASSWORD_HASH:-}" ]; then
      log "owner account managed by variables (pre-hashed password)"
    else
      hash="$(node /usr/local/lib/railway/hash-owner-password.cjs)" \
        || die "could not hash N8N_OWNER_PASSWORD; n8n Main will not start without an owner"
      N8N_INSTANCE_OWNER_PASSWORD_HASH="${hash}"
      export N8N_INSTANCE_OWNER_PASSWORD_HASH
      log "owner account managed by variables (password hashed at boot)"
    fi
  else
    log "N8N_INSTANCE_OWNER_MANAGED_BY_ENV is not true: the existing owner is managed inside n8n"
  fi
  # n8n itself only needs the hash; keep the plain password out of its environment.
  unset N8N_OWNER_PASSWORD
  exec /docker-entrypoint.sh start
}

start_webhook() {
  unset N8N_OWNER_PASSWORD N8N_INSTANCE_OWNER_PASSWORD_HASH
  exec /docker-entrypoint.sh webhook
}

role="${N8N_RAILWAY_ROLE:-main}"
case "${role}" in
  main) start_main ;;
  webhook) start_webhook ;;
  *) die "N8N_RAILWAY_ROLE must be 'main' or 'webhook' (got '${role}')" ;;
esac
