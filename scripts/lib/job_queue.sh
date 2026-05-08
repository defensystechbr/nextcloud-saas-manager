#!/bin/bash
# scripts/lib/job_queue.sh — Operações sobre a fila de jobs Redis
# dbindex 16 (ARCH-001, CONTRACTS §6.1). Prefixo nc: em todas as chaves.
# NUNCA usar KEYS nc:jobs:* — sempre SCAN MATCH ... COUNT 1000.
# Source guard
[ "${JOB_QUEUE_SH_SOURCED:-0}" = "1" ] && return 0
readonly JOB_QUEUE_SH_SOURCED=1

set -euo pipefail

# Dependências
# shellcheck source=scripts/lib/validators.sh
JOB_QUEUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${JOB_QUEUE_LIB_DIR}/validators.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${JOB_QUEUE_LIB_DIR}/output_json.sh"

# ============================================================
# Configuração Redis — via env vars (sem state interno)
# ============================================================
# WORKER_REDIS_HOST    (default: 127.0.0.1)
# WORKER_REDIS_PORT    (default: 6379)
# WORKER_REDIS_DB      (default: 16)
# WORKER_REDIS_PASS    (optional)

_redis_cli() {
  local host="${WORKER_REDIS_HOST:-127.0.0.1}"
  local port="${WORKER_REDIS_PORT:-6379}"
  local db="${WORKER_REDIS_DB:-16}"
  local pass="${WORKER_REDIS_PASS:-}"

  local args=(-h "$host" -p "$port" -n "$db" --raw)
  [[ -n "$pass" ]] && args+=(-a "$pass")

  redis-cli "${args[@]}" "$@"
}

_redis_raw_cli() {
  local host="${WORKER_REDIS_HOST:-127.0.0.1}"
  local port="${WORKER_REDIS_PORT:-6379}"
  local db="${WORKER_REDIS_DB:-16}"
  local pass="${WORKER_REDIS_PASS:-}"

  local args=(-h "$host" -p "$port" -n "$db" --raw)
  [[ -n "$pass" ]] && args+=(-a "$pass")

  redis-cli "${args[@]}" "$@"
}

_scan_jobs_page() {
  local cursor="${1:?_scan_jobs_page: cursor obrigatorio}"
  local scan_result

  if ! scan_result="$(_redis_cli SCAN "$cursor" MATCH "nc:jobs:*" COUNT 1000 2>/dev/null)" || \
     [[ -z "${scan_result//[[:space:]]/}" ]]; then
    echo "redis_scan_failed" >&2
    return 1
  fi

  local new_cursor
  new_cursor="$(printf '%s\n' "$scan_result" | sed -n '1p' | tr -d ' ')"
  if [[ ! "$new_cursor" =~ ^[0-9]+$ ]]; then
    echo "redis_scan_invalid_cursor" >&2
    return 1
  fi

  printf '%s\n' "$scan_result"
}

# ============================================================
# enqueue <job_id> <hash_key1> <hash_value1> ...
# Armazena hash nc:jobs:<id> + LPUSH nc:jobs:queue <id>
# Valida que job_id é UUID v4 antes de tocar Redis.
# ============================================================
enqueue() {
  local job_id="${1:?enqueue: job_id obrigatorio}"
  shift

  if ! is_valid_uuid_v4 "$job_id"; then
    echo "enqueue: job_id deve ser UUID v4 lowercase: ${job_id}" >&2
    return 1
  fi

  local key="nc:jobs:${job_id}"

  # Construir HSET com todos os pares
  local hset_args=("HSET" "$key")
  while [[ $# -ge 2 ]]; do
    hset_args+=("$1" "$2")
    shift 2
  done

  _redis_cli "${hset_args[@]}" >/dev/null
  _redis_cli LPUSH "nc:jobs:queue" "$job_id" >/dev/null
}

# ============================================================
# set_state <job_id> <state> [extra_key extra_value ...]
# Atualiza estado + timestamps. EXPIRE 604800 (7d) quando finished/failed/cancelled.
# ============================================================
set_state() {
  local job_id="${1:?set_state: job_id obrigatorio}"
  local state="${2:?set_state: state obrigatorio}"
  shift 2

  local key="nc:jobs:${job_id}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local hset_args=("HSET" "$key" "state" "$state")

  case "$state" in
    queued)    hset_args+=("queued_at" "$ts") ;;
    running)   hset_args+=("started_at" "$ts") ;;
    finished)  hset_args+=("finished_at" "$ts") ;;
    failed)    hset_args+=("failed_at" "$ts") ;;
    cancelled) hset_args+=("cancelled_at" "$ts") ;;
  esac

  # Extras (k/v pares)
  while [[ $# -ge 2 ]]; do
    hset_args+=("$1" "$2")
    shift 2
  done

  _redis_cli "${hset_args[@]}" >/dev/null

  # EXPIRE ao encerrar
  case "$state" in
    finished|failed|cancelled)
      _redis_cli EXPIRE "$key" 604800 >/dev/null
      ;;
  esac
}

# ============================================================
# get_state <job_id>
# Retorna JSON com todos os campos do hash.
# ============================================================
get_state() {
  local job_id="${1:?get_state: job_id obrigatorio}"
  local key="nc:jobs:${job_id}"

  local raw
  raw="$(_redis_raw_cli HGETALL "$key" 2>/dev/null)"

  if [[ -z "$raw" ]]; then
    echo "{}"
    return 0
  fi

  # HGETALL retorna field/value em linhas alternadas. `jq -Rn` preserva
  # escaping correto para valores que ja sejam JSON serializado (args_json).
  printf '%s\n' "$raw" | jq -Rnc '
    [inputs] as $items
    | reduce range(0; ($items | length); 2) as $i
        ({}; . + {($items[$i]): ($items[$i + 1] // "")})
  '
}

# ============================================================
# idem_check <key> <args_hash> <job_id>
# SET nc:idem:<key> <job_id>:<args_hash> NX EX 86400
# Retorna: new | same:<existing_job_id> | conflict | invalid
#
# Fluxo:
#   caller gera job_id antes de chamar; se "new" → usar esse job_id e enqueue.
#   se "same:<id>" → retornar id existente como idempotent response.
#   se "conflict" → exit 3.
#   se "invalid" → exit 5.
# ============================================================
idem_check() {
  local idem_key="${1:?idem_check: key obrigatorio}"
  local args_hash="${2:?idem_check: args_hash obrigatorio}"
  local job_id="${3:?idem_check: job_id obrigatorio}"

  if ! is_valid_uuid_v4 "$idem_key" 2>/dev/null; then
    echo "invalid"
    return 0
  fi

  local redis_key="nc:idem:${idem_key}"
  local new_val="${job_id}:${args_hash}"

  # Tenta SET NX — armazena job_id:args_hash
  local result
  result="$(_redis_cli SET "$redis_key" "$new_val" NX EX 86400 2>/dev/null)"

  if [[ "$result" == "OK" ]]; then
    echo "new"
    return 0
  fi

  # Já existe — ler valor atual e comparar apenas a hash (após o primeiro ':')
  local existing
  existing="$(_redis_cli GET "$redis_key" 2>/dev/null)"

  # Separar job_id existente e hash existente
  local existing_job_id="${existing%%:*}"
  local existing_hash="${existing#*:}"

  if [[ "$existing_hash" == "$args_hash" ]]; then
    echo "same:${existing_job_id}"
  else
    echo "conflict"
  fi
}

# ============================================================
# idem_lookup <key>
# Retorna: <job_id>:<args_hash> ou vazio se não existir
# ============================================================
idem_lookup() {
  local idem_key="${1:?idem_lookup: key obrigatorio}"
  local redis_key="nc:idem:${idem_key}"
  _redis_cli GET "$redis_key" 2>/dev/null || echo ""
}

# ============================================================
# dequeue
# BRPOP nc:jobs:queue <timeout> (0 = block indefinidamente)
# Retorna job_id ou string vazia se timeout/SIGTERM
# ============================================================
dequeue() {
  local timeout="${1:-0}"
  local result
  result="$(_redis_cli BRPOP "nc:jobs:queue" "$timeout" 2>/dev/null)" || true

  if [[ -z "$result" ]]; then
    echo ""
    return 0
  fi

  # BRPOP retorna "nc:jobs:queue\n<job_id>" com --no-raw
  echo "$result" | awk 'NR==2{print $0}'
}

# ============================================================
# client_lock_acquire <client> [ttl_sec]
# SET nc:client_lock:<client> <pid> NX EX <ttl>
# Retorna: 0=adquirido, 1=já bloqueado
# ============================================================
client_lock_acquire() {
  local client="${1:?client_lock_acquire: client obrigatorio}"
  local ttl="${2:-5}"
  local redis_key="nc:client_lock:${client}"
  local pid="$$"

  local result
  result="$(_redis_cli SET "$redis_key" "$pid" NX EX "$ttl" 2>/dev/null)"
  [[ "$result" == "OK" ]]
}

# ============================================================
# client_lock_release <client>
# DEL nc:client_lock:<client> apenas se pid bate (Lua atômica)
# ============================================================
client_lock_release() {
  local client="${1:?client_lock_release: client obrigatorio}"
  local redis_key="nc:client_lock:${client}"
  local pid="$$"

  # Lua: deletar apenas se valor == pid atual (evita liberar lock alheio)
  local lua_script='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end'
  _redis_cli EVAL "$lua_script" 1 "$redis_key" "$pid" >/dev/null 2>&1 || true
}

# ============================================================
# client_lock_renew <client>
# EXPIRE nc:client_lock:<client> 5
# ============================================================
client_lock_renew() {
  local client="${1:?client_lock_renew: client obrigatorio}"
  local redis_key="nc:client_lock:${client}"
  _redis_cli EXPIRE "$redis_key" 5 >/dev/null 2>&1 || true
}

# ============================================================
# worker_lock_acquire <pid>
# SET nc:worker:lock <pid> NX EX 60
# ============================================================
worker_lock_acquire() {
  local pid="${1:?worker_lock_acquire: pid obrigatorio}"
  local result
  result="$(_redis_cli SET "nc:worker:lock" "$pid" NX EX 60 2>/dev/null)"
  [[ "$result" == "OK" ]]
}

# ============================================================
# worker_lock_renew <pid>
# Renova lock apenas se pid bate (Lua atômica).
# Retorna 0=ok, 1=pid errado (lock alienado)
# ============================================================
worker_lock_renew() {
  local pid="${1:?worker_lock_renew: pid obrigatorio}"
  local lua_script='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("EXPIRE", KEYS[1], 60) else return redis.call("error", "pid_mismatch") end'

  local result
  result="$(_redis_cli EVAL "$lua_script" 1 "nc:worker:lock" "$pid" 2>&1)"
  if [[ "$result" == *"pid_mismatch"* || "$result" == *"ERR"* ]]; then
    return 1
  fi
  return 0
}

# ============================================================
# worker_status
# Retorna JSON: queue_depth, current_job, jobs_today, last_failure
# ============================================================
worker_status() {
  local queue_depth
  queue_depth="$(_redis_cli LLEN "nc:jobs:queue" 2>/dev/null || echo 0)"
  # Trim whitespace
  queue_depth="${queue_depth// /}"

  local current_job=""
  current_job="$(_redis_cli GET "nc:worker:current_job" 2>/dev/null || echo "")"

  emit_json \
    queue_depth "@number:${queue_depth:-0}" \
    current_job "${current_job:-null}" \
    jobs_today "@number:0" \
    last_failure ""
}

# ============================================================
# job_cancel <job_id>
# Cancela job em estado queued: seta state=cancelled + LREM da fila.
# Retorna: 0=cancelado, 1=nao em estado queued (exit 5 no caller)
# ============================================================
job_cancel() {
  local job_id="${1:?job_cancel: job_id obrigatorio}"

  local key="nc:jobs:${job_id}"
  local state
  state="$(_redis_cli HGET "$key" "state" 2>/dev/null || echo "")"

  if [[ "$state" != "queued" ]]; then
    return 1
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _redis_cli HSET "$key" state cancelled cancelled_at "$ts" >/dev/null
  _redis_cli LREM "nc:jobs:queue" 0 "$job_id" >/dev/null
  _redis_cli EXPIRE "$key" 604800 >/dev/null
  return 0
}

# ============================================================
# worker_stats [by_cmd] [by_client]
# Retorna JSON com counts por state (e opcionalmente por cmd/client).
# NUNCA usar KEYS — usa SCAN MATCH nc:jobs:* COUNT 1000.
# ============================================================
worker_stats() {
  local by_cmd="${1:-}"
  local by_client="${2:-}"

  local cursor=0
  declare -A state_counts=()
  declare -A cmd_counts=()
  declare -A client_counts=()

  while true; do
    local scan_result
    scan_result="$(_scan_jobs_page "$cursor")" || return 1

    local new_cursor
    new_cursor="$(printf '%s\n' "$scan_result" | sed -n '1p' | tr -d ' ')"
    local keys
    keys="$(printf '%s\n' "$scan_result" | sed '1d')"

    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      [[ "$key" == "nc:jobs:queue" ]] && continue

      local state cmd client
      state="$(_redis_cli HGET "$key" state 2>/dev/null || echo "unknown")"
      cmd="$(_redis_cli HGET "$key" cmd 2>/dev/null || echo "")"
      client="$(_redis_cli HGET "$key" client 2>/dev/null || echo "")"

      state_counts["${state:-unknown}"]=$(( ${state_counts["${state:-unknown}"]:-0} + 1 ))
      [[ -n "$by_cmd"    && -n "$cmd"    ]] && cmd_counts["$cmd"]=$(( ${cmd_counts["$cmd"]:-0} + 1 ))
      [[ -n "$by_client" && -n "$client" ]] && client_counts["$client"]=$(( ${client_counts["$client"]:-0} + 1 ))
    done <<< "$keys"

    [[ "$new_cursor" == "0" ]] && break
    cursor="$new_cursor"
  done

  # Construir JSON resultado
  local by_state_json="{"
  local first=1
  for st in "${!state_counts[@]}"; do
    [[ $first -eq 0 ]] && by_state_json+=","
    by_state_json+="\"${st}\":${state_counts[$st]}"
    first=0
  done
  by_state_json+="}"

  local result_args=("by_state" "@json:${by_state_json}")

  if [[ -n "$by_cmd" ]]; then
    local by_cmd_json="{"
    first=1
    for c in "${!cmd_counts[@]}"; do
      [[ $first -eq 0 ]] && by_cmd_json+=","
      by_cmd_json+="\"${c}\":${cmd_counts[$c]}"
      first=0
    done
    by_cmd_json+="}"
    result_args+=("by_cmd" "@json:${by_cmd_json}")
  fi

  if [[ -n "$by_client" ]]; then
    local by_client_json="{"
    first=1
    for c in "${!client_counts[@]}"; do
      [[ $first -eq 0 ]] && by_client_json+=","
      by_client_json+="\"${c}\":${client_counts[$c]}"
      first=0
    done
    by_client_json+="}"
    result_args+=("by_client" "@json:${by_client_json}")
  fi

  emit_json "${result_args[@]}"
}

# ============================================================
# job_list <state_filter> <client_filter> <cmd_filter> <limit> <offset>
# Usa SCAN MATCH nc:jobs:* COUNT 1000 (nunca KEYS).
# Retorna array JSON de jobs filtrados.
# ============================================================
job_list() {
  local state_filter="${1:-}"
  local client_filter="${2:-}"
  local cmd_filter="${3:-}"
  local limit="${4:-20}"
  local offset="${5:-0}"

  local cursor=0
  local results=()

  while true; do
    local scan_result
    scan_result="$(_scan_jobs_page "$cursor")" || return 1

    local new_cursor
    new_cursor="$(printf '%s\n' "$scan_result" | sed -n '1p' | tr -d ' ')"
    local keys
    keys="$(printf '%s\n' "$scan_result" | sed '1d')"

    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      # Excluir nc:jobs:queue (lista, não hash)
      [[ "$key" == "nc:jobs:queue" ]] && continue

      local job_id="${key#nc:jobs:}"

      # Ler campos relevantes para filtragem
      local state cmd client
      state="$(_redis_cli HGET "$key" state 2>/dev/null || echo "")"
      cmd="$(_redis_cli HGET "$key" cmd 2>/dev/null || echo "")"
      client="$(_redis_cli HGET "$key" client 2>/dev/null || echo "")"

      # Filtrar
      [[ -n "$state_filter"  && "$state"  != "$state_filter"  ]] && continue
      [[ -n "$client_filter" && "$client" != "$client_filter" ]] && continue
      [[ -n "$cmd_filter"    && "$cmd"    != "$cmd_filter"    ]] && continue

      results+=("$job_id")
    done <<< "$keys"

    [[ "$new_cursor" == "0" ]] && break
    cursor="$new_cursor"
  done

  # Paginação por offset/limit
  local total="${#results[@]}"
  local page=()
  local i="$offset"
  while [[ $i -lt $total && ${#page[@]} -lt $limit ]]; do
    page+=("${results[$i]}")
    i=$((i + 1))
  done

  # Serializar como array JSON com campos completos do job
  local json="["
  local first=1
  for jid in "${page[@]}"; do
    [[ $first -eq 0 ]] && json+=","
    local job_raw
    job_raw="$(get_state "$jid" 2>/dev/null || echo "{}")"
    job_raw="$(printf '%s\n' "$job_raw" | jq -c --arg job_id "$jid" '. + {job_id: (.job_id // $job_id)}')"
    json+="$job_raw"
    first=0
  done
  json+="]"
  echo "$json"
}
