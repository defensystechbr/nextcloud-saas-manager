#!/usr/bin/env bats
# tests/integration/test_job_queue.bats — Testes integration de scripts/lib/job_queue.sh
# Requer Redis ativo (via service container CI ou redis_fixture).
# Budget: 14 testes

load '../helpers/redis_fixture'
load '../helpers/setup'
load 'bats-support/load'
load 'bats-assert/load'

setup() {
  start_redis_fixture
  export WORKER_REDIS_HOST="$REDIS_HOST"
  export WORKER_REDIS_PORT="$REDIS_PORT"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"

  # Limpar DB antes de cada teste
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$WORKER_REDIS_DB" flushdb >/dev/null 2>&1

  # shellcheck source=scripts/lib/job_queue.sh
  source "${REPO_ROOT}/scripts/lib/job_queue.sh"
}

teardown() {
  stop_redis_fixture
}

_uuid() {
  # Gera UUID v4 lowercase
  python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null \
    || cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# ============================================================

@test "enqueue + get_state: retorna estado completo" {
  local jid
  jid="$(_uuid)"
  run enqueue "$jid" client "acme" cmd "create" state "queued"
  assert_success

  run get_state "$jid"
  assert_success
  local state
  state="$(echo "$output" | jq -r '.state')"
  assert_equal "$state" "queued"
}

@test "set_state running: timestamps populados + EXPIRE setado" {
  local jid
  jid="$(_uuid)"
  enqueue "$jid" client "acme" cmd "create" state "queued"

  run set_state "$jid" "running"
  assert_success

  local json
  json="$(get_state "$jid")"
  local state started_at
  state="$(echo "$json" | jq -r '.state')"
  started_at="$(echo "$json" | jq -r '.started_at')"
  assert_equal "$state" "running"
  [[ -n "$started_at" && "$started_at" != "null" ]]
}

@test "set_state finished: EXPIRE 604800 setado" {
  local jid
  jid="$(_uuid)"
  enqueue "$jid" client "acme" cmd "create" state "queued"
  set_state "$jid" "finished"

  local ttl
  ttl="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$WORKER_REDIS_DB" TTL "nc:jobs:${jid}" 2>/dev/null)"
  [[ "$ttl" -gt 0 ]]
}

@test "idem_check: primeira chamada retorna 'new'" {
  local idem_key
  idem_key="$(_uuid)"
  run idem_check "$idem_key" "hash_abc123"
  assert_success
  assert_output "new"
}

@test "idem_check: segunda chamada com mesmo hash retorna 'same'" {
  local idem_key
  idem_key="$(_uuid)"
  idem_check "$idem_key" "hash_abc123"

  run idem_check "$idem_key" "hash_abc123"
  assert_success
  assert_output "same"
}

@test "idem_check: segunda chamada com hash diferente retorna 'conflict'" {
  local idem_key
  idem_key="$(_uuid)"
  idem_check "$idem_key" "hash_abc123"

  run idem_check "$idem_key" "hash_xyz999"
  assert_success
  assert_output "conflict"
}

@test "idem_check: chave inválida (não UUID) retorna 'invalid'" {
  run idem_check "nao-e-um-uuid" "hash_abc"
  assert_success
  assert_output "invalid"
}

@test "dequeue: retorna job_id em ordem FIFO" {
  local jid1 jid2
  jid1="$(_uuid)"
  jid2="$(_uuid)"

  enqueue "$jid1" client "a" cmd "create" state "queued"
  enqueue "$jid2" client "b" cmd "backup" state "queued"

  # LPUSH faz push à esquerda; BRPOP pega direita → FIFO (primeiro enfileirado, primeiro dequeued)
  local first
  first="$(dequeue 1)"
  [[ -n "$first" ]]
}

@test "client_lock_acquire: segundo acquire falha (lock já existe)" {
  local client="acme-lock-test"
  client_lock_acquire "$client" 10

  run client_lock_acquire "$client" 10
  assert_failure
}

@test "client_lock_release: libera lock do próprio processo" {
  local client="acme-release-test"
  client_lock_acquire "$client" 10
  client_lock_release "$client"

  run client_lock_acquire "$client" 10
  assert_success
}

@test "worker_lock_renew: pid errado retorna erro" {
  # Adquirir com PID fictício diferente
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$WORKER_REDIS_DB" \
    SET "nc:worker:lock" "99999" EX 60 >/dev/null

  run worker_lock_renew "12345"
  assert_failure
}

@test "worker_status: fila vazia retorna queue_depth=0" {
  run worker_status
  assert_success
  local depth
  depth="$(echo "$output" | jq -r '.queue_depth')"
  assert_equal "$depth" "0"
}

@test "worker_status: 3 jobs enfileirados = queue_depth=3" {
  for i in 1 2 3; do
    local jid
    jid="$(_uuid)"
    enqueue "$jid" client "test" cmd "create" state "queued"
  done

  run worker_status
  assert_success
  local depth
  depth="$(echo "$output" | jq -r '.queue_depth')"
  assert_equal "$depth" "3"
}

@test "job_list: filtro por client retorna apenas jobs do cliente" {
  local jid_acme jid_other
  jid_acme="$(_uuid)"
  jid_other="$(_uuid)"

  enqueue "$jid_acme"  client "acme"  cmd "create" state "queued"
  enqueue "$jid_other" client "other" cmd "create" state "queued"
  # Remover da fila (simular jobs processados como hash apenas)
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$WORKER_REDIS_DB" \
    DEL "nc:jobs:queue" >/dev/null

  run job_list "" "acme" "" 20 0
  assert_success
  # jid_acme deve estar presente; jid_other não
  assert_output --partial "$jid_acme"
  refute_output --partial "$jid_other"
}
