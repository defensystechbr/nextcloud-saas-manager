#!/bin/bash
# scripts/lib/validators.sh — Validadores puros para Nextcloud SaaS Manager
# Todas as funções são puras: sem efeito colateral, sem I/O, retornam 0=válido ou 1=inválido.
# Source guard
[ "${VALIDATORS_SH_SOURCED:-0}" = "1" ] && return 0
readonly VALIDATORS_SH_SOURCED=1

set -euo pipefail

# ============================================================
# Regex compiladas como readonly (CONTRACTS §3.4)
# ============================================================
readonly RE_CLIENT_NAME='^[a-z0-9-]{1,64}$'
readonly RE_FQDN='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
readonly RE_UUID_V4='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# Comandos que aceitam --async (CONTRACTS §3.6)
readonly ASYNC_ALLOWED=(
  create remove backup restore update stop start
  user-create user-remove user-modify
  group-create group-remove group-modify
  apps-enable apps-disable
)

# Namespaces hierárquicos — token-2 deve ser checado ANTES de tratar como FQDN (CONTRACTS §3.6)
# shellcheck disable=SC2034 # Consumido por callers apos source (manage.sh/dispatch.sh).
readonly RESERVED_NAMESPACES=(user group apps occ-exec)

# ============================================================
# is_valid_client_name <name>
# usage: is_valid_client_name "acme"
# returns: 0=válido, 1=inválido
# CONTRACTS §3.4: ^[a-z0-9-]{1,64}$; "_" reservado para "no domain"
# ============================================================
is_valid_client_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  [[ "$name" != "_" ]] || return 1
  [[ "$name" =~ $RE_CLIENT_NAME ]]
}

# ============================================================
# is_valid_fqdn <fqdn>
# usage: is_valid_fqdn "nextcloud.example.com"
# returns: 0=válido, 1=inválido
# ============================================================
is_valid_fqdn() {
  local fqdn="${1:-}"
  [[ -n "$fqdn" ]] || return 1
  [[ "${#fqdn}" -le 253 ]] || return 1
  [[ "$fqdn" =~ $RE_FQDN ]]
}

# ============================================================
# is_valid_uuid_v4 <uuid>
# usage: is_valid_uuid_v4 "550e8400-e29b-41d4-a716-446655440000"
# returns: 0=válido, 1=inválido
# Apenas lowercase aceito (padronização para hash de idempotency).
# ============================================================
is_valid_uuid_v4() {
  local uuid="${1:-}"
  [[ -n "$uuid" ]] || return 1
  [[ "$uuid" =~ $RE_UUID_V4 ]]
}

# ============================================================
# is_valid_https_url <url>
# usage: is_valid_https_url "https://api.example.com/hook"
# returns: 0=válido, 1=inválido
# Rejeita IPs RFC1918 (SSRF defense: CONTRACTS §3.7)
# ============================================================
is_valid_https_url() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 1

  # Deve começar com https://
  [[ "$url" == https://* ]] || return 1

  # Extrair host (tudo entre https:// e próximo / ou fim)
  local without_scheme="${url#https://}"
  local host="${without_scheme%%/*}"
  # Remover porta se presente
  host="${host%%:*}"

  [[ -n "$host" ]] || return 1

  # Rejeitar IPs RFC1918 e loopback
  # 10.0.0.0/8
  local re_10='^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  # 172.16.0.0/12 (172.16 - 172.31)
  local re_172='^172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}$'
  # 192.168.0.0/16
  local re_192='^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$'
  # 127.0.0.0/8
  local re_127='^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'

  [[ "$host" =~ $re_10  ]] && return 1
  [[ "$host" =~ $re_172 ]] && return 1
  [[ "$host" =~ $re_192 ]] && return 1
  [[ "$host" =~ $re_127 ]] && return 1

  return 0
}

# ============================================================
# is_async_allowed_cmd <cmd>
# usage: is_async_allowed_cmd "create"
# returns: 0=permite async, 1=não permite
# ============================================================
is_async_allowed_cmd() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || return 1
  local c
  for c in "${ASYNC_ALLOWED[@]}"; do
    [[ "$c" == "$cmd" ]] && return 0
  done
  return 1
}

# ============================================================
# parse_global_flags <argv...>
# usage: parse_global_flags "$@"
# Exporta: declare -gA PARSED_FLAGS com chaves:
#   async, idempotency_key, callback, json, dry_run, confirm,
#   payload_stdin, staging_id, strict, no_async_pickup
# returns: 0=ok, 5=erro de validação
# ============================================================
parse_global_flags() {
  declare -gA PARSED_FLAGS=(
    [async]=""
    [idempotency_key]=""
    [callback]=""
    [json]=""
    [dry_run]=""
    [confirm]=""
    [payload_stdin]=""
    [staging_id]=""
    [strict]=""
    [no_async_pickup]=""
  )

  if has_password_in_argv "$@"; then
    echo "parse_global_flags: --password em argv proibido; use --payload-stdin (password_in_argv_forbidden)" >&2
    return 5
  fi

  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    local arg="${args[$i]}"
    case "$arg" in
      # Flags booleanas — rejeitar forma --flag=value
      --async|--json|--dry-run|--payload-stdin|--strict|--no-async-pickup)
        local key="${arg#--}"
        key="${key//-/_}"
        PARSED_FLAGS[$key]="1"
        ;;
      --async=*|--json=*|--dry-run=*|--payload-stdin=*|--strict=*|--no-async-pickup=*)
        echo "parse_global_flags: erro — flag booleana nao aceita '=value': ${arg}" >&2
        return 5
        ;;
      # --confirm aceita forma booleana OU --confirm=<value>
      --confirm)
        PARSED_FLAGS[confirm]="1"
        ;;
      --confirm=*)
        PARSED_FLAGS[confirm]="${arg#--confirm=}"
        ;;
      # Flags com valor — aceitar --key=value ou --key value
      --idempotency-key=*)
        PARSED_FLAGS[idempotency_key]="${arg#--idempotency-key=}"
        ;;
      --idempotency-key)
        i=$((i + 1))
        PARSED_FLAGS[idempotency_key]="${args[$i]:-}"
        ;;
      --callback=*)
        PARSED_FLAGS[callback]="${arg#--callback=}"
        ;;
      --callback)
        i=$((i + 1))
        PARSED_FLAGS[callback]="${args[$i]:-}"
        ;;
      --staging-id=*)
        PARSED_FLAGS[staging_id]="${arg#--staging-id=}"
        ;;
      --staging-id)
        i=$((i + 1))
        PARSED_FLAGS[staging_id]="${args[$i]:-}"
        ;;
      *)
        # Argumento posicional ou flag desconhecida — ignorar (não é responsabilidade deste parser)
        ;;
    esac
    i=$((i + 1))
  done

  # Validação: --callback requer --async
  if [[ -n "${PARSED_FLAGS[callback]}" && -z "${PARSED_FLAGS[async]}" ]]; then
    echo "parse_global_flags: --callback requer --async (callback_requires_async)" >&2
    return 5
  fi

  # Validação: --idempotency-key só faz sentido no fluxo async
  if [[ -n "${PARSED_FLAGS[idempotency_key]}" && -z "${PARSED_FLAGS[async]}" ]]; then
    echo "parse_global_flags: --idempotency-key requer --async (idempotency_requires_async)" >&2
    return 5
  fi

  # Validação: --idempotency-key deve ser UUID v4
  if [[ -n "${PARSED_FLAGS[idempotency_key]}" ]]; then
    if ! is_valid_uuid_v4 "${PARSED_FLAGS[idempotency_key]}"; then
      echo "parse_global_flags: --idempotency-key deve ser UUID v4 lowercase: ${PARSED_FLAGS[idempotency_key]}" >&2
      return 5
    fi
  fi

  # Validação: --callback deve ser HTTPS sem RFC1918
  if [[ -n "${PARSED_FLAGS[callback]}" ]]; then
    if ! is_valid_https_url "${PARSED_FLAGS[callback]}"; then
      echo "parse_global_flags: --callback invalido (deve ser HTTPS e nao RFC1918): ${PARSED_FLAGS[callback]}" >&2
      return 5
    fi
  fi

  # Validação: --staging-id deve ser UUID v4
  if [[ -n "${PARSED_FLAGS[staging_id]}" ]]; then
    if ! is_valid_uuid_v4 "${PARSED_FLAGS[staging_id]}"; then
      echo "parse_global_flags: --staging-id deve ser UUID v4 lowercase: ${PARSED_FLAGS[staging_id]}" >&2
      return 5
    fi
  fi

  return 0
}

# ============================================================
# has_password_in_argv <argv...>
# Detecta --password=* ou --password em qualquer argumento.
# Retorna: 0=detectado (proibido), 1=limpo
# CONTRACTS §3.6: senha DEVE vir via --payload-stdin
# ============================================================
has_password_in_argv() {
  local arg
  for arg in "$@"; do
    [[ "$arg" == --password=* || "$arg" == --password ]] && return 0
  done
  return 1
}

# ============================================================
# compute_args_hash <arg1> [arg2 ...]
# Calcula sha256sum dos args posicionais normalizados.
# Retorna: string hexadecimal de 64 chars
# ============================================================
compute_args_hash() {
  printf '%s\n' "$@" | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}
