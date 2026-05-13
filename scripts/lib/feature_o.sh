#!/bin/bash
# scripts/lib/feature_o.sh — Feature O: Lifecycle de users/groups/apps
#
# Sprint D3.3 / D3.4 — Handlers de namespace para manage.sh.
# Todos os handlers são enqueue-only: constroem args_json e chamam dispatch_enqueue.
# A execução real ocorre no worker via worker_exec_* em worker.sh.
#
# Contratos (CONTRACTS.md §4):
#   - Senha NUNCA em argv — via --payload-stdin injetado como env NEXTCLOUD_USER_PASSWORD
#   - Password armazenada em nc:pending_pw:<job_id> EX 300 (apagada após uso)
#   - args_json é objeto JSON com campos nomeados (não array de argv)
#   - Todos os handlers são async-only (exit 5 se --async ausente)
# Source guard
[ "${FEATURE_O_SH_SOURCED:-0}" = "1" ] && return 0
readonly FEATURE_O_SH_SOURCED=1

set -euo pipefail

FEATURE_O_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dispatch.sh
source "${FEATURE_O_LIB_DIR}/dispatch.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${FEATURE_O_LIB_DIR}/job_queue.sh"
# shellcheck source=scripts/lib/validators.sh
source "${FEATURE_O_LIB_DIR}/validators.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${FEATURE_O_LIB_DIR}/output_json.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Interno: _require_async
# Todos os handlers Feature O são async-only.
# ─────────────────────────────────────────────────────────────────────────────
_require_async() {
  local cmd="$1"
  if [[ "${PARSED_FLAGS[async]:-}" != "1" ]]; then
    if [[ "${PARSED_FLAGS[json]:-}" == "1" ]]; then
      emit_error "async_required" "comando '${cmd}' e async-only; use --async"
    else
      echo "[ERROR] '${cmd}' requer --async" >&2
    fi
    return 5
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Interno: _read_payload_stdin
# Lê JSON de stdin se --payload-stdin estiver setado.
# Emite o JSON ou "{}" se não configurado.
# ─────────────────────────────────────────────────────────────────────────────
_read_payload_stdin() {
  if [[ "${PARSED_FLAGS[payload_stdin]:-}" == "1" ]]; then
    local payload
    payload="$(cat)"
    if ! echo "$payload" | jq -e . >/dev/null 2>&1; then
      emit_error "invalid_payload" "stdin nao e JSON valido" >&2
      return 5
    fi
    echo "$payload"
  else
    echo "{}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Interno: _store_pw_for_job <job_id> <password>
# Armazena senha efêmera em nc:pending_pw:<job_id>.
# ─────────────────────────────────────────────────────────────────────────────
_store_pw_for_job() {
  local job_id="$1"
  local pw="$2"
  [[ -n "$pw" ]] || return 0
  _redis_cli SET "nc:pending_pw:${job_id}" "$pw" EX 300 >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_user_create <client> <username> [flags...]
# Enqueue: job cmd=user-create.
# Payload JSON esperado via --payload-stdin: {"password":"...","display_name":"...","email":"..."}
# ─────────────────────────────────────────────────────────────────────────────
cmd_user_create() {
  local client="${1:?cmd_user_create: client obrigatorio}"
  local username="${2:-}"
  shift 2 || true

  _require_async "user create" || return $?

  if [[ -z "$username" ]]; then
    emit_error "missing_username" "user create requer <username>"
    return 5
  fi

  # Ler payload stdin
  local payload_json
  if [[ "${PARSED_FLAGS[payload_stdin]:-}" != "1" ]]; then
    emit_error "payload_stdin_required" "user create requer --payload-stdin com password" >&2
    return 5
  fi
  payload_json="$(_read_payload_stdin)" || return $?

  # Extrair campos não-sensíveis
  local display_name email quota
  display_name="$(echo "$payload_json" | jq -r '.display_name // ""')"
  email="$(echo "$payload_json" | jq -r '.email // ""')"
  quota="$(echo "$payload_json" | jq -r '.quota // ""')"
  local groups_json
  groups_json="$(echo "$payload_json" | jq -c '.groups // []')"
  local subadmin_groups_json
  subadmin_groups_json="$(echo "$payload_json" | jq -c '.subadmin_groups // []')"

  # Extrair senha (nunca vai no args_json)
  local password
  password="$(echo "$payload_json" | jq -r '.password // ""')"
  if [[ -z "$password" ]]; then
    emit_error "missing_password" "user create requer password no payload stdin" >&2
    return 5
  fi

  # Construir args_json (sem senha)
  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --arg username "$username" \
    --arg display_name "$display_name" \
    --arg email "$email" \
    --arg quota "$quota" \
    --argjson groups "$groups_json" \
    --argjson subadmin_groups "$subadmin_groups_json" \
    '{cmd:"user-create",client:$client,username:$username,display_name:$display_name,email:$email,quota:$quota,groups:$groups,subadmin_groups:$subadmin_groups}')"

  # Enqueue e capturar job_id para armazenar senha
  local enqueue_result
  enqueue_result="$(dispatch_enqueue "$client" "user-create" "$args_json")" || return $?

  # Armazenar senha efêmera vinculada ao job_id
  if [[ -n "$password" ]]; then
    local job_id
    job_id="$(echo "$enqueue_result" | jq -r '.job_id // ""')"
    [[ -n "$job_id" ]] && _store_pw_for_job "$job_id" "$password"
  fi

  echo "$enqueue_result"
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_user_remove <client> <username> [--force] [flags...]
# ─────────────────────────────────────────────────────────────────────────────
cmd_user_remove() {
  local client="${1:?cmd_user_remove: client obrigatorio}"
  local username="${2:-}"
  shift 2 || true

  _require_async "user remove" || return $?

  if [[ -z "$username" ]]; then
    emit_error "missing_username" "user remove requer <username>"
    return 5
  fi

  local force=""
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--force" ]] && force="1"
  done

  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --arg username "$username" \
    --arg force "${force:-0}" \
    '{cmd:"user-remove",client:$client,username:$username,force:($force=="1")}')"

  dispatch_enqueue "$client" "user-remove" "$args_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_user_modify <client> <username> <action> [flags...]
# Actions: display-name, email, quota, enable, disable, resend_welcome,
#          add_subadmin, remove_subadmin
# ─────────────────────────────────────────────────────────────────────────────
cmd_user_modify() {
  local client="${1:?cmd_user_modify: client obrigatorio}"
  local username="${2:-}"
  local action="${3:-}"
  shift 3 || true

  _require_async "user modify" || return $?

  if [[ -z "$username" || -z "$action" ]]; then
    emit_error "missing_args" "user modify requer <username> <action>"
    return 5
  fi

  # Validar action
  local valid_actions=(display-name email quota enable disable resend_welcome add_subadmin remove_subadmin)
  local valid=0
  local a
  for a in "${valid_actions[@]}"; do
    [[ "$action" == "$a" ]] && valid=1 && break
  done
  if [[ $valid -eq 0 ]]; then
    emit_error "invalid_action" "user modify: action '${action}' invalida"
    return 5
  fi

  # Ler payload stdin se fornecido
  local payload_json
  payload_json="$(_read_payload_stdin)" || return $?

  local value
  value="$(echo "$payload_json" | jq -r '.value // ""')"
  # Para add_subadmin/remove_subadmin, o valor é o grupo
  local group
  group="$(echo "$payload_json" | jq -r '.group // ""')"

  # Extrair senha (para resetpassword action futura — incluir em pending_pw)
  local password
  password="$(echo "$payload_json" | jq -r '.password // ""')"

  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --arg username "$username" \
    --arg action "$action" \
    --arg value "$value" \
    --arg group "$group" \
    '{cmd:"user-modify",client:$client,username:$username,action:$action,value:$value,group:$group}')"

  local enqueue_result
  enqueue_result="$(dispatch_enqueue "$client" "user-modify" "$args_json")" || return $?

  if [[ -n "$password" ]]; then
    local job_id
    job_id="$(echo "$enqueue_result" | jq -r '.job_id // ""')"
    [[ -n "$job_id" ]] && _store_pw_for_job "$job_id" "$password"
  fi

  echo "$enqueue_result"
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_group_create <client> <groupname> [flags...]
# ─────────────────────────────────────────────────────────────────────────────
cmd_group_create() {
  local client="${1:?cmd_group_create: client obrigatorio}"
  local groupname="${2:-}"
  shift 2 || true

  _require_async "group create" || return $?

  if [[ -z "$groupname" ]]; then
    emit_error "missing_groupname" "group create requer <groupname>"
    return 5
  fi

  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --arg groupname "$groupname" \
    '{cmd:"group-create",client:$client,groupname:$groupname}')"

  dispatch_enqueue "$client" "group-create" "$args_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_group_remove <client> <groupname> [--force] [flags...]
# ─────────────────────────────────────────────────────────────────────────────
cmd_group_remove() {
  local client="${1:?cmd_group_remove: client obrigatorio}"
  local groupname="${2:-}"
  shift 2 || true

  _require_async "group remove" || return $?

  if [[ -z "$groupname" ]]; then
    emit_error "missing_groupname" "group remove requer <groupname>"
    return 5
  fi

  local force=""
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--force" ]] && force="1"
  done

  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --arg groupname "$groupname" \
    --arg force "${force:-0}" \
    '{cmd:"group-remove",client:$client,groupname:$groupname,force:($force=="1")}')"

  dispatch_enqueue "$client" "group-remove" "$args_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_group_modify <client> <groupname> <action> [flags...]
# Actions: rename
# Requer Nextcloud >= 31 para group:rename; emite warning se não confirmado.
# ─────────────────────────────────────────────────────────────────────────────
cmd_group_modify() {
  local client="${1:?cmd_group_modify: client obrigatorio}"
  local groupname="${2:-}"
  local action="${3:-}"
  shift 3 || true

  _require_async "group modify" || return $?

  if [[ -z "$groupname" || -z "$action" ]]; then
    emit_error "missing_args" "group modify requer <groupname> <action>"
    return 5
  fi

  local payload_json
  payload_json="$(_read_payload_stdin)" || return $?

  local new_name
  new_name="$(echo "$payload_json" | jq -r '.new_name // ""')"

  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --arg groupname "$groupname" \
    --arg action "$action" \
    --arg new_name "$new_name" \
    '{cmd:"group-modify",client:$client,groupname:$groupname,action:$action,new_name:$new_name}')"

  dispatch_enqueue "$client" "group-modify" "$args_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_apps_enable <client> <apps_csv> [flags...]
# apps_csv: "richdocuments,calendar,contacts"
# Política: parcial-tolerante por padrão; --strict falha ao primeiro erro.
# ─────────────────────────────────────────────────────────────────────────────
cmd_apps_enable() {
  local client="${1:?cmd_apps_enable: client obrigatorio}"
  local apps_csv="${2:-}"
  shift 2 || true

  _require_async "apps enable" || return $?

  if [[ -z "$apps_csv" ]]; then
    emit_error "missing_apps" "apps enable requer <apps_csv>"
    return 5
  fi

  local strict="${PARSED_FLAGS[strict]:-}"

  # Converter CSV em JSON array
  local apps_json
  apps_json="$(echo "$apps_csv" | tr ',' '\n' | jq -Rc '[., inputs]' | jq -c '.')"

  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --argjson apps "$apps_json" \
    --argjson strict "$([ "${strict}" = "1" ] && echo true || echo false)" \
    '{cmd:"apps-enable",client:$client,apps:$apps,strict:$strict}')"

  dispatch_enqueue "$client" "apps-enable" "$args_json"
}

# ─────────────────────────────────────────────────────────────────────────────
# cmd_apps_disable <client> <apps_csv> [--strict] [flags...]
# --remove_after_disable: desinstalar após desabilitar
# ─────────────────────────────────────────────────────────────────────────────
cmd_apps_disable() {
  local client="${1:?cmd_apps_disable: client obrigatorio}"
  local apps_csv="${2:-}"
  shift 2 || true

  _require_async "apps disable" || return $?

  if [[ -z "$apps_csv" ]]; then
    emit_error "missing_apps" "apps disable requer <apps_csv>"
    return 5
  fi

  local strict="${PARSED_FLAGS[strict]:-}"
  local remove_after=false
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--remove_after_disable" || "$arg" == "--remove-after-disable" ]] && remove_after=true
  done

  local apps_json
  apps_json="$(echo "$apps_csv" | tr ',' '\n' | jq -Rc '[., inputs]' | jq -c '.')"

  local args_json
  args_json="$(jq -cn \
    --arg client "$client" \
    --argjson apps "$apps_json" \
    --argjson strict "$([ "${strict}" = "1" ] && echo true || echo false)" \
    --argjson remove_after "$remove_after" \
    '{cmd:"apps-disable",client:$client,apps:$apps,strict:$strict,remove_after_disable:$remove_after}')"

  dispatch_enqueue "$client" "apps-disable" "$args_json"
}
