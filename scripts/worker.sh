#!/bin/bash
# scripts/worker.sh — Worker daemon para jobs assíncronos do Nextcloud SaaS Manager
#
# ARCH-002: worker systemd único, concorrência=1, flock host + Redis lock,
#           watchdog 120s, BRPOP nc:jobs:queue, callback HMAC-SHA256.
# NUNCA executar bash -c. SEMPRE array argv via nextcloud-manage.
# NUNCA logar payload bruto — sempre via log_event (sanitização automática).
#
# Uso: systemctl start nextcloud-saas-worker (não invocar diretamente)

set -euo pipefail

WORKER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Libs
# ============================================================
# shellcheck source=scripts/lib/validators.sh
source "${WORKER_SCRIPT_DIR}/lib/validators.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${WORKER_SCRIPT_DIR}/lib/output_json.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${WORKER_SCRIPT_DIR}/lib/job_queue.sh"
# shellcheck source=scripts/lib/job_runner.sh
source "${WORKER_SCRIPT_DIR}/lib/job_runner.sh"
# shellcheck source=scripts/lib/ssh_audit.sh
source "${WORKER_SCRIPT_DIR}/lib/ssh_audit.sh"
# shellcheck source=scripts/lib/occ_bridge.sh
source "${WORKER_SCRIPT_DIR}/lib/occ_bridge.sh"

# ============================================================
# Configuração (via env ou defaults)
# ============================================================
WORKER_JOBS_DIR="${WORKER_JOBS_DIR:-/opt/nextcloud-customers/jobs}"
WORKER_FLOCK_FILE="${WORKER_FLOCK_FILE:-/run/nextcloud-saas-worker.lock}"
WORKER_CALLBACK_BACKOFF="${WORKER_CALLBACK_BACKOFF:-5,30,300}"
WORKER_CONCURRENCY="${WORKER_CONCURRENCY:-1}"
MANAGE_BIN="${MANAGE_BIN:-/usr/local/bin/nextcloud-manage}"

# HMAC secret: LoadCredential via systemd (/run/credentials/) ou fallback
_read_callback_secret() {
  local cred_dir="${CREDENTIALS_DIRECTORY:-}"
  if [[ -n "$cred_dir" && -f "${cred_dir}/callback_secret" ]]; then
    cat "${cred_dir}/callback_secret"
    return
  fi
  if [[ -f "/run/secrets/worker_callback_secret" ]]; then
    cat "/run/secrets/worker_callback_secret"
    return
  fi
  echo "${WORKER_CALLBACK_SECRET:-}"
}

# ============================================================
# Sinais e locks
# ============================================================
_WORKER_PID="$$"
_WORKER_CURRENT_JOB=""
_WORKER_SHUTDOWN=0

_systemd_notify() {
  if command -v systemd-notify >/dev/null 2>&1; then
    systemd-notify "$@" 2>/dev/null || true
  fi
}

_acquire_flock() {
  exec 200>"$WORKER_FLOCK_FILE" 2>/dev/null || {
    log_event warning worker_startup pid "$_WORKER_PID" reason "cannot_open_flock"
    exit 1
  }
  if ! flock -n 200 2>/dev/null; then
    log_event warning worker_startup pid "$_WORKER_PID" reason "already_running_flock"
    exit 1
  fi
}

_cleanup_stale_job() {
  local current
  current="$(_redis_cli GET "nc:worker:current_job" 2>/dev/null || echo "")"
  current="${current// /}"
  if [[ -n "$current" && "$current" != "null" ]]; then
    log_event warning run_finish job_id "$current" reason "worker_killed_stale"
    set_state "$current" failed \
      error_msg "worker_killed" \
      failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _redis_cli DEL "nc:worker:current_job" >/dev/null 2>&1 || true
    audit_worker run_finish warning "$current" reason "worker_killed_stale"
  fi
}

_on_sigterm() {
  _WORKER_SHUTDOWN=1
  log_event notice worker_shutdown pid "$_WORKER_PID"
  _systemd_notify STOPPING=1

  if [[ -n "$_WORKER_CURRENT_JOB" ]]; then
    log_event warning run_finish job_id "$_WORKER_CURRENT_JOB" reason "worker_terminated"
    set_state "$_WORKER_CURRENT_JOB" failed \
      error_msg "worker_terminated" \
      failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    audit_worker run_finish warning "$_WORKER_CURRENT_JOB" reason "worker_terminated"

    # Callback best-effort após SIGTERM com backoff encurtado (max ~7s total)
    # para não ultrapassar o TimeoutStopSec do systemd (default 90s).
    local callback
    callback="$(_redis_cli HGET "nc:jobs:${_WORKER_CURRENT_JOB}" "callback" 2>/dev/null || echo "")"
    if [[ -n "$callback" ]]; then
      WORKER_CALLBACK_BACKOFF="0,2,5" _fire_callback "$_WORKER_CURRENT_JOB" "failed" "$callback" || true
    fi

    # Liberar client lock se houver
    local client
    client="$(_redis_cli HGET "nc:jobs:${_WORKER_CURRENT_JOB}" "client" 2>/dev/null || echo "")"
    [[ -n "$client" ]] && client_lock_release "$client" || true
  fi

  _redis_cli DEL "nc:worker:current_job" >/dev/null 2>&1 || true
  _redis_cli DEL "nc:worker:lock" >/dev/null 2>&1 || true
  exit 0
}

trap '_on_sigterm' TERM INT

# ============================================================
# Callback HMAC
# ============================================================
# _fire_callback <job_id> <state> <url>
# Envia POST HMAC-SHA256 com retry exponencial.
# Retorna: 0=sucesso, 1=todas tentativas falharam
_fire_callback() {
  local job_id="${1:?}"
  local state="${2:?}"
  local url="${3:?}"

  local secret
  secret="$(_read_callback_secret)"
  if [[ -z "$secret" ]]; then
    audit_worker callback_failed error "$job_id" reason "missing_callback_secret"
    set_state "$job_id" failed callback_failed "true" callback_error "missing_callback_secret"
    return 1
  fi

  # Construir payload JSON (schema_version=1)
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local payload
  payload="$(emit_json \
    schema_version "1" \
    job_id "$job_id" \
    state "$state" \
    ts "$ts")"

  # Calcular assinatura HMAC-SHA256
  local signature
  signature="sha256=$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$secret" -hex 2>/dev/null | awk '{print $NF}')"

  # Retry exponencial com backoff configurável
  local attempt=0
  local backoffs
  IFS=',' read -ra backoffs <<< "$WORKER_CALLBACK_BACKOFF"
  local max_attempts=$(( ${#backoffs[@]} + 1 ))

  while [[ $attempt -lt $max_attempts ]]; do
    audit_worker callback_attempt notice "$job_id" \
      attempt "@number:$((attempt + 1))" url "$url" state "$state"

    local http_code=0
    http_code="$(curl -sf --max-time 10 \
      -X POST \
      -H "Content-Type: application/json" \
      -H "X-Signature: ${signature}" \
      -d "$payload" \
      -o /dev/null \
      -w "%{http_code}" \
      "$url" 2>/dev/null)" || http_code=0

    if [[ "$http_code" =~ ^2 ]]; then
      set_state "$job_id" "$state" callback_attempts "@number:$((attempt + 1))"
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ $attempt -lt $max_attempts ]]; then
      local wait_sec="${backoffs[$((attempt - 1))]:-300}"
      log_event warning callback_attempt job_id "$job_id" \
        attempt "@number:$attempt" http_code "@number:${http_code}" wait_sec "@number:$wait_sec"
      audit_worker callback_failed warning "$job_id" \
        attempt "@number:$attempt" http_code "@number:${http_code}"
      # Em shutdown: abortar retries para não bloquear além do TimeoutStopSec
      if [[ "${_WORKER_SHUTDOWN:-0}" -eq 1 ]]; then
        log_event notice callback_aborted job_id "$job_id" reason "worker_shutting_down"
        break
      fi
      sleep "$wait_sec"
    fi
  done

  # Todas tentativas falharam
  set_state "$job_id" "$state" callback_failed "true" callback_attempts "@number:$max_attempts"
  audit_worker callback_failed warning "$job_id" reason "max_retries_exceeded"
  return 1
}

# ============================================================
# Feature O — worker_exec_* functions (D3.3/D3.4)
# Estas funções executam OCC diretamente (sem re-chamar manage.sh).
# São despachadas por process_job quando cmd ∈ Feature O verbs.
# ============================================================

# _occ_exec_safe <client> <subcmd> [args...]
# Wrapper que propaga erros com log mas não aborta o job inteiro.
_occ_exec_safe() {
  local client="$1"
  local subcmd="$2"
  shift 2
  occ_run "$client" "$subcmd" "$@" || {
    local rc=$?
    log_event warning occ_exec_failed client "$client" subcmd "$subcmd" exit_code "@number:$rc"
    return $rc
  }
}

# worker_exec_user_create <client> <args_json> <job_id>
worker_exec_user_create() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local username display_name email quota
  username="$(echo    "$args_json" | jq -r '.username      // ""')"
  display_name="$(echo "$args_json" | jq -r '.display_name  // ""')"
  email="$(echo       "$args_json" | jq -r '.email         // ""')"
  quota="$(echo       "$args_json" | jq -r '.quota         // ""')"
  local groups_json
  groups_json="$(echo "$args_json" | jq -c '.groups // []')"
  local subadmin_groups_json
  subadmin_groups_json="$(echo "$args_json" | jq -c '.subadmin_groups // []')"

  [[ -z "$username" ]] && { log_event warning worker_exec_user_create jid "$jid" reason "missing_username"; return 1; }

  # Ler e limpar senha efêmera do Redis
  local pw
  pw="$(read_and_clear_pending_pw "$jid")"

  # Exportar para occ_run usar --password-from-env
  [[ -n "$pw" ]] && export NEXTCLOUD_USER_PASSWORD="$pw"
  local _occ_args=("$username")
  [[ -n "$display_name" ]] && _occ_args+=("--display-name=${display_name}")
  _occ_exec_safe "$client" "user:add" "${_occ_args[@]}"
  local rc=$?
  unset NEXTCLOUD_USER_PASSWORD

  [[ $rc -ne 0 ]] && return $rc

  # Definir email via user:setting
  if [[ -n "$email" ]]; then
    _occ_exec_safe "$client" "user:setting" "$username" settings email "$email" || true
  fi

  # Definir quota via user:setting
  if [[ -n "$quota" ]]; then
    _occ_exec_safe "$client" "user:setting" "$username" files quota "$quota" || true
  fi

  # Adicionar a grupos
  local g
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    _occ_exec_safe "$client" "group:adduser" "$g" "$username" || true
  done < <(echo "$groups_json" | jq -r '.[]' 2>/dev/null)

  # Subadmin
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    _occ_exec_safe "$client" "user:setting" "$username" settings "subadmingroups[]" "$g" || true
  done < <(echo "$subadmin_groups_json" | jq -r '.[]' 2>/dev/null)

  return 0
}

# worker_exec_user_remove <client> <args_json> <job_id>
worker_exec_user_remove() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local username force
  username="$(echo "$args_json" | jq -r '.username // ""')"
  force="$(echo    "$args_json" | jq -r '.force    // false')"

  [[ -z "$username" ]] && { log_event warning worker_exec_user_remove jid "$jid" reason "missing_username"; return 1; }

  if [[ "$force" != "true" ]]; then
    # Verificar se usuário existe antes de tentar deletar
    _occ_exec_safe "$client" "user:info" "$username" >/dev/null 2>&1 || {
      log_event warning worker_exec_user_remove jid "$jid" username "$username" reason "user_not_found"
      return 16
    }
  fi

  _occ_exec_safe "$client" "user:delete" "$username"
}

# worker_exec_user_modify <client> <args_json> <job_id>
worker_exec_user_modify() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local username action value group
  username="$(echo "$args_json" | jq -r '.username // ""')"
  action="$(echo   "$args_json" | jq -r '.action   // ""')"
  value="$(echo    "$args_json" | jq -r '.value    // ""')"
  group="$(echo    "$args_json" | jq -r '.group    // ""')"

  [[ -z "$username" || -z "$action" ]] && { log_event warning worker_exec_user_modify jid "$jid" reason "missing_args"; return 1; }

  case "$action" in
    display-name)
      _occ_exec_safe "$client" "user:setting" "$username" settings displayname "$value" ;;
    email)
      _occ_exec_safe "$client" "user:setting" "$username" settings email "$value" ;;
    quota)
      _occ_exec_safe "$client" "user:setting" "$username" files quota "$value" ;;
    enable)
      _occ_exec_safe "$client" "user:enable" "$username" ;;
    disable)
      _occ_exec_safe "$client" "user:disable" "$username" ;;
    resend_welcome)
      _occ_exec_safe "$client" "user:setting" "$username" core lang "$value" 2>/dev/null || true
      log_event notice worker_exec_user_modify jid "$jid" username "$username" action "resend_welcome" status "no_occ_verb_available" ;;
    add_subadmin)
      _occ_exec_safe "$client" "user:setting" "$username" settings "subadmingroups[]" "$group" ;;
    remove_subadmin)
      log_event notice worker_exec_user_modify jid "$jid" username "$username" action "remove_subadmin" status "not_supported_by_occ" ;;
    *)
      log_event warning worker_exec_user_modify jid "$jid" action "$action" reason "unknown_action"
      return 1 ;;
  esac
}

# worker_exec_group_create <client> <args_json> <job_id>
worker_exec_group_create() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local groupname
  groupname="$(echo "$args_json" | jq -r '.groupname // ""')"
  [[ -z "$groupname" ]] && { log_event warning worker_exec_group_create jid "$jid" reason "missing_groupname"; return 1; }

  _occ_exec_safe "$client" "group:add" "$groupname"
}

# worker_exec_group_remove <client> <args_json> <job_id>
worker_exec_group_remove() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local groupname force
  groupname="$(echo "$args_json" | jq -r '.groupname // ""')"
  force="$(echo     "$args_json" | jq -r '.force     // false')"

  [[ -z "$groupname" ]] && { log_event warning worker_exec_group_remove jid "$jid" reason "missing_groupname"; return 1; }

  if [[ "$force" != "true" ]]; then
    _occ_exec_safe "$client" "group:info" "$groupname" >/dev/null 2>&1 || {
      log_event warning worker_exec_group_remove jid "$jid" groupname "$groupname" reason "group_not_found"
      return 16
    }
  fi

  _occ_exec_safe "$client" "group:delete" "$groupname"
}

# worker_exec_group_modify <client> <args_json> <job_id>
worker_exec_group_modify() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local groupname action new_name
  groupname="$(echo "$args_json" | jq -r '.groupname // ""')"
  action="$(echo    "$args_json" | jq -r '.action    // ""')"
  new_name="$(echo  "$args_json" | jq -r '.new_name  // ""')"

  [[ -z "$groupname" || -z "$action" ]] && { log_event warning worker_exec_group_modify jid "$jid" reason "missing_args"; return 1; }

  case "$action" in
    rename)
      # Requer Nextcloud >= 31 (guard: verificar se occ group:rename existe)
      _occ_exec_safe "$client" "group:add" "$new_name" || true
      log_event notice worker_exec_group_modify jid "$jid" groupname "$groupname" action "rename" new_name "$new_name" \
        note "nc_group_rename_requires_v31" ;;
    *)
      log_event warning worker_exec_group_modify jid "$jid" action "$action" reason "unknown_action"
      return 1 ;;
  esac
}

# worker_exec_apps_enable <client> <args_json> <job_id>
worker_exec_apps_enable() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local strict
  strict="$(echo "$args_json" | jq -r '.strict // false')"
  local failed=0 total=0 last_rc=1

  local app
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    total=$((total + 1))
    if _occ_exec_safe "$client" "app:enable" "$app"; then
      :
    else
      last_rc=$?
      if [[ "$strict" == "true" ]]; then
        log_event warning worker_exec_apps_enable jid "$jid" app "$app" reason "enable_failed_strict"
        return "$last_rc"
      else
        log_event warning worker_exec_apps_enable jid "$jid" app "$app" reason "enable_failed_tolerant"
        failed=$((failed + 1))
      fi
    fi
  done < <(echo "$args_json" | jq -r '.apps[]' 2>/dev/null)

  [[ $failed -gt 0 ]] && log_event warning worker_exec_apps_enable jid "$jid" failed_count "@number:$failed"
  [[ $total -gt 0 && $failed -eq $total ]] && return "$last_rc"
  return 0
}

# worker_exec_apps_disable <client> <args_json> <job_id>
worker_exec_apps_disable() {
  local client="$1"
  local args_json="$2"
  local jid="$3"

  local strict remove_after
  strict="$(echo        "$args_json" | jq -r '.strict                // false')"
  remove_after="$(echo  "$args_json" | jq -r '.remove_after_disable  // false')"
  local failed=0 total=0 last_rc=1

  local app
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    total=$((total + 1))
    if _occ_exec_safe "$client" "app:disable" "$app"; then
      :
    else
      last_rc=$?
      if [[ "$strict" == "true" ]]; then
        log_event warning worker_exec_apps_disable jid "$jid" app "$app" reason "disable_failed_strict"
        return "$last_rc"
      else
        log_event warning worker_exec_apps_disable jid "$jid" app "$app" reason "disable_failed_tolerant"
        failed=$((failed + 1))
        continue
      fi
    fi
    if [[ "$remove_after" == "true" ]]; then
      _occ_exec_safe "$client" "app:remove" "$app" || true
    fi
  done < <(echo "$args_json" | jq -r '.apps[]' 2>/dev/null)

  [[ $failed -gt 0 ]] && log_event warning worker_exec_apps_disable jid "$jid" failed_count "@number:$failed"
  [[ $total -gt 0 && $failed -eq $total ]] && return "$last_rc"
  return 0
}

# worker_exec_feature_o <cmd> <client> <args_json> <job_id>
# Dispatcher central para Feature O cmds no worker.
worker_exec_feature_o() {
  local cmd="$1"
  local client="$2"
  local args_json="$3"
  local jid="$4"

  case "$cmd" in
    user-create)    worker_exec_user_create  "$client" "$args_json" "$jid" ;;
    user-remove)    worker_exec_user_remove  "$client" "$args_json" "$jid" ;;
    user-modify)    worker_exec_user_modify  "$client" "$args_json" "$jid" ;;
    group-create)   worker_exec_group_create "$client" "$args_json" "$jid" ;;
    group-remove)   worker_exec_group_remove "$client" "$args_json" "$jid" ;;
    group-modify)   worker_exec_group_modify "$client" "$args_json" "$jid" ;;
    apps-enable)    worker_exec_apps_enable  "$client" "$args_json" "$jid" ;;
    apps-disable)   worker_exec_apps_disable "$client" "$args_json" "$jid" ;;
    *)
      log_event warning worker_exec_feature_o jid "$jid" cmd "$cmd" reason "unknown_feature_o_cmd"
      return 1 ;;
  esac
}

# FEATURE_O_CMDS — verbs despachados diretamente (não via nextcloud-manage argv)
readonly FEATURE_O_CMDS=(
  user-create user-remove user-modify
  group-create group-remove group-modify
  apps-enable apps-disable
)

_is_feature_o_cmd() {
  local c="$1"
  local v
  for v in "${FEATURE_O_CMDS[@]}"; do
    [[ "$c" == "$v" ]] && return 0
  done
  return 1
}

# ============================================================
# process_job <job_id>
# ============================================================
process_job() {
  local jid="${1:?process_job: job_id obrigatorio}"
  _WORKER_CURRENT_JOB="$jid"
  _redis_cli SET "nc:worker:current_job" "$jid" EX 86400 >/dev/null 2>&1 || true

  # Ler campos do job
  local raw
  raw="$(get_state "$jid")"

  if [[ "$raw" == "{}" ]]; then
    log_event warning run_start job_id "$jid" reason "job_not_found"
    _WORKER_CURRENT_JOB=""
    return
  fi

  local client cmd args_json callback
  client="$(echo "$raw" | jq -r '.client // ""')"
  cmd="$(echo "$raw" | jq -r '.cmd // ""')"
  args_json="$(echo "$raw" | jq -r '.args_json // "[]"')"
  callback="$(echo "$raw" | jq -r '.callback // ""')"

  # Validar campos mínimos
  if [[ -z "$client" || -z "$cmd" ]]; then
    log_event warning run_start job_id "$jid" reason "missing_fields" client "$client" cmd "$cmd"
    set_state "$jid" failed error_msg "missing_required_fields"
    _WORKER_CURRENT_JOB=""
    return
  fi

  # Adquirir client lock (evitar operações simultâneas no mesmo cliente)
  if ! client_lock_acquire "$client" "${CLIENT_LOCK_TTL_SEC:-60}"; then
    log_event warning run_start job_id "$jid" reason "client_locked" client "$client"
    # Re-enqueue para tentar depois (LPUSH para frente da fila)
    _redis_cli LPUSH "nc:jobs:queue" "$jid" >/dev/null 2>&1 || true
    set_state "$jid" queued
    _WORKER_CURRENT_JOB=""
    sleep 2
    return
  fi
  # shellcheck disable=SC2064
  trap "client_lock_release '${client}'" RETURN

  # Marcar como running
  set_state "$jid" running started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  audit_worker run_start notice "$jid" client "$client" cmd "$cmd"

  # Renovar worker lock + client lock durante execução
  (
    while true; do
      sleep 20  # renew a cada 20s; TTL=60s → margem 3× para jobs OCC longos
      worker_lock_renew "$_WORKER_PID" 2>/dev/null || true
      client_lock_renew "$client" 2>/dev/null || true
      _systemd_notify WATCHDOG=1
    done
  ) &
  local renew_pid=$!
  # shellcheck disable=SC2064
  trap "kill $renew_pid 2>/dev/null || true; client_lock_release '${client}'" RETURN

  # Feature O: dispatch direto sem re-chamar nextcloud-manage
  local exit_code=0
  local log_dir="${WORKER_JOBS_DIR}/${jid}"
  local log_file="${log_dir}/output.log"
  mkdir -p "$log_dir" 2>/dev/null || true
  export CURRENT_JOB_ID="$jid"
  export WORKER_JOBS_DIR

  if _is_feature_o_cmd "$cmd"; then
    OCC_CLIENT_LOCK_HELD="$client" worker_exec_feature_o "$cmd" "$client" "$args_json" "$jid" \
      >> "$log_file" 2>&1 || exit_code=$?
  else
    # Caminho legado: construir argv e chamar via job_runner
    local -a argv=()
    while IFS= read -r element; do
      argv+=("$element")
    done < <(echo "$args_json" | jq -r '.[]' 2>/dev/null)

    if [[ ${#argv[@]} -eq 0 || "${argv[0]:-}" != "nextcloud-manage" ]]; then
      log_event warning run_start job_id "$jid" reason "invalid_argv"
      set_state "$jid" failed error_msg "invalid_argv"
      _WORKER_CURRENT_JOB=""
      kill "$renew_pid" 2>/dev/null || true
      unset CURRENT_JOB_ID
      return
    fi

    exit_code="$(run_job "$jid" "$log_file" "${argv[@]}")" || exit_code=$?
  fi
  unset CURRENT_JOB_ID

  kill "$renew_pid" 2>/dev/null || true

  # Atualizar estado final
  local final_state="finished"
  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$exit_code" -ne 0 ]]; then
    final_state="failed"
    set_state "$jid" failed \
      exit_code "@number:${exit_code}" \
      failed_at "$finished_at"
    audit_worker run_finish warning "$jid" client "$client" cmd "$cmd" \
      exit_code "@number:${exit_code}"
  else
    set_state "$jid" finished \
      exit_code "@number:0" \
      finished_at "$finished_at"
    audit_worker run_finish notice "$jid" client "$client" cmd "$cmd" \
      exit_code "@number:0"
  fi

  _redis_cli DEL "nc:worker:current_job" >/dev/null 2>&1 || true
  _WORKER_CURRENT_JOB=""

  # Disparar callback se configurado
  if [[ -n "$callback" ]]; then
    _fire_callback "$jid" "$final_state" "$callback" || true
  fi
}

# ============================================================
# main_loop
# ============================================================
main_loop() {
  log_event notice worker_startup pid "$_WORKER_PID"
  _systemd_notify READY=1

  local watchdog_usec="${WATCHDOG_USEC:-0}"
  local watchdog_interval=0
  if [[ "$watchdog_usec" -gt 0 ]]; then
    watchdog_interval=$(( watchdog_usec / 2000000 ))
    [[ $watchdog_interval -lt 5 ]] && watchdog_interval=5
  fi

  local last_watchdog=0

  while [[ $_WORKER_SHUTDOWN -eq 0 ]]; do
    # Renova Redis worker lock
    if ! worker_lock_renew "$_WORKER_PID" 2>/dev/null; then
      # Lock expirou ou pid mismatch — retentar acquire
      if ! worker_lock_acquire "$_WORKER_PID" 2>/dev/null; then
        log_event warning worker_startup pid "$_WORKER_PID" reason "redis_lock_conflict"
        sleep 5
        continue
      fi
    fi

    # Watchdog systemd periódico
    if [[ $watchdog_interval -gt 0 ]]; then
      local now
      now="$(date +%s)"
      if (( now - last_watchdog >= watchdog_interval )); then
        _systemd_notify WATCHDOG=1
        last_watchdog="$now"
      fi
    fi

    # BRPOP bloqueante (timeout 30s para verificar SIGTERM)
    local job_id=""
    job_id="$(dequeue 30)" || true
    job_id="${job_id// /}"

    if [[ -z "$job_id" ]]; then
      # Timeout ou sinal — checar shutdown flag e continuar
      continue
    fi

    if [[ $_WORKER_SHUTDOWN -eq 1 ]]; then
      # Re-enqueue job não processado
      _redis_cli LPUSH "nc:jobs:queue" "$job_id" >/dev/null 2>&1 || true
      break
    fi

    process_job "$job_id"
  done

  log_event notice worker_shutdown pid "$_WORKER_PID" reason "normal_shutdown"
}

# ============================================================
# Inicialização
# ============================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Não executar como daemon em modo de teste
  if [[ "${WORKER_TEST_MODE:-0}" == "1" ]]; then
    log_event notice worker_test_mode pid "$_WORKER_PID"
    exit 0
  fi

  # Adquirir flock (defesa primária contra múltiplas instâncias)
  _acquire_flock

  # Adquirir Redis worker lock
  if ! worker_lock_acquire "$_WORKER_PID"; then
    log_event warning worker_startup pid "$_WORKER_PID" reason "redis_lock_conflict_startup"
    exit 1
  fi

  # Limpar job stale de crash anterior
  _cleanup_stale_job

  # Criar diretório de jobs
  mkdir -p "$WORKER_JOBS_DIR" 2>/dev/null || true

  # Iniciar loop principal
  main_loop
fi
