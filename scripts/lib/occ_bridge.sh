#!/usr/bin/env bash
# scripts/lib/occ_bridge.sh
#
# Bridge entre nextcloud-manage e o binário OCC dentro do container <cliente>-app.
# Materializa a allowlist canônica de docs/CONTRACTS.md §3.10.1 (Feature P).
#
# Implementação Sprint D3.1:
#   - occ_run real com validação allowlist/blocklist, client-lock, timeout, parsed_result
#   - Sprint D4: superfície CLI completa via `<cliente> occ-exec <subcmd>`
#
# Critério de aceite do drift gate (.github/workflows/contracts-check.yml):
#   - O array OCC_ALLOWLIST DEVE conter EXATAMENTE os 35 subcomandos da
#     tabela §3.10.1 de docs/CONTRACTS.md (revisão 0.3).
#   - Mudanças aqui exigem PR + bump de schema_version em docs/CONTRACTS.md.
# Source guard
[ "${OCC_BRIDGE_SH_SOURCED:-0}" = "1" ] && return 0
readonly OCC_BRIDGE_SH_SOURCED=1

set -euo pipefail

OCC_BRIDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/job_queue.sh
source "${OCC_BRIDGE_LIB_DIR}/job_queue.sh"
# shellcheck source=scripts/lib/ssh_audit.sh
source "${OCC_BRIDGE_LIB_DIR}/ssh_audit.sh"

# shellcheck disable=SC2034
OCC_BRIDGE_SH_VERSION="1.0.0"

# ─────────────────────────────────────────────────────────────────────────────
# OCC_ALLOWLIST — fonte: docs/CONTRACTS.md §3.10.1 (single source of truth)
# Mantenha em ordem alfabética para facilitar diff em PR.
# ─────────────────────────────────────────────────────────────────────────────
declare -ar OCC_ALLOWLIST=(
  "app:disable"
  "app:enable"
  "app:install"
  "app:list"
  "app:remove"
  "config:app:delete"
  "config:app:get"
  "config:app:list"
  "config:app:set"
  "config:system:get"
  "db:add-missing-columns"
  "db:add-missing-indices"
  "files:cleanup"
  "files:repair-tree"
  "files:scan"
  "group:add"
  "group:adduser"
  "group:delete"
  "group:info"
  "group:list"
  "group:removeuser"
  "maintenance:mode"
  "maintenance:repair"
  "notification:generate"
  "theming:config"
  "user:add"
  "user:delete"
  "user:disable"
  "user:enable"
  "user:info"
  "user:list"
  "user:resetpassword"
  "user:setting"
  "versions:cleanup"
  "versions:expire"
)

# ─────────────────────────────────────────────────────────────────────────────
# OCC_BLOCKLIST — fonte: docs/CONTRACTS.md §3.10.2 (lista negra fixa)
# Mesmo se um futuro PR tentar adicionar à OCC_ALLOWLIST, o bridge rejeita.
# Padrões com '*' são prefix-match (encryption:* casa encryption:enable, etc.)
# ─────────────────────────────────────────────────────────────────────────────
declare -ar OCC_BLOCKLIST=(
  "encryption:*"
  "db:execute"
  "db:convert-type"
  "db:convert-mysql-charset"
  "config:system:set"
  "update:check"
  "upgrade"
  "security:certificates*"
)

# Subcomandos que suportam --output=json (parsed_result preenchido em §4.9).
# Fonte: coluna "−output=json?" da tabela §3.10.1.
declare -ar OCC_JSON_CAPABLE=(
  "user:info"
  "user:list"
  "group:list"
  "group:info"
  "app:list"
  "config:app:get"
  "config:app:list"
  "config:system:get"
)

# ─────────────────────────────────────────────────────────────────────────────
# API pública
# ─────────────────────────────────────────────────────────────────────────────

# SET_STATE_OCC_VERBS — subcomandos que alteram estado e precisam de client-lock.
# Fonte: CONTRACTS.md §3.10.1 coluna "State-changing".
readonly -a SET_STATE_OCC_VERBS=(
  "user:add"      "user:delete"       "user:disable"       "user:enable"
  "user:setting"  "user:resetpassword"
  "group:add"     "group:delete"      "group:adduser"      "group:removeuser"
  "app:enable"    "app:disable"       "app:install"        "app:remove"
  "maintenance:mode"  "files:cleanup" "files:repair-tree"
  "config:app:set"    "config:app:delete"
  "versions:cleanup"  "theming:config"
  "notification:generate"
  "db:add-missing-indices" "db:add-missing-columns"
)

# occ_is_blocklisted <subcmd>
#   Retorna 0 se <subcmd> casa algum padrão de OCC_BLOCKLIST.
occ_is_blocklisted() {
  local subcmd="${1:-}"
  [[ -n "$subcmd" ]] || return 1
  local pattern
  for pattern in "${OCC_BLOCKLIST[@]}"; do
    # shellcheck disable=SC2254
    case "$subcmd" in
      ${pattern}) return 0 ;;
    esac
  done
  return 1
}

# occ_is_state_changing <subcmd>
#   Retorna 0 se o subcmd é state-changing (necessita client-lock).
occ_is_state_changing() {
  local s="${1:-}"
  local v
  for v in "${SET_STATE_OCC_VERBS[@]}"; do
    [[ "$s" == "$v" ]] && return 0
  done
  return 1
}

# occ_is_allowed <subcmd>
#   Retorna 0 se <subcmd> está em OCC_ALLOWLIST e NÃO casa nenhum padrão de
#   OCC_BLOCKLIST. Caso contrário, retorna 1.
occ_is_allowed() {
  local subcmd="${1:-}"
  [[ -n "$subcmd" ]] || return 1

  local pattern
  for pattern in "${OCC_BLOCKLIST[@]}"; do
    # shellcheck disable=SC2254 # OCC_BLOCKLIST entries are intentional glob patterns.
    case "$subcmd" in
      ${pattern}) return 1 ;;
    esac
  done

  local allowed
  for allowed in "${OCC_ALLOWLIST[@]}"; do
    [[ "$subcmd" == "$allowed" ]] && return 0
  done

  return 1
}

# occ_supports_json <subcmd>
#   Retorna 0 se manage-cli deve passar --output=json automaticamente.
occ_supports_json() {
  local subcmd="${1:-}"
  local s
  for s in "${OCC_JSON_CAPABLE[@]}"; do
    [[ "$subcmd" == "$s" ]] && return 0
  done
  return 1
}

# occ_run <client> <subcmd> [args...]
#   Executa um subcomando OCC dentro do container <client>-app.
#   Contrato (docs/CONTRACTS.md §4.9 — OccExecResult):
#     - Valida subcmd contra OCC_ALLOWLIST + OCC_BLOCKLIST. Exit 100 se negado.
#     - Verifica container rodando. Exit 14 (instance_not_running) se parado.
#     - Pega client-lock se verb é state-changing. Exit 17 se bloqueado.
#     - Executa via array argv: docker exec <c>-app php occ <subcmd> "${args[@]}"
#     - Senha via NEXTCLOUD_USER_PASSWORD env + --password-from-env. Nunca argv.
#     - Timeout: WORKER_OCC_TIMEOUT_SEC (default 60s); kill-after 30s extra.
#     - Audit log NDJSON (nextcloud-saas-occ-exec) para cada invocação.
#     - parsed_result preenchido quando subcmd ∈ OCC_JSON_CAPABLE e exit=0.
#   Exit codes:
#     0  — sucesso
#     5  — argumentos inválidos
#     14 — instance_not_running
#     15 — occ_timeout
#     16 — occ_command_failed (exit_code != 0)
#     17 — client_busy_async_job_running
#     100 — occ_command_not_allowed
occ_run() {
  local client="${1:-}"
  local subcmd="${2:-}"
  shift 2 || true
  local -a args=("$@")

  if [[ -z "$client" || -z "$subcmd" ]]; then
    emit_json error "invalid_arguments" message "client and subcmd required" >&2
    return 5
  fi

  # 1. Blocklist check (explícita antes de allowlist para mensagem clara)
  if occ_is_blocklisted "$subcmd"; then
    audit_occ "$client" "$subcmd" rejected reason "blocklisted"
    emit_json error "occ_command_not_allowed" message "subcommand ${subcmd} is blocklisted" subcommand "$subcmd"
    return 100
  fi

  # 2. Allowlist check
  if ! occ_is_allowed "$subcmd"; then
    audit_occ "$client" "$subcmd" rejected reason "not_in_allowlist"
    emit_json error "occ_command_not_allowed" message "subcommand ${subcmd} not in allowlist" subcommand "$subcmd"
    return 100
  fi

  # 3. Container check
  local container="${client}-app"
  if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q "^true$"; then
    audit_occ "$client" "$subcmd" rejected reason "instance_not_running"
    emit_json error "instance_not_running" message "container ${container} is not running" container "$container"
    return 14
  fi

  # 4. Client lock para verbs state-changing
  local need_lock=false
  if occ_is_state_changing "$subcmd"; then
    if ! client_lock_acquire "$client" "${CLIENT_LOCK_TTL_SEC:-5}"; then
      audit_occ "$client" "$subcmd" rejected reason "client_locked"
      emit_json error "client_busy_async_job_running" message "client ${client} is locked by another operation"
      return 17
    fi
    need_lock=true
  fi

  _occ_run_release_lock() {
    [[ "$need_lock" == true ]] && client_lock_release "$client" || true
  }
  trap '_occ_run_release_lock' RETURN

  # 5. Build OCC args array — NUNCA bash -c, NUNCA string-concat
  local -a occ_args=("$subcmd" "${args[@]+"${args[@]}"}")
  if occ_supports_json "$subcmd"; then
    occ_args+=("--output=json")
  fi
  # Senha via env, nunca argv
  if [[ -n "${NEXTCLOUD_USER_PASSWORD:-}" ]]; then
    occ_args+=("--password-from-env")
  fi

  # 6. Exec com timeout duro
  local start_ms
  start_ms="$(date +%s%3N)"
  local stdout_tmp stderr_tmp
  stdout_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  local exit_code=0

  local -a docker_cmd=("docker" "exec")
  [[ -n "${NEXTCLOUD_USER_PASSWORD:-}" ]] && docker_cmd+=("-e" "NEXTCLOUD_USER_PASSWORD")
  docker_cmd+=("$container" "php" "occ" "${occ_args[@]}")

  timeout --signal=TERM --kill-after=30 "${WORKER_OCC_TIMEOUT_SEC:-60}" \
    "${docker_cmd[@]}" \
    >"$stdout_tmp" 2>"$stderr_tmp" || exit_code=$?

  local duration_ms
  duration_ms=$(( $(date +%s%3N) - start_ms ))
  local stdout_content stderr_content
  stdout_content="$(<"$stdout_tmp")"
  stderr_content="$(<"$stderr_tmp")"
  rm -f "$stdout_tmp" "$stderr_tmp"

  # 7. Detectar timeout (exit 124 = timeout SIGTERM; 137 = SIGKILL após kill-after)
  if [[ "$exit_code" -eq 124 || "$exit_code" -eq 137 ]]; then
    audit_occ "$client" "$subcmd" timeout duration_ms "$duration_ms" timeout_sec "${WORKER_OCC_TIMEOUT_SEC:-60}"
    emit_json error "occ_timeout" message "subcommand timed out after ${WORKER_OCC_TIMEOUT_SEC:-60}s" subcommand "$subcmd"
    return 15
  fi

  # 8. Detectar falha OCC
  if [[ "$exit_code" -ne 0 ]]; then
    audit_occ "$client" "$subcmd" failed exit_code "$exit_code" duration_ms "$duration_ms"
    emit_json \
      error "occ_command_failed" \
      message "occ exited with code ${exit_code}" \
      subcommand "$subcmd" \
      exit_code "@number:${exit_code}" \
      stdout "$stdout_content" \
      stderr "$stderr_content"
    return 16
  fi

  # 9. parsed_result (best-effort, apenas OCC_JSON_CAPABLE)
  local parsed_json="null"
  if occ_supports_json "$subcmd"; then
    if echo "$stdout_content" | jq -e . >/dev/null 2>&1; then
      parsed_json="$(echo "$stdout_content" | jq -c .)"
    fi
  fi

  audit_occ "$client" "$subcmd" success exit_code 0 duration_ms "$duration_ms"

  emit_json \
    schema_version "1" \
    occ_command "$subcmd" \
    exit_code "@number:0" \
    stdout "$stdout_content" \
    stderr "$stderr_content" \
    parsed_result "@json:${parsed_json}" \
    duration_ms "@number:${duration_ms}"
  return 0
}

# Permite source sem executar; quando invocado direto, mostra a allowlist.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf 'OCC_ALLOWLIST (%d entries):\n' "${#OCC_ALLOWLIST[@]}"
  printf '  %s\n' "${OCC_ALLOWLIST[@]}"
  printf '\nOCC_BLOCKLIST (%d patterns):\n' "${#OCC_BLOCKLIST[@]}"
  printf '  %s\n' "${OCC_BLOCKLIST[@]}"
fi
