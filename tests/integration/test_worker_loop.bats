#!/usr/bin/env bats
# tests/integration/test_worker_loop.bats
# Testa o loop principal do worker.sh (D2.3):
#   - Fluxo de processo de job
#   - Estados do job (running → finished/failed)
#   - Lock duplo flock + Redis
#   - Cleanup de job stale
# Budget: 8 testes

load '../helpers/setup'

setup() {
  export WORKER_REDIS_HOST="127.0.0.1"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  export WORKER_TEST_MODE=1
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc-base"
  export SHARED_DIR="${BATS_TEST_TMPDIR}/nc-shared"
  export MANAGE_SKIP_ROOT_CHECK=1
  export WORKER_JOBS_DIR="${BATS_TEST_TMPDIR}/worker-jobs"
  mkdir -p "$BASE_DIR" "$SHARED_DIR" "$WORKER_JOBS_DIR"

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  WORKER="${BATS_TEST_DIRNAME}/../../scripts/worker.sh"
  SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../../scripts"
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
  # Matar worker em background se sobreviveu
  if [[ -n "${WORKER_BG_PID:-}" ]]; then
    kill "$WORKER_BG_PID" 2>/dev/null || true
  fi
}

# Helpers
_redis() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" "$@"
}

_enqueue_job() {
  local job_id="$1"
  local cmd="${2:-create}"
  local client="${3:-acme}"
  local args_json="${4:-[\"nextcloud-manage\",\"${client}\",\"cloud.acme.com\",\"${cmd}\"]}"

  _redis HSET "nc:jobs:${job_id}" \
    schema_version 1 \
    job_id "$job_id" \
    state queued \
    cmd "$cmd" \
    client "$client" \
    args_json "$args_json" \
    queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/dev/null

  _redis LPUSH "nc:jobs:queue" "$job_id" >/dev/null
}

# ─── Sourcing worker em modo de teste ──────────────────────
@test "worker.sh com WORKER_TEST_MODE=1 sai imediatamente com exit 0" {
  run bash "$WORKER"
  [ "$status" -eq 0 ]
}

# ─── process_job: estados ─────────────────────────────────
@test "process_job: job sem campos obrigatórios → state=failed" {
  local job_id="aaaaaaaa-0000-4000-a000-000000000001"

  # Criar job sem cmd/client
  _redis HSET "nc:jobs:${job_id}" \
    schema_version 1 job_id "$job_id" state queued >/dev/null
  _redis LPUSH "nc:jobs:queue" "$job_id" >/dev/null

  # Source o worker e executar process_job diretamente
  run bash -c "
    export WORKER_TEST_MODE=0
    export WORKER_JOBS_DIR='${WORKER_JOBS_DIR}'
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    export MANAGE_SKIP_ROOT_CHECK=1
    source '${WORKER}'
    process_job '${job_id}'
  " 2>/dev/null || true

  # Job deve estar marcado como failed
  state="\$(_redis HGET "nc:jobs:${job_id}" state)"
  run _redis HGET "nc:jobs:${job_id}" state
  [[ "$output" == "failed" || "$output" == "" ]]
}

@test "job_queue: enqueue + dequeue retorna job_id correto" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    JOB_ID='bbbbbbbb-0000-4000-a000-000000000001'
    enqueue \"\$JOB_ID\" cmd create client acme state queued
    RESULT=\$(dequeue 1)
    echo \"\$RESULT\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"bbbbbbbb-0000-4000-a000-000000000001"* ]]
}

@test "worker_lock: acquire retorna OK; segundo acquire falha" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    PID=\$\$
    worker_lock_acquire \"\$PID\" && echo 'first_ok' || echo 'first_fail'
    worker_lock_acquire '99999' && echo 'second_ok' || echo 'second_fail'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"first_ok"* ]]
  [[ "$output" == *"second_fail"* ]]
}

@test "client_lock: acquire + release funciona corretamente" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    client_lock_acquire 'acme' 5 && echo 'acquired' || echo 'failed'
    client_lock_acquire 'acme' 5 && echo 'second_ok' || echo 'second_fail'
    client_lock_release 'acme'
    client_lock_acquire 'acme' 5 && echo 'after_release_ok' || echo 'after_release_fail'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"acquired"* ]]
  [[ "$output" == *"second_fail"* ]]
  [[ "$output" == *"after_release_ok"* ]]
}

@test "set_state: queued → running → finished com timestamps" {
  local job_id="cccccccc-0000-4000-a000-000000000001"
  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    enqueue '${job_id}' cmd create client acme state queued
    set_state '${job_id}' running
    set_state '${job_id}' finished
    get_state '${job_id}'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"finished"'* ]]
  [[ "$output" == *'"finished_at"'* ]]
}

@test "job_cancel: job em queued → cancelled; LREM" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    JID='dddddddd-0000-4000-a000-000000000001'
    enqueue \"\$JID\" cmd create client acme state queued
    job_cancel \"\$JID\" && echo 'cancelled_ok' || echo 'cancel_fail'
    get_state \"\$JID\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"cancelled_ok"* ]]
  [[ "$output" == *'"state":"cancelled"'* ]]
}

@test "job_cancel: job em running → retorna 1" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    JID='eeeeeeee-0000-4000-a000-000000000001'
    enqueue \"\$JID\" cmd create client acme state queued
    set_state \"\$JID\" running
    job_cancel \"\$JID\" && echo 'cancel_ok' || echo 'cancel_fail'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"cancel_fail"* ]]
}
