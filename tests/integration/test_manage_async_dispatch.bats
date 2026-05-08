#!/usr/bin/env bats
# tests/integration/test_manage_async_dispatch.bats
# Testa o dispatcher híbrido de manage.sh (D2.1):
#   - Parser legado + namespaces hierárquicos
#   - Dispatch sync vs async
#   - Flags de segurança (--idempotency-key, --callback, --dry-run)
#   - Rejeição de --password em argv
# Budget: 16 testes

load '../helpers/setup'

setup() {
  export MANAGE_SKIP_ROOT_CHECK=1
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc-base"
  export SHARED_DIR="${BATS_TEST_TMPDIR}/nc-shared"
  export WORKER_REDIS_HOST="127.0.0.1"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  mkdir -p "$BASE_DIR" "$SHARED_DIR"

  # Redis FLUSHDB para garantir estado limpo
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  MANAGE="${BATS_TEST_DIRNAME}/../../scripts/manage.sh"
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
}

# ─── 1. Dispatch legado sync ────────────────────────────────
@test "dispatch legado: status sync chama cmd_status" {
  # Criar fixture de cliente
  create_test_client_fixture "acme" "cloud.acme.com"
  mock_docker "running"

  run bash "$MANAGE" acme _ status
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme"* ]]
}

@test "dispatch legado: list retorna cabeçalho" {
  run bash "$MANAGE" list
  [ "$status" -eq 0 ]
}

@test "dispatch legado: shared-status retorna serviços" {
  mock_docker "not found"
  run bash "$MANAGE" shared-status
  [ "$status" -eq 0 ]
}

# ─── 2. Parser híbrido — token-2 namespace ─────────────────
@test "namespace user: retorna not_implemented_yet (exit 99)" {
  run bash "$MANAGE" acme user create john --async --json
  [ "$status" -eq 99 ]
  [[ "$output" == *"not_implemented_yet"* ]]
}

@test "namespace group: retorna not_implemented_yet (exit 99)" {
  run bash "$MANAGE" acme group create admins --async --json
  [ "$status" -eq 99 ]
  [[ "$output" == *"not_implemented_yet"* ]]
}

@test "namespace apps: retorna not_implemented_yet (exit 99)" {
  run bash "$MANAGE" acme apps enable deck,tasks --async --json
  [ "$status" -eq 99 ]
  [[ "$output" == *"not_implemented_yet"* ]]
}

@test "namespace occ-exec: retorna not_implemented_yet (exit 99)" {
  run bash "$MANAGE" acme occ-exec user:list --json
  [ "$status" -eq 99 ]
  [[ "$output" == *"not_implemented_yet"* ]]
}

# ─── 3. Dispatch async: enqueue path ───────────────────────
@test "create --async --json retorna EnqueuedJob com job_id" {
  create_test_client_fixture "acme" "cloud.acme.com"

  run bash "$MANAGE" acme cloud.acme.com create --async --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"job_id"'* ]]
  [[ "$output" == *'"state"'*'"queued"'* ]] || [[ "$output" == *'queued'* ]]
}

@test "create --async --json: job_id existe no Redis" {
  create_test_client_fixture "acme" "cloud.acme.com"

  run bash "$MANAGE" acme cloud.acme.com create --async --json
  [ "$status" -eq 0 ]
  job_id="$(echo "$output" | jq -r '.job_id // empty')"
  [ -n "$job_id" ]

  # Verificar key no Redis
  run redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    HGET "nc:jobs:${job_id}" state
  [ "$status" -eq 0 ]
  [[ "$output" == "queued" ]]
}

@test "create --async --dry-run: não cria key no Redis" {
  create_test_client_fixture "acme" "cloud.acme.com"

  run bash "$MANAGE" acme cloud.acme.com create --async --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"job_id"'* ]]

  # Verificar que Redis está vazio
  run redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    LLEN "nc:jobs:queue"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ─── 4. Flags de segurança ─────────────────────────────────
@test "--callback sem --async: exit 5" {
  run bash "$MANAGE" acme cloud.acme.com create --callback=https://api.example.com/hook --json
  [ "$status" -eq 5 ]
}

@test "--callback com IP RFC1918: exit 5" {
  run bash "$MANAGE" acme cloud.acme.com create --async --callback=https://192.168.1.1/hook --json
  [ "$status" -eq 5 ]
}

@test "--idempotency-key inválido (não UUID v4): exit 5" {
  run bash "$MANAGE" acme cloud.acme.com create --async --idempotency-key=not-a-uuid --json
  [ "$status" -eq 5 ]
}

@test "--password=* em argv: exit 5" {
  run bash "$MANAGE" acme user create john --password=secret --async --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"password_in_argv_forbidden"* ]]
}

# ─── 5. Idempotency (D2.2) ─────────────────────────────────
@test "idempotency: 2a chamada com mesmos args retorna mesmo job_id" {
  create_test_client_fixture "acme" "cloud.acme.com"
  local idem_key
  idem_key="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json \
    "--idempotency-key=${idem_key}"
  [ "$status" -eq 0 ]
  job_id_1="$(echo "$output" | jq -r '.job_id // empty')"
  [ -n "$job_id_1" ]

  # Segunda chamada com mesmo idem key e mesmos args
  run bash "$MANAGE" acme cloud.acme.com create \
    --async --json \
    "--idempotency-key=${idem_key}"
  [ "$status" -eq 0 ]
  job_id_2="$(echo "$output" | jq -r '.job_id // empty')"
  [ "$job_id_1" = "$job_id_2" ]
  [[ "$output" == *'"idempotent":true'* ]]
}

# ─── 6. worker/job subcommands ─────────────────────────────
@test "worker status --json retorna queue_depth" {
  run bash "$MANAGE" worker status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"queue_depth"'* ]]
}

@test "job list --json retorna array" {
  run bash "$MANAGE" job list --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
}
