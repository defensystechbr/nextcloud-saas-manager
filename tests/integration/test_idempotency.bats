#!/usr/bin/env bats
# tests/integration/test_idempotency.bats
# Testa idempotency integrado ao manage-cli (D2.2)
# Budget: 6 testes

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
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
}

_redis() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" "$@"
}

@test "idem: 1a chamada com idem_key cria novo job" {
  create_test_client_fixture "acme" "cloud.acme.com"
  local key
  key="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${key}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"job_id"'* ]]
  [[ "$output" != *'"idempotent":true'* ]]
}

@test "idem: 2a chamada mesmos args retorna mesmo job_id + idempotent=true" {
  create_test_client_fixture "acme" "cloud.acme.com"
  local key
  key="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${key}"
  [ "$status" -eq 0 ]
  local job1
  job1="$(echo "$output" | jq -r '.job_id // empty')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${key}"
  [ "$status" -eq 0 ]
  local job2
  job2="$(echo "$output" | jq -r '.job_id // empty')"

  [ "$job1" = "$job2" ]
  [[ "$output" == *'"idempotent":true'* ]]
}

@test "idem: chave reusada com args diferentes → exit 3 (conflict)" {
  create_test_client_fixture "acme" "cloud.acme.com"
  create_test_client_fixture "acme2" "cloud.acme2.com"
  local key
  key="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${key}" > /dev/null

  run bash "$MANAGE" acme2 cloud.acme2.com create \
    --async --json "--idempotency-key=${key}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"idempotency_conflict"* ]]
}

@test "idem: key inválida (não UUID v4) → exit 5" {
  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=not-valid-uuid"
  [ "$status" -eq 5 ]
}

@test "idem: nc:idem key expira em 86400s (EXPIRETIME verificado)" {
  create_test_client_fixture "acme" "cloud.acme.com"
  local key
  key="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${key}"
  [ "$status" -eq 0 ]

  run _redis TTL "nc:idem:${key}"
  [ "$output" -gt 0 ]
  [ "$output" -le 86400 ]
}

@test "idem: sem idem_key, job_id muda em cada chamada" {
  create_test_client_fixture "acme" "cloud.acme.com"

  run bash "$MANAGE" acme cloud.acme.com create --async --json
  local job1
  job1="$(echo "$output" | jq -r '.job_id // empty')"

  run bash "$MANAGE" acme cloud.acme.com create --async --json
  local job2
  job2="$(echo "$output" | jq -r '.job_id // empty')"

  [ "$job1" != "$job2" ]
}
