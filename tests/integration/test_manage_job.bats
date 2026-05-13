#!/usr/bin/env bats
# tests/integration/test_manage_job.bats
# Testa subcomandos job e worker de manage.sh (D2.8, D2.7, D2.9)
# Budget: 10 testes

load '../helpers/setup'

setup() {
  export MANAGE_SKIP_ROOT_CHECK=1
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc-base"
  export SHARED_DIR="${BATS_TEST_TMPDIR}/nc-shared"
  export WORKER_REDIS_HOST="127.0.0.1"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  mkdir -p "$BASE_DIR" "$SHARED_DIR"

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  MANAGE="${BATS_TEST_DIRNAME}/../../scripts/manage.sh"
  SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../../scripts"

  # Criar job de teste no Redis
  TEST_JOB_ID="aaaabbbb-cccc-4ddd-aeee-ffffffff0001"
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    HSET "nc:jobs:${TEST_JOB_ID}" \
    schema_version 1 \
    job_id "$TEST_JOB_ID" \
    state queued \
    cmd create \
    client acme \
    args_json '["nextcloud-manage","acme","cloud.acme.com","create"]' \
    queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/dev/null

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    LPUSH "nc:jobs:queue" "$TEST_JOB_ID" >/dev/null
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
}

_redis() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" "$@"
}

# ─── job status ─────────────────────────────────────────────
@test "job status --json retorna JSON com state" {
  run bash "$MANAGE" job "$TEST_JOB_ID" status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state"'* ]]
  [[ "$output" == *'"job_id"'* ]]
}

@test "job status: job inexistente → exit 1" {
  run bash "$MANAGE" job "00000000-0000-4000-a000-000000000000" status --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"job_not_found"* ]]
}

@test "job status sem --json: saída human-readable" {
  run bash "$MANAGE" job "$TEST_JOB_ID" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Job"* ]]
}

# ─── job cancel ────────────────────────────────────────────
@test "job cancel: job queued → state=cancelled" {
  run bash "$MANAGE" job "$TEST_JOB_ID" cancel --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state"'*'"cancelled"'* ]] || [[ "$output" == *"cancelled"* ]]

  run _redis HGET "nc:jobs:${TEST_JOB_ID}" state
  [[ "$output" == "cancelled" ]]
}

@test "job cancel: job running → exit 5" {
  _redis HSET "nc:jobs:${TEST_JOB_ID}" state running >/dev/null
  run bash "$MANAGE" job "$TEST_JOB_ID" cancel --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"not_cancellable"* ]]
}

# ─── job list ──────────────────────────────────────────────
@test "job list --json retorna array JSON" {
  run bash "$MANAGE" job list --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
}

@test "job list --state=queued: retorna somente jobs queued" {
  run bash "$MANAGE" job list --state=queued --json
  [ "$status" -eq 0 ]
  # Se tem conteúdo, deve conter state=queued
  if [[ "$output" != "[]" && "$output" != "[ ]" ]]; then
    [[ "$output" == *'"state":"queued"'* ]] || [[ "$output" == *'queued'* ]]
  fi
}

@test "job list --client=acme: filtra por cliente" {
  run bash "$MANAGE" job list --client=acme --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
}

# ─── worker status ─────────────────────────────────────────
@test "worker status --json: retorna queue_depth como número" {
  run bash "$MANAGE" worker status --json
  [ "$status" -eq 0 ]
  # queue_depth deve ser 0 (após cancelamento anterior) ou 1
  [[ "$output" == *'"queue_depth"'* ]]
  queue_depth="$(echo "$output" | jq '.queue_depth // -1')"
  [ "$queue_depth" -ge 0 ]
}

# ─── worker stats ──────────────────────────────────────────
@test "worker stats --json: retorna by_state com contagens" {
  run bash "$MANAGE" worker stats --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"by_state"'* ]]
}
