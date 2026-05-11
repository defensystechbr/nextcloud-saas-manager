#!/bin/bash
# scripts/lib/output_json.sh — Geração segura de JSON e logging NDJSON
# NUNCA usar string-concat para JSON; SEMPRE jq.
# Source guard
[ "${OUTPUT_JSON_SH_SOURCED:-0}" = "1" ] && return 0
readonly OUTPUT_JSON_SH_SOURCED=1

set -euo pipefail

# ============================================================
# sanitize_secrets <text>
# usage: sanitize_secrets "MYSQL_PASSWORD=abc123 log line"
# Substitui valores de segredos conhecidos por ***.
# Idempotente: chamar 2x = chamar 1x.
# ============================================================
sanitize_secrets() {
  local text="${1:-}"
  # Regex: captura o token secreto e substitui o valor por ***
  # Não re-substitui *** (idempotência garantida pois \S+ não casa ***)
  echo "$text" | sed -E \
    's/(MYSQL_PASSWORD|NEXTCLOUD_ADMIN_PASSWORD|REDIS_PASSWORD|WORKER_REDIS_PASS|WORKER_CALLBACK_SECRET|SIGNALING_SECRET|RECORDING_SECRET|TURN_SECRET|SIGNALING_HASH_KEY|SIGNALING_BLOCK_KEY|SIGNALING_INTERNAL_SECRET|DB_ROOT_PASSWORD|HARP_SHARED_KEY|--password|--password-from-env)=\S+/\1=***/g'
}

# ============================================================
# emit_json [key value ...]
# usage: emit_json job_id "$jid" state "queued"
# Emite 1 linha JSON com schema_version="1" + pares chave-valor.
# Prefixos de tipo no value: @number: @bool: @json:
# Validação: número de args deve ser par (key value); exit 5 se ímpar.
# ============================================================
emit_json() {
  if (( $# % 2 != 0 )); then
    echo "emit_json: numero de argumentos deve ser par (key value ...)" >&2
    return 5
  fi

  local jq_args=(--arg _schema_version "1")
  local jq_keys='{"schema_version":$_schema_version'

  local args=("$@")
  local idx=0
  while [[ $idx -lt ${#args[@]} ]]; do
    local key="${args[$idx]}"
    local val="${args[$((idx + 1))]}"
    idx=$((idx + 2))

    [[ -n "$key" ]] || { echo "emit_json: key vazia não permitida" >&2; return 5; }

    # Sanitize key name for use as jq $variable (replace non-alphanumeric with _)
    local safe_key="${key//[^a-zA-Z0-9_]/_}"

    if [[ "$val" == "@number:"* ]]; then
      jq_args+=(--argjson "_v_${safe_key}" "${val#@number:}")
    elif [[ "$val" == "@bool:"* ]]; then
      jq_args+=(--argjson "_v_${safe_key}" "${val#@bool:}")
    elif [[ "$val" == "@json:"* ]]; then
      jq_args+=(--argjson "_v_${safe_key}" "${val#@json:}")
    else
      jq_args+=(--arg "_v_${safe_key}" "$val")
    fi
    jq_keys+=",\"${key}\":\$_v_${safe_key}"
  done

  jq_keys+="}"
  jq -nc "${jq_args[@]}" "$jq_keys"
}

# ============================================================
# emit_error <code> <message> [retry_after]
# usage: emit_error "idempotency_conflict" "key already used" 30
# Emite payload de erro padrão (CONTRACTS §3.6)
# ============================================================
emit_error() {
  local code="${1:?emit_error: code obrigatorio}"
  local message="${2:?emit_error: message obrigatorio}"
  local retry_after="${3:-}"

  if [[ -n "$retry_after" ]]; then
    emit_json error "$code" message "$message" retry_after "@number:${retry_after}"
  else
    emit_json error "$code" message "$message"
  fi
}

# ============================================================
# log_event <level> <event> [key value ...]
# usage: log_event notice run_start job_id "$jid" client "acme"
# Emite NDJSON em stdout via logger journald (tag configurável via LOG_EVENT_TAG).
# Sanitiza automaticamente segredos antes de emitir.
# ============================================================
log_event() {
  local level="${1:?log_event: level obrigatorio}"
  local event="${2:?log_event: event obrigatorio}"
  shift 2

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local payload
  payload="$(emit_json ts "$ts" level "$level" event "$event" "$@")"

  # Sanitizar segredos antes de emitir
  payload="$(sanitize_secrets "$payload")"

  printf '%s\n' "$payload"
}
