#!/usr/bin/env bash
# scripts/lib/occ_bridge.sh
#
# Bridge entre nextcloud-manage e o binário OCC dentro do container <cliente>-app.
# Materializa a allowlist canônica de docs/CONTRACTS.md §3.10.1 (Feature P).
#
# ESTE É UM SKELETON gerado por /devops planejar. A implementação real (parsing,
# docker exec, audit log NDJSON, scrub de NC_PASS, parsed_result via --output=json,
# client-lock em nc:client_lock:<cliente>) é da skill `dev` durante:
#   • Sprint S2 (Parte 1): utilitário interno consumido por user-group-apps
#   • Sprint S3 (Parte 2): superfície CLI completa via `<cliente> occ-exec <subcmd>`
#
# Critério de aceite do drift gate (.github/workflows/contracts-check.yml):
#   - O array OCC_ALLOWLIST DEVE conter EXATAMENTE os 35 subcomandos da
#     tabela §3.10.1 de docs/CONTRACTS.md (revisão 0.3).
#   - Mudanças aqui exigem PR + bump de schema_version em docs/CONTRACTS.md.

set -euo pipefail

# shellcheck disable=SC2034  # consumido por manage.sh
OCC_BRIDGE_SH_VERSION="0.0.1-skeleton"

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
# API pública (a ser implementada nos Sprints S2/S3)
# ─────────────────────────────────────────────────────────────────────────────

# occ_is_allowed <subcmd>
#   Retorna 0 se <subcmd> está em OCC_ALLOWLIST e NÃO casa nenhum padrão de
#   OCC_BLOCKLIST. Caso contrário, retorna 1.
occ_is_allowed() {
  local subcmd="${1:-}"
  [[ -n "$subcmd" ]] || return 1

  local pattern
  for pattern in "${OCC_BLOCKLIST[@]}"; do
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
#   Implementação real fica para o Sprint S2 (Parte 1) e S3 (Parte 2).
#   Contrato (docs/CONTRACTS.md §4.9 — OccExecResult):
#     - Pega client-lock em nc:client_lock:<client> (SET NX EX 5).
#     - Valida via occ_is_allowed; se falhar, exit 100 (SHIM_INVALID_COMMAND)
#       ou 102 (SHIM_OCC_NOT_ALLOWED).
#     - Executa: docker exec -e NC_PASS="$pass" -e NC_LANG=en_US <c>-app php occ <subcmd> "${args[@]}"
#       (NC_PASS apenas se subcmd ∈ {user:add, user:resetpassword}; nunca via argv).
#     - Timeout duro: WORKER_OCC_TIMEOUT_SEC (default 60s).
#     - Sanitiza output e emite NDJSON em journald (tag nextcloud-saas-occ-exec):
#         {"event":"occ_exec","client":...,"occ_subcommand":...,"args":[...],
#          "caller_key_id":...,"exit_code":...,"duration_ms":...,
#          "started_at":...,"finished_at":...}
#     - Se occ_supports_json e exit_code=0, parseia stdout e popula parsed_result.
occ_run() {
  local client="${1:-}"
  local subcmd="${2:-}"
  shift 2 || true
  local -a args=("$@")

  if [[ -z "$client" || -z "$subcmd" ]]; then
    printf '{"error":"invalid_arguments","message":"client and subcmd required"}\n' >&2
    return 5
  fi

  if ! occ_is_allowed "$subcmd"; then
    printf '{"error":"occ_command_not_allowed","subcommand":"%s"}\n' "$subcmd" >&2
    return 102
  fi

  printf '{"error":"not_implemented","sprint":"S2-P1 or S3-P2","subcommand":"%s","args_count":%d}\n' \
    "$subcmd" "${#args[@]}" >&2
  return 70
}

# Permite source sem executar; quando invocado direto, mostra a allowlist.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf 'OCC_ALLOWLIST (%d entries):\n' "${#OCC_ALLOWLIST[@]}"
  printf '  %s\n' "${OCC_ALLOWLIST[@]}"
  printf '\nOCC_BLOCKLIST (%d patterns):\n' "${#OCC_BLOCKLIST[@]}"
  printf '  %s\n' "${OCC_BLOCKLIST[@]}"
fi
