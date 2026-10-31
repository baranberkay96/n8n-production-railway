#!/bin/bash
# Logical backups of the n8n Postgres database to a Railway Bucket (S3), with retention,
# and a guarded restore. Runs once and exits: "Postgres Backup" is a Railway cron job.
#
#   BACKUP_ACTION=backup   roles + every database -> Bucket, verify, prune (default)
#   BACKUP_ACTION=list     list the backup runs stored in the Bucket
#   BACKUP_ACTION=restore  restore one database from a complete run (see README); refuses
#                          while other clients (n8n) are connected to that database
#   (a first argument overrides BACKUP_ACTION, e.g. `postgres-backup list`)
#
# Layout in the Bucket (one folder per run, UTC timestamp):
#   {BACKUP_PREFIX}/20261031T031500Z/globals.sql       roles and tablespaces (pg_dumpall -g)
#   {BACKUP_PREFIX}/20261031T031500Z/{database}.dump   pg_dump custom format, one per database
#   {BACKUP_PREFIX}/20261031T031500Z/MANIFEST.txt      written last; a run without it is incomplete
#
# Retention: complete runs older than BACKUP_RETENTION_DAYS are deleted, but the newest
# BACKUP_KEEP_MIN complete runs are always kept. Incomplete runs older than two days are
# deleted. A failed run deletes nothing.
#
# n8n stores credentials encrypted: a restored database is only readable by n8n services
# that use the same N8N_ENCRYPTION_KEY as when the backup was taken.
set -Eeuo pipefail

PREFIX="${BACKUP_PREFIX:-postgres}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
COMPRESSION="${BACKUP_COMPRESSION:-zstd:3}"
DATABASES="${BACKUP_DATABASES:-}"
WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-300}"
RESTORE_RUN="${BACKUP_RESTORE_RUN:-latest}"
RESTORE_DATABASE="${BACKUP_RESTORE_DATABASE:-${PGDATABASE:-}}"
RESTORE_CONFIRM="${BACKUP_RESTORE_CONFIRM:-}"
LOCK_WAIT_TIMEOUT="10min"
INCOMPLETE_GRACE_DAYS=2
RUN_RE='^[0-9]{8}T[0-9]{6}Z$'
REMOTE=""
WORK_DIR=""

log() { printf '[backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

cleanup() {
  if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then rm -rf "${WORK_DIR}"; fi
}
trap cleanup EXIT

require_uint() {
  local name="$1" value="$2" min="$3"
  [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -ge "${min}" ] \
    || die "${name} must be a whole number >= ${min} (got '${value}')"
}

validate_settings() {
  require_uint BACKUP_RETENTION_DAYS "${RETENTION_DAYS}" 1
  require_uint BACKUP_KEEP_MIN "${KEEP_MIN}" 1
  require_uint BACKUP_WAIT_SECONDS "${WAIT_SECONDS}" 0
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "/${PREFIX}/" != */./* ]] && [[ "/${PREFIX}/" != */../* ]] \
    || die "BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-' (no '.' or '..' segments)"
  [[ "${COMPRESSION}" =~ ^[a-z0-9:=,]+$ ]] || die "BACKUP_COMPRESSION looks invalid: '${COMPRESSION}'"
  local var missing=()
  for var in PGHOST PGUSER PGPASSWORD; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Postgres connection not configured (missing: ${missing[*]})"
}

configure_remote() {
  local var missing=()
  for var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Bucket not configured (missing: ${missing[*]})"
  # rclone remote "bucket", configured only through the environment. Railway Buckets use
  # virtual-hosted-style URLs (path style is rejected).
  export RCLONE_CONFIG="${HOME:-/tmp}/rclone.conf"
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  # 16 MiB parts: streams of unknown size up to ~150 GiB (10,000 parts).
  export RCLONE_CONFIG_BUCKET_CHUNK_SIZE=16M
  REMOTE="bucket:${BACKUP_S3_BUCKET}/${PREFIX}"
}

wait_for_postgres() {
  local waited=0
  until pg_isready -q -t 5; do
    [ "${waited}" -ge "${WAIT_SECONDS}" ] && die "Postgres at ${PGHOST}:${PGPORT:-5432} not ready after ${WAIT_SECONDS}s"
    log "waiting for Postgres at ${PGHOST}:${PGPORT:-5432}"
    sleep 10
    waited=$((waited + 10))
  done
}

check_versions() {
  local server_num client_version client_major
  server_num="$(psql -XAtq -c 'SHOW server_version_num')"
  client_version="$(pg_dump --version | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)?).*/\1/')"
  client_major="${client_version%%.*}"
  SERVER_MAJOR=$((server_num / 10000))
  log "server PostgreSQL ${SERVER_MAJOR} (${server_num}), pg_dump ${client_version}"
  [ "${SERVER_MAJOR}" -le "${client_major}" ] \
    || die "pg_dump ${client_major} cannot dump a PostgreSQL ${SERVER_MAJOR} server; rebuild this service with postgresql${SERVER_MAJOR}-client"
  SERVER_VERSION="$(psql -XAtq -c 'SHOW server_version')"
  CLIENT_VERSION="${client_version}"
}

list_databases() {
  if [ -n "${DATABASES}" ]; then
    printf '%s\n' ${DATABASES//,/ }
  else
    psql -XAtq -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
  fi
}

# Object name for a database: keep it readable, never let it escape the run folder.
object_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Stream stdin to the Bucket; fail if the producer or the upload failed.
upload_stream() {
  rclone rcat --retries 1 "$1"
}

verify_dump() {
  # pg_restore --list reads the archive header and table of contents; a truncated or
  # corrupt upload fails here. Only pg_restore's status counts (rclone may get SIGPIPE
  # once pg_restore has read the TOC).
  { rclone cat "$1" 2>/dev/null || true; } | pg_restore --list > /dev/null
}

run_backup() {
  local run_id dest db obj failed=0 dumped=() size
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${REMOTE}/${run_id}"
  log "starting run ${run_id} -> ${PREFIX}/${run_id}/ in bucket ${BACKUP_S3_BUCKET}"

  if pg_dumpall --globals-only | upload_stream "${dest}/globals.sql"; then
    log "globals.sql uploaded"
  else
    log "ERROR: roles/tablespaces dump failed"; failed=1
  fi

  while IFS= read -r db; do
    [ -n "${db}" ] || continue
    obj="$(object_name "${db}").dump"
    log "dumping database ${db} -> ${obj}"
    if pg_dump --format=custom --compress="${COMPRESSION}" --lock-wait-timeout="${LOCK_WAIT_TIMEOUT}" \
         --dbname="${db}" | upload_stream "${dest}/${obj}" \
       && verify_dump "${dest}/${obj}"; then
      size="$(rclone size --json "${dest}/${obj}" 2>/dev/null | sed -nE 's/.*"bytes":[[:space:]]*([0-9]+).*/\1/p')"
      log "database ${db} done (${size:-?} bytes, verified with pg_restore --list)"
      dumped+=("${db}:${obj}:${size:-0}")
    else
      log "ERROR: database ${db} failed"; failed=1
    fi
  done < <(list_databases)

  [ "${#dumped[@]}" -gt 0 ] || { log "ERROR: no database was dumped"; failed=1; }
  if [ "${failed}" -ne 0 ]; then
    die "run ${run_id} is incomplete (no MANIFEST.txt); older backups were left untouched"
  fi

  {
    printf 'run=%s\nserver_version=%s\npg_dump_version=%s\ncompression=%s\n' \
      "${run_id}" "${SERVER_VERSION}" "${CLIENT_VERSION}" "${COMPRESSION}"
    printf 'globals=globals.sql\n'
    printf 'database=%s\n' "${dumped[@]}"
  } | upload_stream "${dest}/MANIFEST.txt"
  log "run ${run_id} complete: ${#dumped[@]} database(s)"
  CURRENT_RUN="${run_id}"
}

list_runs() {
  # Folder names of every run, oldest first (non-matching folders are ignored).
  rclone lsf --dirs-only "${REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${RUN_RE}" | sort || true
}

list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${RUN_RE}" | sort || true
}

prune() {
  local now cutoff incomplete_cutoff complete=() run keep protected=" " total
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - INCOMPLETE_GRACE_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  while IFS= read -r run; do [ -n "${run}" ] && complete+=("${run}"); done < <(list_complete_runs)
  total="${#complete[@]}"
  keep=$((total - KEEP_MIN))
  for run in ${complete[@]+"${complete[@]}"}; do
    # The newest KEEP_MIN complete runs are protected regardless of age.
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s), keep ${RETENTION_DAYS} days (older than ${cutoff}), at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN:-}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    if printf '%s\n' ${complete[@]+"${complete[@]}"} | grep -x "${run}" > /dev/null; then
      [[ "${run}" < "${cutoff}" ]] || continue
      log "deleting expired run ${run}"
    else
      [[ "${run}" < "${incomplete_cutoff}" ]] || continue
      log "deleting incomplete run ${run}"
    fi
    rclone purge "${REMOTE}/${run}" || log "WARNING: could not delete ${run}"
  done < <(list_runs)
}

show_runs() {
  local complete=" " run
  while IFS= read -r run; do complete="${complete}${run} "; done < <(list_complete_runs)
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    case "${complete}" in *" ${run} "*) printf '%s complete\n' "${run}" ;; *) printf '%s incomplete\n' "${run}" ;; esac
  done < <(list_runs)
}

# The run to restore: BACKUP_RESTORE_RUN=latest or a run folder name; it must be complete.
resolve_restore_run() {
  local run="${RESTORE_RUN}"
  if [ "${run}" = "latest" ]; then
    run="$(list_complete_runs | tail -n 1)"
    [ -n "${run}" ] || die "no complete backup run found under ${PREFIX}/ in bucket ${BACKUP_S3_BUCKET}"
  fi
  [[ "${run}" =~ ${RUN_RE} ]] || die "BACKUP_RESTORE_RUN must be 'latest' or a run folder like 20261031T031500Z (got '${run}')"
  list_complete_runs | grep -x "${run}" > /dev/null || die "run ${run} is not a complete backup (missing or no MANIFEST.txt)"
  printf '%s' "${run}"
}

other_connections() {
  psql -XAtq --dbname="$1" -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'"
}

# SQL for the restore, in one transaction: reset the public schema (so tables created
# after the backup do not survive), replay the dump, and COMMIT only if pg_restore
# finished. If anything fails, psql disconnects without COMMIT and nothing changes.
restore_sql() {
  printf 'BEGIN;\nSET client_min_messages = warning;\nDROP SCHEMA IF EXISTS public CASCADE;\nCREATE SCHEMA public AUTHORIZATION pg_database_owner;\nGRANT USAGE ON SCHEMA public TO PUBLIC;\n'
  pg_restore --no-owner --no-privileges --file=- "$1" || exit 1
  printf 'COMMIT;\n'
}

run_restore() {
  local db="${RESTORE_DATABASE}" run obj file others
  [ -n "${db}" ] || die "BACKUP_RESTORE_DATABASE is empty"
  [ "${RESTORE_CONFIRM}" = "${db}" ] \
    || die "restore overwrites database '${db}': set BACKUP_RESTORE_CONFIRM=${db} to confirm (BACKUP_ACTION is 'restore', so no backup was taken)"
  run="$(resolve_restore_run)"
  obj="$(object_name "${db}").dump"
  rclone lsf --files-only "${REMOTE}/${run}/" 2>/dev/null | grep -x "${obj}" > /dev/null \
    || die "run ${run} has no ${obj}"
  others="$(other_connections "${db}")"
  [ "${others}" = "0" ] \
    || die "${others} other connection(s) to '${db}': stop n8n Main, n8n Webhook and n8n Worker first (BACKUP_ACTION is 'restore', so no backup was taken)"

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/restore.XXXXXX")"
  file="${WORK_DIR}/${obj}"
  log "downloading ${PREFIX}/${run}/${obj}"
  rclone copyto --retries 3 "${REMOTE}/${run}/${obj}" "${file}"
  pg_restore --list "${file}" > /dev/null || die "${obj} from run ${run} is not a readable pg_dump archive"
  log "restoring run ${run} into database '${db}' (one transaction: all or nothing)"
  ( restore_sql "${file}" ) | psql -X -q --set ON_ERROR_STOP=1 --dbname="${db}" > /dev/null \
    || die "restore failed; database '${db}' was left unchanged"
  log "restore of run ${run} into '${db}' complete. Set BACKUP_ACTION=backup again, then redeploy n8n Main, n8n Webhook and n8n Worker (same N8N_ENCRYPTION_KEY as the backup)."
}

main() {
  local action="${1:-${BACKUP_ACTION:-backup}}"
  case "${action}" in
    backup)
      validate_settings
      configure_remote
      wait_for_postgres
      check_versions
      run_backup
      prune
      log "done"
      ;;
    list)
      validate_settings
      configure_remote
      show_runs
      ;;
    restore)
      validate_settings
      configure_remote
      wait_for_postgres
      check_versions
      run_restore
      ;;
    *)
      die "unknown action '${action}' (BACKUP_ACTION: backup, list, restore)"
      ;;
  esac
}

main "$@"
