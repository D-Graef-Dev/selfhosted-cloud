#!/usr/bin/env bash
# Backs up host configuration and service data with restic.
# Services with database files are stopped during the backup.
set -euo pipefail

IMAGE="restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510"
REPO="/srv/backup/restic"
PASSWORD_FILE="/etc/restic/password"
METRICS_FILE="/var/lib/node_exporter/textfile_collector/restic_backup.prom"

# Drop-in directories for stacks outside this repo (e.g. Henria):
# executables in HOOK_DIR run before the backup (e.g. pg_dump),
# each *.txt in EXCLUDE_DIR is passed to restic as --exclude-file.
HOOK_DIR="/etc/restic/pre-backup.d"
EXCLUDE_DIR="/etc/restic/exclude.d"

# Stopped in this order, started in reverse (Authelia before Grafana).
SERVICES=(grafana authelia portainer crowdsec)
STOPPED=()

log() {
  echo "$(date '+%F %T') $*"
}

restic_run() {
  docker run --rm --network none \
    --hostname "$(hostname)" \
    -v "$REPO":/repo \
    -v "$PASSWORD_FILE":/run/secrets/restic_password:ro \
    -v /etc:/host/etc:ro \
    -v /opt:/host/opt:ro \
    -v /root:/host/root:ro \
    -v /home:/host/home:ro \
    -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
    "$IMAGE" --no-cache "$@"
}

# A failing hook is logged but does not stop the backup of everything else.
# Each stack alerts on its own stale dumps (e.g. HenriaDumpTooOld).
run_hooks() {
  local hook
  for hook in "$HOOK_DIR"/*; do
    [[ -x "$hook" ]] || continue
    log "Running hook $hook"
    "$hook" || log "ERROR: hook $hook failed"
  done
}

# Paths as seen inside the restic container (/etc is mounted at /host/etc).
exclude_args() {
  local file
  for file in "$EXCLUDE_DIR"/*.txt; do
    [[ -f "$file" ]] && printf '%s\n' "--exclude-file=/host$file"
  done
  return 0
}

start_services() {
  local i
  for (( i=${#STOPPED[@]}-1; i>=0; i-- )); do
    log "Starting ${STOPPED[i]}"
    docker start "${STOPPED[i]}" >/dev/null || log "ERROR: could not start ${STOPPED[i]}"
  done
  STOPPED=()
}

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root" >&2
  exit 1
fi

exec 9>/run/restic-backup.lock
if ! flock -n 9; then
  log "Another backup is running"
  exit 1
fi

# Runs on every exit, also on errors, so no service stays stopped.
trap start_services EXIT

run_hooks

for svc in "${SERVICES[@]}"; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null)" == "true" ]]; then
    log "Stopping $svc"
    STOPPED+=("$svc")
    docker stop "$svc" >/dev/null
  else
    log "$svc is not running, skipped"
  fi
done

log "Backup started"
mapfile -t EXTRA_EXCLUDES < <(exclude_args)
restic_run backup /host/etc /host/opt /host/root /host/home \
  --exclude /host/opt/prometheus/data \
  --exclude /host/opt/loki/data \
  --exclude /host/root/.cache \
  "${EXTRA_EXCLUDES[@]}"

start_services
log "Backup finished, services started"

log "Applying retention policy"
restic_run forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

log "Checking repository"
restic_run check --read-data

# Written only after a successful run. Temp file and mv, so Node Exporter
# never reads a half-written file.
cat > "$METRICS_FILE.$$" <<EOF
# HELP restic_backup_last_success_timestamp_seconds Time of the last successful backup.
# TYPE restic_backup_last_success_timestamp_seconds gauge
restic_backup_last_success_timestamp_seconds $(date +%s)
EOF
mv "$METRICS_FILE.$$" "$METRICS_FILE"

log "Done"
