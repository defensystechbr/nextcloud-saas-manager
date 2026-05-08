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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Libs
# ============================================================
# shellcheck source=scripts/lib/validators.sh
source "${SCRIPT_DIR}/lib/validators.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${SCRIPT_DIR}/lib/output_json.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${SCRIPT_DIR}/lib/job_queue.sh"
# shellcheck source=scripts/lib/job_runner.sh
source "${SCRIPT_DIR}/lib/job_runner.sh"
# shellcheck source=scripts/lib/ssh_audit.sh
source "${SCRIPT_DIR}/lib/ssh_audit.sh"

# ============================================================
# Configuração (via env ou defaults)
# ============================================================
WORKER_JOBS_DIR="${WORKER_JOBS_DIR:-/opt/nextcloud-saas/jobs}"
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

    # Callback best-effort após SIGTERM
    local callback
    callback="$(_redis_cli HGET "nc:jobs:${_WORKER_CURRENT_JOB}" "callback" 2>/dev/null || echo "")"
    if [[ -n "$callback" ]]; then
      _fire_callback "$_WORKER_CURRENT_JOB" "failed" "$callback" || true
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
  if [[ -n "$secret" ]]; then
    signature="sha256=$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$secret" -hex 2>/dev/null | awk '{print $NF}')"
  else
    signature="sha256=unsigned"
  fi

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
      sleep "$wait_sec"
    fi
  done

  # Todas tentativas falharam
  set_state "$job_id" "$state" callback_failed "true" callback_attempts "@number:$max_attempts"
  audit_worker callback_failed warning "$job_id" reason "max_retries_exceeded"
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
  if ! client_lock_acquire "$client" "${CLIENT_LOCK_TTL_SEC:-5}"; then
    log_event warning run_start job_id "$jid" reason "client_locked" client "$client"
    # Re-enqueue para tentar depois (LPUSH para frente da fila)
    _redis_cli LPUSH "nc:jobs:queue" "$jid" >/dev/null 2>&1 || true
    set_state "$jid" queued
    _WORKER_CURRENT_JOB=""
    sleep 2
    return
  fi
  trap "client_lock_release '${client}'" RETURN

  # Marcar como running
  set_state "$jid" running started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  audit_worker run_start notice "$jid" client "$client" cmd "$cmd"

  # Renovar worker lock + client lock durante execução
  (
    while true; do
      sleep 30
      worker_lock_renew "$_WORKER_PID" 2>/dev/null || true
      client_lock_renew "$client" 2>/dev/null || true
      _systemd_notify WATCHDOG=1
    done
  ) &
  local renew_pid=$!
  trap "kill $renew_pid 2>/dev/null; client_lock_release '${client}'" RETURN

  # Construir argv a partir de args_json (array de strings)
  local -a argv=()
  while IFS= read -r element; do
    argv+=("$element")
  done < <(echo "$args_json" | jq -r '.[]' 2>/dev/null)

  if [[ ${#argv[@]} -eq 0 || "${argv[0]:-}" != "nextcloud-manage" ]]; then
    log_event warning run_start job_id "$jid" reason "invalid_argv"
    set_state "$jid" failed error_msg "invalid_argv"
    _WORKER_CURRENT_JOB=""
    kill "$renew_pid" 2>/dev/null || true
    return
  fi

  # Log path
  local log_dir="${WORKER_JOBS_DIR}/${jid}"
  local log_file="${log_dir}/output.log"
  mkdir -p "$log_dir" 2>/dev/null || true

  # Executar via job_runner
  local exit_code=0
  exit_code="$(run_job "$jid" "$log_file" "${argv[@]}")" || exit_code=$?

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
