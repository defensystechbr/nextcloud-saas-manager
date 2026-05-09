#!/usr/bin/env bats
# tests/integration/test_inbox_staging.bats
# Testa inbox-staging: inbox_metadata_create/get/consume/delete + inbox_staging_consume (D3.2).
# Budget: 8 testes
# Requer: Redis em $WORKER_REDIS_HOST:$WORKER_REDIS_PORT db $WORKER_REDIS_DB

load '../helpers/setup'

setup() {
  export WORKER_REDIS_HOST="${WORKER_REDIS_HOST:-127.0.0.1}"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  LIB_DIR="${BATS_TEST_DIRNAME}/../../scripts/lib"
  INBOX_BASE="${BATS_TEST_TMPDIR}/inbox"
  JOBS_BASE="${BATS_TEST_TMPDIR}/jobs"
  mkdir -p "$INBOX_BASE" "$JOBS_BASE"

  STAGING_UUID="550e8400-e29b-41d4-a716-446655440001"
  JOB_UUID="550e8400-e29b-41d4-a716-446655440002"
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
  rm -rf "${BATS_TEST_TMPDIR}/inbox" "${BATS_TEST_TMPDIR}/jobs" || true
}

# Wrapper para chamar funcoes de job_queue.sh
_run_queue_fn() {
  local fn="$1"; shift
  bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    ${fn} \"\$@\"
  " -- "$@"
}

# ─── 1. inbox_metadata_create: cria hash com fields corretos ────────────────
@test "inbox_metadata_create: hash nc:inbox:<id> criado com fields corretos" {
  run _run_queue_fn "inbox_metadata_create" "$STAGING_UUID" "3" "1048576" "acme"
  [ "$status" -eq 0 ]

  local staging_id val
  staging_id="$(redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    HGET "nc:inbox:${STAGING_UUID}" staging_id)"
  [ "$staging_id" = "$STAGING_UUID" ]

  local client
  client="$(redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    HGET "nc:inbox:${STAGING_UUID}" client)"
  [ "$client" = "acme" ]
}

# ─── 2. inbox_metadata_get: retorna JSON com staging_id ─────────────────────
@test "inbox_metadata_get: retorna JSON com staging_id preenchido" {
  _run_queue_fn "inbox_metadata_create" "$STAGING_UUID" "1" "512" ""

  run _run_queue_fn "inbox_metadata_get" "$STAGING_UUID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$STAGING_UUID"* ]]
  local sid
  sid="$(echo "$output" | jq -r '.staging_id')"
  [ "$sid" = "$STAGING_UUID" ]
}

# ─── 3. inbox_metadata_get: retorna {} para staging inexistente ─────────────
@test "inbox_metadata_get: retorna {} para staging nao existente" {
  run _run_queue_fn "inbox_metadata_get" "99999999-9999-4999-a999-999999999999"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

# ─── 4. inbox_metadata_consume: atualiza consumed_at ────────────────────────
@test "inbox_metadata_consume: atualiza consumed_at e job_id" {
  _run_queue_fn "inbox_metadata_create" "$STAGING_UUID" "2" "2048" "acme"

  run _run_queue_fn "inbox_metadata_consume" "$STAGING_UUID" "$JOB_UUID"
  [ "$status" -eq 0 ]

  local consumed_at
  consumed_at="$(redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    HGET "nc:inbox:${STAGING_UUID}" consumed_at)"
  [[ -n "$consumed_at" ]]

  local stored_job
  stored_job="$(redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    HGET "nc:inbox:${STAGING_UUID}" job_id)"
  [ "$stored_job" = "$JOB_UUID" ]
}

# ─── 5. inbox_staging_consume: move arquivos para jobs/<jid>/staging/ ───────
@test "inbox_staging_consume: move arquivos do inbox para jobs staging dir" {
  mkdir -p "${INBOX_BASE}/${STAGING_UUID}"
  echo "fake-logo-content" > "${INBOX_BASE}/${STAGING_UUID}/logo.png"
  _run_queue_fn "inbox_metadata_create" "$STAGING_UUID" "1" "18" "acme"

  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    inbox_staging_consume '${STAGING_UUID}' '${JOB_UUID}' '${INBOX_BASE}' '${JOBS_BASE}'
  "
  [ "$status" -eq 0 ]
  [ -f "${JOBS_BASE}/${JOB_UUID}/staging/logo.png" ]
  [ ! -f "${INBOX_BASE}/${STAGING_UUID}/logo.png" ]
}

# ─── 6. inbox_staging_consume: staging dir nao existe → exit 19 ─────────────
@test "inbox_staging_consume: staging dir inexistente retorna exit 19" {
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    inbox_staging_consume 'nonexistent-uuid-0000-0000-000000000000' \
      '${JOB_UUID}' '${INBOX_BASE}' '${JOBS_BASE}'
  "
  [ "$status" -eq 19 ]
}

# ─── 7. inbox_staging_consume: arquivo > 5MB → exit 18 ──────────────────────
@test "inbox_staging_consume: arquivo maior que 5MB retorna exit 18" {
  mkdir -p "${INBOX_BASE}/${STAGING_UUID}"
  # Criar arquivo de 6MB (6291456 bytes) com dd
  dd if=/dev/zero of="${INBOX_BASE}/${STAGING_UUID}/bigfile.bin" bs=1M count=6 2>/dev/null

  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    inbox_staging_consume '${STAGING_UUID}' '${JOB_UUID}' '${INBOX_BASE}' '${JOBS_BASE}'
  "
  [ "$status" -eq 18 ]
}

# ─── 8. inbox_metadata_create: UUID invalido → exit 5 ───────────────────────
@test "inbox_metadata_create: UUID invalido retorna exit 5" {
  run _run_queue_fn "inbox_metadata_create" "not-a-valid-uuid" "0" "0" ""
  [ "$status" -eq 5 ]
}

# ─── 9. QA-004: inbox_staging_consume: staging_id invalido → exit 5 ─────────
@test "inbox_staging_consume: staging_id vazio ou invalido retorna exit 5" {
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    inbox_staging_consume 'not-a-uuid' '${JOB_UUID}' '${INBOX_BASE}' '${JOBS_BASE}'
  "
  [ "$status" -eq 5 ]
}

# ─── 10. QA-004: inbox_staging_consume: path traversal (/../../etc) → exit 5 ─
@test "inbox_staging_consume: staging_id com path traversal retorna exit 5" {
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    inbox_staging_consume '../../etc/passwd' '${JOB_UUID}' '${INBOX_BASE}' '${JOBS_BASE}'
  "
  [ "$status" -eq 5 ]
}

# ─── 11. QA-005: inbox_staging_consume: N arquivos < 5MB mas total > 10MB ────
@test "inbox_staging_consume: 3 arquivos de 4MB cada (total 12MB) retorna exit 18" {
  mkdir -p "${INBOX_BASE}/${STAGING_UUID}"
  # 3 arquivos de 4MB = 12MB total (> limite de 10MB)
  dd if=/dev/zero of="${INBOX_BASE}/${STAGING_UUID}/file1.bin" bs=1M count=4 2>/dev/null
  dd if=/dev/zero of="${INBOX_BASE}/${STAGING_UUID}/file2.bin" bs=1M count=4 2>/dev/null
  dd if=/dev/zero of="${INBOX_BASE}/${STAGING_UUID}/file3.bin" bs=1M count=4 2>/dev/null

  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    inbox_staging_consume '${STAGING_UUID}' '${JOB_UUID}' '${INBOX_BASE}' '${JOBS_BASE}'
  "
  [ "$status" -eq 18 ]
}

# ─── 12. QA-005: inbox_staging_consume: 2 arquivos de 4MB (total 8MB) → ok ───
@test "inbox_staging_consume: 2 arquivos de 4MB (total 8MB, abaixo do limite) → exit 0" {
  mkdir -p "${INBOX_BASE}/${STAGING_UUID}"
  dd if=/dev/zero of="${INBOX_BASE}/${STAGING_UUID}/file1.bin" bs=1M count=4 2>/dev/null
  dd if=/dev/zero of="${INBOX_BASE}/${STAGING_UUID}/file2.bin" bs=1M count=4 2>/dev/null

  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/job_queue.sh'
    inbox_staging_consume '${STAGING_UUID}' '${JOB_UUID}' '${INBOX_BASE}' '${JOBS_BASE}'
  "
  [ "$status" -eq 0 ]
  [ -f "${JOBS_BASE}/${JOB_UUID}/staging/file1.bin" ]
  [ -f "${JOBS_BASE}/${JOB_UUID}/staging/file2.bin" ]
}
