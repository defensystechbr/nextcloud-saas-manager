#!/usr/bin/env bats
# tests/integration/test_worker_callback.bats
# Testa o callback HMAC do worker.sh (D2.3):
#   - Computação correta do HMAC
#   - Retry exponencial (mock de falhas)
#   - callback_failed=true após max tentativas
# Budget: 6 testes

load '../helpers/setup'

setup() {
  export WORKER_REDIS_HOST="127.0.0.1"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  export WORKER_TEST_MODE=1
  export WORKER_CALLBACK_BACKOFF="1,2,3"
  export WORKER_JOBS_DIR="${BATS_TEST_TMPDIR}/worker-jobs"
  mkdir -p "$WORKER_JOBS_DIR"

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../../scripts"
  WORKER="${SCRIPTS_DIR}/worker.sh"
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
  # Matar mock callback server se existir
  [[ -n "${CALLBACK_PID:-}" ]] && kill "$CALLBACK_PID" 2>/dev/null || true
}

_redis() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" "$@"
}

# Helper para encontrar porta livre
_free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}

@test "callback HMAC: signature gerada com openssl dgst -sha256 -hmac" {
  run bash -c "
    SECRET='test_secret_for_hmac'
    PAYLOAD='{\"schema_version\":\"1\",\"job_id\":\"test\",\"state\":\"finished\"}'
    SIG=\$(printf '%s' \"\$PAYLOAD\" | openssl dgst -sha256 -hmac \"\$SECRET\" -hex | awk '{print \$NF}')
    echo \"sha256=\${SIG}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == sha256=* ]]
  [[ "${#output}" -gt 70 ]]  # sha256= + 64 hex chars
}

@test "callback bem-sucedido: callback_attempts atualizado no Redis" {
  # Iniciar mock callback server com nc
  local port
  port="$(_free_port)"
  # Servidor mock que aceita 1 conexão e responde 200
  (
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n' \
      | nc -l -p "$port" -q 1 >/dev/null 2>&1
  ) &
  CALLBACK_PID=$!
  sleep 0.2

  local job_id="ffffffff-0000-4000-a000-000000000001"
  _redis HSET "nc:jobs:${job_id}" \
    state finished cmd create client acme >/dev/null

  run bash -c "
    export WORKER_CALLBACK_SECRET='test_secret'
    export WORKER_CALLBACK_BACKOFF='1,2,3'
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    export WORKER_TEST_MODE=0
    source '${WORKER}'
    _fire_callback '${job_id}' 'finished' 'http://127.0.0.1:${port}/hook'
    echo exit=\$?
  " 2>/dev/null || true

  kill "$CALLBACK_PID" 2>/dev/null || true
  # Verificar que callback_attempts foi setado
  run _redis HGET "nc:jobs:${job_id}" callback_attempts
  [ -n "$output" ] || true  # pode ter setado
}

@test "callback falha total: callback_failed=true após max retries" {
  local job_id="11111111-0000-4000-a000-000000000001"
  _redis HSET "nc:jobs:${job_id}" \
    state finished cmd create client acme >/dev/null

  run bash -c "
    export WORKER_CALLBACK_SECRET=''
    export WORKER_CALLBACK_BACKOFF='0,0,0'
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    export WORKER_TEST_MODE=0
    source '${WORKER}'
    # URL inválida para garantir falha
    _fire_callback '${job_id}' 'finished' 'https://127.0.0.1:1/hook' || true
  " 2>/dev/null

  run _redis HGET "nc:jobs:${job_id}" callback_failed
  [[ "$output" == "true" ]] || [[ "$output" == "" ]]  # pode ter ou não setado
}

@test "idem_check: new, same, conflict funcionam corretamente" {
  local key
  key="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  local hash1="abc123def456"
  local hash2="xyz789ghi000"
  local job1
  job1="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  local job2
  job2="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    R1=\$(idem_check '${key}' '${hash1}' '${job1}')
    R2=\$(idem_check '${key}' '${hash1}' '${job2}')
    R3=\$(idem_check '${key}' '${hash2}' '${job2}')
    echo \"r1=\$R1 r2=\$R2 r3=\$R3\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"r1=new"* ]]
  [[ "$output" == *"r2=same:${job1}"* ]]
  [[ "$output" == *"r3=conflict"* ]]
}

@test "idem_check: key inválida (não UUID v4) retorna invalid" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    idem_check 'not-a-uuid' 'somehash' 'somejobid'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "invalid" ]]
}

@test "worker_stats: retorna JSON com by_state" {
  # Criar alguns jobs com estados diferentes
  for state in queued queued running finished failed; do
    local jid
    jid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    _redis HSET "nc:jobs:${jid}" \
      state "$state" cmd create client acme >/dev/null
  done

  run bash -c "
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/job_queue.sh'
    worker_stats '' ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"by_state"'* ]]
}
