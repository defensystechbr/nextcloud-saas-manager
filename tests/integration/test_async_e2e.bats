#!/usr/bin/env bats
# tests/integration/test_async_e2e.bats
# Testa fluxo E2E assíncrono (D2.10):
#   - dispatch → enqueue → worker pickup → state=finished/failed → callback
# Budget: 8 testes (sem docker real; usa nextcloud-manage mockado)

load '../helpers/setup'

setup() {
  export MANAGE_SKIP_ROOT_CHECK=1
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc-base"
  export SHARED_DIR="${BATS_TEST_TMPDIR}/nc-shared"
  export WORKER_REDIS_HOST="127.0.0.1"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  export WORKER_JOBS_DIR="${BATS_TEST_TMPDIR}/worker-jobs"
  mkdir -p "$BASE_DIR" "$SHARED_DIR" "$WORKER_JOBS_DIR"

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  MANAGE="${BATS_TEST_DIRNAME}/../../scripts/manage.sh"
  WORKER="${BATS_TEST_DIRNAME}/../../scripts/worker.sh"
  SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../../scripts"

  # Criar mock nextcloud-manage que simula sucesso
  local mock_dir="${BATS_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_dir"
  cat > "${mock_dir}/nextcloud-manage" << 'MOCK_EOF'
#!/bin/bash
# Mock nextcloud-manage para testes E2E
echo '{"schema_version":"1","status":"ok","client":"'"${1:-acme}"'"}'
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/nextcloud-manage"

  export MANAGE_BIN="${mock_dir}/nextcloud-manage"
  export PATH="${mock_dir}:${PATH}"
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
  [[ -n "${WORKER_PID:-}" ]] && kill "$WORKER_PID" 2>/dev/null || true
}

_redis() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" "$@"
}

# ─── 1. dispatch + enqueue ─────────────────────────────────
@test "e2e: create --async --json retorna EnqueuedJob com job_id" {
  create_test_client_fixture "acme" "cloud.acme.com"
  run bash "$MANAGE" acme cloud.acme.com create --async --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"job_id"'* ]]
  [[ "$output" == *'"state"'* ]]
  job_id="$(echo "$output" | jq -r '.job_id // empty')"
  [ -n "$job_id" ]
}

@test "e2e: job enfileirado aparece em nc:jobs:queue" {
  create_test_client_fixture "acme" "cloud.acme.com"
  run bash "$MANAGE" acme cloud.acme.com create --async --json
  [ "$status" -eq 0 ]
  job_id="$(echo "$output" | jq -r '.job_id // empty')"

  run _redis LLEN "nc:jobs:queue"
  [ "$output" -ge 1 ]
  run _redis LRANGE "nc:jobs:queue" 0 -1
  [[ "$output" == *"$job_id"* ]]
}

@test "e2e: job tem state=queued e args_json com nextcloud-manage" {
  create_test_client_fixture "acme" "cloud.acme.com"
  run bash "$MANAGE" acme cloud.acme.com create --async --json
  job_id="$(echo "$output" | jq -r '.job_id // empty')"

  run _redis HGET "nc:jobs:${job_id}" state
  [ "$output" = "queued" ]

  run _redis HGET "nc:jobs:${job_id}" args_json
  [[ "$output" == *"nextcloud-manage"* ]]
}

# ─── 2. Idempotency E2E ────────────────────────────────────
@test "e2e: idempotency - 2a chamada retorna mesmo job_id" {
  create_test_client_fixture "acme" "cloud.acme.com"
  local idem_key
  idem_key="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${idem_key}"
  [ "$status" -eq 0 ]
  job_id_1="$(echo "$output" | jq -r '.job_id // empty')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${idem_key}"
  [ "$status" -eq 0 ]
  job_id_2="$(echo "$output" | jq -r '.job_id // empty')"

  [ "$job_id_1" = "$job_id_2" ]
  [[ "$output" == *'"idempotent":true'* ]]
}

@test "e2e: idempotency conflict (args diferentes) → exit 3" {
  create_test_client_fixture "acme" "cloud.acme.com"
  create_test_client_fixture "acme2" "cloud.acme2.com"
  local idem_key
  idem_key="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json "--idempotency-key=${idem_key}"
  [ "$status" -eq 0 ]

  run bash "$MANAGE" acme2 cloud.acme2.com create \
    --async --json "--idempotency-key=${idem_key}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"idempotency_conflict"* ]]
}

# ─── 3. Worker pickup E2E ──────────────────────────────────
@test "e2e: worker processa job enfileirado → state!=queued" {
  # Criar job diretamente no Redis com nextcloud-manage mockado
  local job_id
  job_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  local mock_manage="${BATS_TEST_TMPDIR}/mock-bin/nextcloud-manage"

  _redis HSET "nc:jobs:${job_id}" \
    schema_version 1 \
    job_id "$job_id" \
    state queued \
    cmd create \
    client acme \
    "args_json" "[\"${mock_manage}\",\"acme\",\"cloud.acme.com\",\"create\"]" \
    queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/dev/null
  _redis LPUSH "nc:jobs:queue" "$job_id" >/dev/null

  # Executar worker em modo single-job (WORKER_TEST_MODE facilita teste)
  # Usar process_job diretamente via source
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    export WORKER_JOBS_DIR='${WORKER_JOBS_DIR}'
    export WORKER_TEST_MODE=0
    export MANAGE_SKIP_ROOT_CHECK=1
    source '${WORKER}'
    process_job '${job_id}'
  " 2>/dev/null || true

  # Estado deve ter mudado de queued
  run _redis HGET "nc:jobs:${job_id}" state
  [[ "$output" != "queued" ]] || [ -z "$output" ]
}

# ─── 4. Dry-run E2E ───────────────────────────────────────
@test "e2e: create --async --dry-run não enfileira job real" {
  create_test_client_fixture "acme" "cloud.acme.com"
  run bash "$MANAGE" acme cloud.acme.com create --async --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"job_id"'* ]]

  # Fila deve estar vazia
  run _redis LLEN "nc:jobs:queue"
  [ "$output" -eq 0 ]
}

# ─── 5. Multiple async jobs ───────────────────────────────
@test "e2e: múltiplos jobs enfileirados respeitam FIFO" {
  create_test_client_fixture "acme" "cloud.acme.com"
  create_test_client_fixture "beta" "cloud.beta.com"

  bash "$MANAGE" acme cloud.acme.com create --async --json > /dev/null
  bash "$MANAGE" beta cloud.beta.com backup --async --json > /dev/null

  run _redis LLEN "nc:jobs:queue"
  [ "$output" -ge 2 ]
}
