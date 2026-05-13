#!/bin/bash
# scripts/lib/health_checks.sh — checks paralelos para `manage.sh health`.

[ "${HEALTH_CHECKS_SH_SOURCED:-0}" = "1" ] && return 0
readonly HEALTH_CHECKS_SH_SOURCED=1

set -euo pipefail

HEALTH_CHECKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/output_json.sh
source "${HEALTH_CHECKS_LIB_DIR}/output_json.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${HEALTH_CHECKS_LIB_DIR}/job_queue.sh"

_health_status_json() {
  local name="$1" status="$2" message="$3" duration_ms="$4"
  jq -nc \
    --arg name "$name" \
    --arg status "$status" \
    --arg message "$message" \
    --argjson duration_ms "$duration_ms" \
    '{name:$name,status:$status,message:$message,duration_ms:$duration_ms}'
}

_docker_container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || printf 'missing'
}

check_shared_containers() {
  local missing=0 stopped=0 c state
  for c in shared-db shared-redis shared-collabora shared-turn shared-nats shared-janus shared-signaling shared-recording shared-socket-proxy; do
    state="$(_docker_container_state "$c")"
    [[ "$state" == "missing" ]] && missing=$((missing + 1))
    [[ "$state" != "running" && "$state" != "missing" ]] && stopped=$((stopped + 1))
  done
  if (( missing > 0 )); then
    printf 'warn|%s shared containers missing' "$missing"
  elif (( stopped > 0 )); then
    printf 'fail|%s shared containers stopped' "$stopped"
  else
    printf 'ok|shared containers running'
  fi
}

check_traefik_certs() {
  local acme="${TRAEFIK_ACME_FILE:-/opt/shared-services/traefik/acme.json}"
  [[ -s "$acme" ]] && printf 'ok|traefik acme storage present' || printf 'warn|traefik acme storage not found'
}

check_dns_fixed_domains() {
  local domains=("${COLLABORA_DOMAIN:-}" "${SIGNALING_DOMAIN:-}" "${TURN_DOMAIN:-}")
  local missing=0 d
  for d in "${domains[@]}"; do
    [[ -z "$d" ]] && { missing=$((missing + 1)); continue; }
    if command -v dig >/dev/null 2>&1; then
      dig +short "$d" >/dev/null 2>&1 || missing=$((missing + 1))
    fi
  done
  (( missing == 0 )) && printf 'ok|fixed domains configured' || printf 'warn|%s fixed domains unresolved/unset' "$missing"
}

check_recording_welcome() {
  if docker exec shared-recording true >/dev/null 2>&1; then
    printf 'ok|recording container reachable'
  else
    printf 'warn|recording container not reachable'
  fi
}

check_harp_socket_proxy() {
  local state
  state="$(_docker_container_state shared-socket-proxy)"
  if [[ "$state" != "running" ]]; then
    printf 'fail|shared-socket-proxy is %s' "$state"
    return
  fi
  if docker inspect shared-socket-proxy 2>/dev/null | jq -e '.[0].HostConfig.Binds[]? | contains("/var/run/docker.sock")' >/dev/null 2>&1; then
    printf 'ok|socket-proxy interposed for HaRP'
  else
    printf 'warn|socket-proxy running without visible docker.sock bind'
  fi
}

check_disk() {
  local target="${BASE_DIR:-/opt/nextcloud-customers}"
  local used
  used="$(df -P "$target" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  [[ -z "$used" ]] && { printf 'warn|disk target unavailable'; return; }
  if (( used >= 95 )); then
    printf 'fail|disk usage %s%%' "$used"
  elif (( used >= 85 )); then
    printf 'warn|disk usage %s%%' "$used"
  else
    printf 'ok|disk usage %s%%' "$used"
  fi
}

check_redis_queue() {
  local depth
  depth="$(_redis_cli LLEN nc:jobs:queue 2>/dev/null || true)"
  [[ "$depth" =~ ^[0-9]+$ ]] || { printf 'fail|redis queue unavailable'; return; }
  printf 'ok|queue depth %s' "$depth"
}

check_worker_active() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nextcloud-saas-worker 2>/dev/null; then
    printf 'ok|worker systemd active'
    return
  fi
  local current
  current="$(_redis_cli GET nc:worker:current_job 2>/dev/null || true)"
  [[ -n "$current" ]] && printf 'warn|worker current job %s but systemd inactive/unknown' "$current" || printf 'warn|worker inactive/unknown'
}

run_health_checks_json() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  export BASE_DIR="${BASE_DIR:-/opt/nextcloud-customers}"
  export COLLABORA_DOMAIN="${COLLABORA_DOMAIN:-}"
  export SIGNALING_DOMAIN="${SIGNALING_DOMAIN:-}"
  export TURN_DOMAIN="${TURN_DOMAIN:-}"
  export WORKER_REDIS_HOST="${WORKER_REDIS_HOST:-127.0.0.1}"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  export WORKER_REDIS_PASS="${WORKER_REDIS_PASS:-}"
  local checks=(
    shared_containers:check_shared_containers
    traefik_certs:check_traefik_certs
    dns_fixed_domains:check_dns_fixed_domains
    recording_welcome:check_recording_welcome
    harp_socket_proxy:check_harp_socket_proxy
    disk_opt:check_disk
    redis_queue:check_redis_queue
    worker_active:check_worker_active
  )

  local item name fn
  for item in "${checks[@]}"; do
    name="${item%%:*}"
    fn="${item#*:}"
    (
      start=""
      end=""
      raw=""
      status=""
      message=""
      start="$(date +%s%3N)"
      raw="$(timeout 5s bash -c "$(declare -f "$fn" _docker_container_state _redis_cli); $fn" 2>/dev/null || printf 'fail|timeout')"
      end="$(date +%s%3N)"
      status="${raw%%|*}"
      message="${raw#*|}"
      [[ "$status" =~ ^(ok|warn|fail)$ ]] || { status="fail"; message="invalid health check output"; }
      _health_status_json "$name" "$status" "$message" "$((end - start))"
    ) >"${tmpdir}/${name}.json" &
  done
  wait

  jq -s '
    {
      schema_version:"1",
      checks:.,
      summary:{
        ok:([.[] | select(.status=="ok")] | length),
        warn:([.[] | select(.status=="warn")] | length),
        fail:([.[] | select(.status=="fail")] | length)
      }
    }' "${tmpdir}"/*.json
  rm -rf "$tmpdir"
}
