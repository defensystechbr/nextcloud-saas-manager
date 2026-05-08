#!/bin/bash
# scripts/lib/dispatch.sh — Dispatcher híbrido: legado posicional + namespaces hierárquicos
# CONTRACTS §3.6: Parser de token-2 valida RESERVED_NAMESPACES ANTES de tratar como FQDN.
# Source guard
[ "${DISPATCH_SH_SOURCED:-0}" = "1" ] && return 0
readonly DISPATCH_SH_SOURCED=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/validators.sh
source "${SCRIPT_DIR}/validators.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${SCRIPT_DIR}/output_json.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${SCRIPT_DIR}/job_queue.sh"

# ============================================================
# _extract_pos_args <argv...>
# Remove flags globais (--*) e retorna apenas args posicionais.
# Flags com valor (--key=val ou --key val) são excluídas.
# ============================================================
_extract_pos_args() {
  local args=("$@")
  local pos=()
  local i=0
  local VALUE_FLAGS=(
    "--idempotency-key" "--callback" "--staging-id" "--confirm"
  )

  while [[ $i -lt ${#args[@]} ]]; do
    local arg="${args[$i]}"
    if [[ "$arg" == --* ]]; then
      # Verificar se é flag de valor sem =
      local is_value_flag=0
      local vf
      for vf in "${VALUE_FLAGS[@]}"; do
        if [[ "$arg" == "$vf" ]]; then
          is_value_flag=1
          i=$((i + 1))  # pular o próximo arg (o valor)
          break
        fi
      done
      # Flags com = são autocontidas; boolean flags são descartadas
      # is_value_flag=0 e arg==--flag=* → descartar (autocontido)
      :
    else
      pos+=("$arg")
    fi
    i=$((i + 1))
  done
  printf '%s\n' "${pos[@]}"
}

# ============================================================
# _build_enqueued_job <client> <cmd> <job_id> <args_json> [domain]
# Emite JSON EnqueuedJob (CONTRACTS §4.1).
# ============================================================
_build_enqueued_job() {
  local client="${1:?}"
  local cmd="${2:?}"
  local job_id="${3:?}"
  local args_json="${4:?}"
  local domain="${5:-}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local extra_args=()
  [[ -n "$domain" ]] && extra_args+=(domain "$domain")

  emit_json \
    schema_version "1" \
    job_id "$job_id" \
    state "queued" \
    cmd "$cmd" \
    client "$client" \
    args_json "@json:${args_json}" \
    queued_at "$ts" \
    "${extra_args[@]}"
}

# ============================================================
# dispatch_enqueue <client> <cmd> <args_json>
# Persiste job no Redis e emite EnqueuedJob.
# Respeita --idempotency-key e --dry-run de PARSED_FLAGS.
# Exit codes: 0=ok, 3=idem_conflict, 5=validacao
# ============================================================
dispatch_enqueue() {
  local client="${1:?dispatch_enqueue: client obrigatorio}"
  local cmd="${2:?dispatch_enqueue: cmd obrigatorio}"
  local args_json="${3:?dispatch_enqueue: args_json obrigatorio}"
  local domain="${4:-}"

  # Dry-run: não toca Redis
  if [[ "${PARSED_FLAGS[dry_run]:-}" == "1" ]]; then
    _build_enqueued_job "$client" "$cmd" "00000000-0000-4000-a000-000000000000" "$args_json" "$domain"
    return 0
  fi

  local job_id
  job_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  # Idempotency
  local idem_key="${PARSED_FLAGS[idempotency_key]:-}"
  if [[ -n "$idem_key" ]]; then
    local args_hash
    args_hash="$(printf '%s' "${args_json}" | sha256sum | cut -d' ' -f1)"

    local idem_result
    idem_result="$(idem_check "$idem_key" "$args_hash" "$job_id")"

    case "$idem_result" in
      new)
        # prosseguir com job_id gerado
        ;;
      same:*)
        local existing_job_id="${idem_result#same:}"
        local existing_state
        existing_state="$(_redis_cli HGET "nc:jobs:${existing_job_id}" state 2>/dev/null || echo "queued")"
        _build_enqueued_job "$client" "$cmd" "$existing_job_id" "$args_json" "$domain" \
          | jq -c ". + {\"idempotent\":true,\"state\":\"${existing_state}\"}"
        return 0
        ;;
      conflict)
        emit_error "idempotency_conflict" "idempotency-key ja usada com args diferentes" 30
        return 3
        ;;
      invalid)
        emit_error "invalid_idempotency_key" "idempotency-key deve ser UUID v4 lowercase"
        return 5
        ;;
    esac
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local callback="${PARSED_FLAGS[callback]:-}"
  local staging_id="${PARSED_FLAGS[staging_id]:-}"

  # Construir hash fields para nc:jobs:<id>
  local -a hset_extra=()
  [[ -n "$domain"     ]] && hset_extra+=(domain     "$domain")
  [[ -n "$callback"   ]] && hset_extra+=(callback   "$callback")
  [[ -n "$staging_id" ]] && hset_extra+=(staging_id "$staging_id")
  [[ -n "$idem_key"   ]] && hset_extra+=(idem_key   "$idem_key")

  enqueue "$job_id" \
    schema_version "1" \
    job_id "$job_id" \
    state "queued" \
    cmd "$cmd" \
    client "$client" \
    args_json "$args_json" \
    queued_at "$ts" \
    "${hset_extra[@]}"

  set_state "$job_id" queued

  # Audit log — enqueue event
  log_event notice enqueue job_id "$job_id" client "$client" cmd "$cmd"

  _build_enqueued_job "$client" "$cmd" "$job_id" "$args_json" "$domain"
}

# ============================================================
# dispatch_namespace_cmd <client> <namespace> <verb> [argv...]
# Despacha para cmd_<ns>_<verb>.
# Em D2: handlers de namespace retornam not_implemented_yet (exit 99).
# Em D3+: handlers reais são implementados.
# ============================================================
dispatch_namespace_cmd() {
  local client="${1:?dispatch_namespace_cmd: client obrigatorio}"
  local namespace="${2:?dispatch_namespace_cmd: namespace obrigatorio}"
  shift 2
  local verb="${1:-}"
  [[ -n "$verb" ]] && shift || { emit_error "missing_verb" "namespace '${namespace}' requer um verbo"; return 5; }

  # Verificar --password em argv (proibido — deve usar --payload-stdin)
  if has_password_in_argv "$@"; then
    emit_error "password_in_argv_forbidden" "senha deve vir via --payload-stdin, nao em argv" >&2
    return 5
  fi

  local handler="cmd_${namespace//-/_}_${verb//-/_}"

  if declare -f "$handler" >/dev/null 2>&1; then
    "$handler" "$client" "$@"
  else
    # Namespaces válidos mas handlers ainda não implementados (D3+)
    if [[ "${PARSED_FLAGS[json]:-}" == "1" ]]; then
      emit_error "not_implemented_yet" "namespace '${namespace}' verb '${verb}' sera implementado em D3/D4"
    else
      echo "[PENDING] ${namespace} ${verb} — sera implementado em Sprint D3/D4" >&2
    fi
    return 99
  fi
}

# ============================================================
# dispatch_legacy_cmd <client> <domain_or_underscore> <cmd> [argv...]
# Caminho legado: manage.sh <cliente> <dom|_> <cmd>
# Distingue sync vs async conforme PARSED_FLAGS.
# ============================================================
dispatch_legacy_cmd() {
  local client="${1:?dispatch_legacy_cmd: client obrigatorio}"
  local domain_or_placeholder="${2:?dispatch_legacy_cmd: domain obrigatorio}"
  local cmd="${3:?dispatch_legacy_cmd: cmd obrigatorio}"
  shift 3
  local extra_args=("$@")

  # Verificar --password em argv (proibido)
  if has_password_in_argv "${extra_args[@]+"${extra_args[@]}"}"; then
    emit_error "password_in_argv_forbidden" "senha deve vir via --payload-stdin, nao em argv" >&2
    return 5
  fi

  local is_async="${PARSED_FLAGS[async]:-}"
  local is_json="${PARSED_FLAGS[json]:-}"
  local is_dry="${PARSED_FLAGS[dry_run]:-}"

  # Verificar se o cmd suporta --async
  if [[ "$is_async" == "1" ]]; then
    if ! is_async_allowed_cmd "$cmd"; then
      if [[ "$is_json" == "1" ]]; then
        emit_error "async_not_supported_for_cmd" "comando '${cmd}' nao suporta --async"
      else
        echo "[ERROR] --async nao suportado para '${cmd}'" >&2
      fi
      return 5
    fi

    # Construir args_json para o job
    local -a job_argv=("nextcloud-manage" "$client" "$domain_or_placeholder" "$cmd" "${extra_args[@]+"${extra_args[@]}"}")
    local args_json
    args_json="$(printf '%s\n' "${job_argv[@]}" | jq -Rc '[.,inputs]')"

    dispatch_enqueue "$client" "$cmd" "$args_json" \
      "$( [[ "$cmd" == "create" ]] && echo "$domain_or_placeholder" || echo "" )"
    return $?
  fi

  # Sync path: executar handler diretamente
  # Verificar se há handler
  local handler="cmd_${cmd//-/_}"
  if declare -f "$handler" >/dev/null 2>&1; then
    if [[ "$cmd" == "create" ]]; then
      "$handler" "$client" "$domain_or_placeholder" "${extra_args[@]+"${extra_args[@]}"}"
    else
      "$handler" "$client" "${extra_args[@]+"${extra_args[@]}"}"
    fi
  else
    if [[ "$is_json" == "1" ]]; then
      emit_error "unknown_command" "comando '${cmd}' nao reconhecido"
    else
      echo "[ERROR] Comando desconhecido: '${cmd}'" >&2
    fi
    return 1
  fi
}
