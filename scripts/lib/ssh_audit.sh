#!/bin/bash
# scripts/lib/ssh_audit.sh — Audit log NDJSON em journald para SSH gateway e worker
# Tags: ncsaas-api-ssh, nextcloud-saas-worker, nextcloud-saas-occ-exec
# Source guard
[ "${SSH_AUDIT_SH_SOURCED:-0}" = "1" ] && return 0
readonly SSH_AUDIT_SH_SOURCED=1

set -euo pipefail

SSH_AUDIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/output_json.sh
source "${SSH_AUDIT_LIB_DIR}/output_json.sh"
# shellcheck source=scripts/lib/validators.sh
source "${SSH_AUDIT_LIB_DIR}/validators.sh"

# Allowlist de eventos válidos
readonly AUDIT_EVENTS=(
  invoke accept reject
  run_start run_finish
  callback_attempt callback_failed
  occ_exec_attempt occ_exec_complete
)

# ============================================================
# _validate_event <event>
# Valida que event está na allowlist.
# ============================================================
_validate_event() {
  local event="${1:-}"
  local e
  for e in "${AUDIT_EVENTS[@]}"; do
    [[ "$e" == "$event" ]] && return 0
  done
  echo "audit: evento inválido: '${event}' (não está na allowlist)" >&2
  return 1
}

# ============================================================
# _truncate_argv <string>
# Trunca argv > 500 chars com sufixo "..."
# ============================================================
_truncate_argv() {
  local s="${1:-}"
  if [[ "${#s}" -gt 500 ]]; then
    echo "${s:0:497}..."
  else
    echo "$s"
  fi
}

# ============================================================
# _emit <tag> <facility> <level> <payload_json>
# Emite via logger; fallback para arquivo se logger falhar.
# ============================================================
_emit() {
  local tag="$1"
  local facility="$2"
  local level="$3"
  local payload="$4"

  payload="$(sanitize_secrets "$payload")"

  logger -t "$tag" -p "${facility}.${level}" -- "$payload" 2>/dev/null \
    || printf '%s [%s.%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$level" "$payload" \
         >> /var/log/ncsaas-fallback.log 2>/dev/null \
    || true
}

# ============================================================
# audit_ssh <event> <decision> [key value ...]
# tag: ncsaas-api-ssh, facility: auth
# decision: accepted|rejected
# ============================================================
audit_ssh() {
  local event="${1:?audit_ssh: event obrigatorio}"
  local decision="${2:?audit_ssh: decision obrigatorio}"
  shift 2

  _validate_event "$event" || return 1

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Sanitizar argv do comando se presente nos extras
  local extras=()
  while [[ $# -ge 2 ]]; do
    local k="$1" v="$2"
    if [[ "$k" == "argv" || "$k" == "command" ]]; then
      v="$(_truncate_argv "$v")"
    fi
    extras+=("$k" "$v")
    shift 2
  done

  local level="notice"
  [[ "$decision" == "rejected" ]] && level="warning"

  local client_ip="${SSH_CONNECTION:-local}"
  # SSH_CONNECTION: "client_ip client_port server_ip server_port"
  client_ip="${client_ip%% *}"
  [[ -z "$client_ip" ]] && client_ip="local"

  local payload
  payload="$(emit_json \
    ts "$ts" \
    event "$event" \
    decision "$decision" \
    key_id "${SSH_USER_AUTH:-unknown}" \
    client_ip "$client_ip" \
    "${extras[@]}")"

  _emit "ncsaas-api-ssh" "auth" "$level" "$payload"
}

# ============================================================
# audit_worker <event> <level> <job_id> [key value ...]
# tag: nextcloud-saas-worker, facility: daemon
# ============================================================
audit_worker() {
  local event="${1:?audit_worker: event obrigatorio}"
  local level="${2:?audit_worker: level obrigatorio}"
  local job_id="${3:?audit_worker: job_id obrigatorio}"
  shift 3

  _validate_event "$event" || return 1

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local payload
  payload="$(emit_json \
    ts "$ts" \
    event "$event" \
    level "$level" \
    job_id "$job_id" \
    "$@")"

  _emit "nextcloud-saas-worker" "daemon" "$level" "$payload"
}

# ============================================================
# audit_occ <client> <subcmd> <decision> [exit_code] [duration_ms]
# tag: nextcloud-saas-occ-exec, facility: daemon
# decision: accept|reject
# ============================================================
audit_occ() {
  local client="${1:?audit_occ: client obrigatorio}"
  local subcmd="${2:?audit_occ: subcmd obrigatorio}"
  local decision="${3:?audit_occ: decision obrigatorio}"
  local exit_code="${4:-}"
  local duration_ms="${5:-}"

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local level="notice"
  [[ "$decision" == "reject" ]] && level="warning"

  local extra_args=()
  [[ -n "$exit_code"    ]] && extra_args+=(exit_code "@number:${exit_code}")
  [[ -n "$duration_ms"  ]] && extra_args+=(duration_ms "@number:${duration_ms}")

  local payload
  payload="$(emit_json \
    ts "$ts" \
    event "occ_exec_attempt" \
    client "$client" \
    subcmd "$subcmd" \
    decision "$decision" \
    "${extra_args[@]}")"

  _emit "nextcloud-saas-occ-exec" "daemon" "$level" "$payload"
}
