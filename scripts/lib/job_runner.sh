#!/bin/bash
# scripts/lib/job_runner.sh — Executa jobs via nextcloud-manage com timeout e sanitização
# Source guard
[ "${JOB_RUNNER_SH_SOURCED:-0}" = "1" ] && return 0
readonly JOB_RUNNER_SH_SOURCED=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/output_json.sh
source "${SCRIPT_DIR}/output_json.sh"
# shellcheck source=scripts/lib/validators.sh
source "${SCRIPT_DIR}/validators.sh"

# ============================================================
# sanitize_log <log_path>
# Aplica sanitize_secrets em arquivo de log (in-place via temp file).
# ============================================================
sanitize_log() {
  local log_path="${1:?sanitize_log: log_path obrigatorio}"
  [[ -f "$log_path" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  # Processar cada linha com sanitize_secrets
  while IFS= read -r line; do
    sanitize_secrets "$line"
  done < "$log_path" > "$tmp"

  mv "$tmp" "$log_path"
}

# ============================================================
# run_job <job_id> <log_path> <argv0> [<argv1> ...]
# Executa nextcloud-manage com timeout; captura saída em log_path.
# Sanitiza log após execução.
# Retorna: exit_code do comando via stdout.
#
# Security: argv[0] DEVE ser "nextcloud-manage" (exit 5 caso contrário).
# ============================================================
run_job() {
  local job_id="${1:?run_job: job_id obrigatorio}"
  local log_path="${2:?run_job: log_path obrigatorio}"
  shift 2

  local argv=("$@")

  # Security gate: argv[0] deve ser nextcloud-manage
  if [[ "${argv[0]:-}" != "nextcloud-manage" ]]; then
    echo "run_job: security — argv[0] deve ser 'nextcloud-manage', recebido: '${argv[0]:-}'" >&2
    return 5
  fi

  # Criar log_path com permissões corretas
  local log_dir
  log_dir="$(dirname "$log_path")"
  if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir" 2>/dev/null || {
      echo "run_job: nao foi possivel criar diretorio de log: ${log_dir}" >&2
      return 1
    }
  fi

  # Criar arquivo de log com permissões seguras
  # install -m 0640 falha se não for root; fallback para touch em ambiente de teste
  if ! install -m 0640 -o root -g adm /dev/null "$log_path" 2>/dev/null; then
    touch "$log_path" 2>/dev/null || {
      echo "run_job: nao foi possivel criar log_path: ${log_path}" >&2
      return 1
    }
  fi

  local timeout_sec="${WORKER_JOB_TIMEOUT_SEC:-1800}"
  local exit_code=0

  # Executar com timeout — append stdout+stderr ao log
  timeout --signal=TERM --kill-after=30 "$timeout_sec" \
    -- "${argv[@]}" --json --no-async-pickup \
    >> "$log_path" 2>&1 || exit_code=$?

  # Sanitizar log após execução (mesmo em caso de falha)
  sanitize_log "$log_path"

  echo "$exit_code"
  return 0
}
