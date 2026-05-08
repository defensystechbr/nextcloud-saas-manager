#!/usr/bin/env bats
# tests/integration/test_occ_bridge.bats
# Testa occ_run e helpers de occ_bridge.sh (D3.1).
# Budget: 14 testes
# Requer: Redis em $WORKER_REDIS_HOST:$WORKER_REDIS_PORT db $WORKER_REDIS_DB
# Mock docker via DOCKER_FAKE_OUTPUT / DOCKER_FAKE_EXIT.

load '../helpers/setup'

setup() {
  export WORKER_REDIS_HOST="${WORKER_REDIS_HOST:-127.0.0.1}"
  export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  export WORKER_OCC_TIMEOUT_SEC=2
  export CLIENT_LOCK_TTL_SEC=5

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  LIB_DIR="${BATS_TEST_DIRNAME}/../../scripts/lib"

  # Monkey-patch docker para controle de saida nos testes.
  # Usa env vars para evitar problemas de quoting com JSON.
  _setup_mock_docker_inspect() {
    local running="${1:-true}"
    local out="${2:-}"
    local ec="${3:-0}"
    local mock_dir="${BATS_TEST_TMPDIR}/mock-bin-occ-$$"
    mkdir -p "$mock_dir"
    export MOCK_DOCKER_RUNNING="$running"
    export MOCK_DOCKER_OUTPUT="$out"
    export MOCK_DOCKER_EXIT="$ec"
    cat > "${mock_dir}/docker" << 'MOCK_EOF'
#!/bin/bash
if [[ "$*" == *"inspect"* ]]; then
  echo "${MOCK_DOCKER_RUNNING:-true}"
  exit 0
fi
echo "${MOCK_DOCKER_OUTPUT:-}"
exit "${MOCK_DOCKER_EXIT:-0}"
MOCK_EOF
    chmod +x "${mock_dir}/docker"
    export PATH="${mock_dir}:${PATH}"
    export _MOCK_BIN_DIR="$mock_dir"
  }
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
  [[ -n "${_MOCK_BIN_DIR:-}" ]] && rm -rf "$_MOCK_BIN_DIR" || true
  unset NEXTCLOUD_USER_PASSWORD CURRENT_JOB_ID _MOCK_BIN_DIR
}

# Helper: source occ_bridge em subshell
_run_occ_bridge_fn() {
  local fn="$1"; shift
  bash -c "
    source '${LIB_DIR}/occ_bridge.sh'
    ${fn} \"\$@\"
  " -- "$@"
}

# ─── 1. occ_is_allowed: subcmd na allowlist → return 0 ──────────────────────
@test "occ_is_allowed: user:list esta na allowlist" {
  run bash -c "source '${LIB_DIR}/occ_bridge.sh'; occ_is_allowed user:list"
  [ "$status" -eq 0 ]
}

# ─── 2. occ_is_allowed: subcmd desconhecido → return 1 ──────────────────────
@test "occ_is_allowed: unknown:cmd nao esta na allowlist" {
  run bash -c "source '${LIB_DIR}/occ_bridge.sh'; occ_is_allowed unknown:cmd"
  [ "$status" -ne 0 ]
}

# ─── 3. occ_is_blocklisted: subcmd bloqueado → return 0 ─────────────────────
@test "occ_is_blocklisted: encryption:decrypt-all e blocklisted" {
  run bash -c "source '${LIB_DIR}/occ_bridge.sh'; occ_is_blocklisted 'encryption:decrypt-all'"
  [ "$status" -eq 0 ]
}

# ─── 4. occ_is_state_changing: user:add → return 0 ──────────────────────────
@test "occ_is_state_changing: user:add e state-changing" {
  run bash -c "source '${LIB_DIR}/occ_bridge.sh'; occ_is_state_changing 'user:add'"
  [ "$status" -eq 0 ]
}

# ─── 5. occ_run: subcmd blocklisted → exit 100 ──────────────────────────────
@test "occ_run: subcmd blocklisted retorna exit 100" {
  _setup_mock_docker_inspect "true" "" 0
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'encryption:decrypt-all'
  "
  [ "$status" -eq 100 ]
  [[ "$output" == *"occ_command_not_allowed"* ]]
}

# ─── 6. occ_run: subcmd nao na allowlist → exit 100 ─────────────────────────
@test "occ_run: subcmd nao na allowlist retorna exit 100" {
  _setup_mock_docker_inspect "true" "" 0
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'notreal:cmd'
  "
  [ "$status" -eq 100 ]
  [[ "$output" == *"occ_command_not_allowed"* ]]
}

# ─── 7. occ_run: container parado → exit 14 ─────────────────────────────────
@test "occ_run: container nao rodando retorna exit 14" {
  _setup_mock_docker_inspect "false" "" 0
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'user:list'
  "
  [ "$status" -eq 14 ]
  [[ "$output" == *"instance_not_running"* ]]
}

# ─── 8. occ_run: timeout → exit 15 ─────────────────────────────────────────
@test "occ_run: timeout retorna exit 15" {
  local mock_dir="${BATS_TEST_TMPDIR}/mock-timeout-$$"
  mkdir -p "$mock_dir"
  cat > "${mock_dir}/docker" << 'MOCK_EOF'
#!/bin/bash
if [[ "$*" == *"inspect"* ]]; then echo "true"; exit 0; fi
sleep 10
MOCK_EOF
  chmod +x "${mock_dir}/docker"
  export PATH="${mock_dir}:${PATH}"
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    export WORKER_OCC_TIMEOUT_SEC=1
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'user:list'
  "
  [ "$status" -eq 15 ]
  [[ "$output" == *"occ_timeout"* ]]
  rm -rf "$mock_dir"
}

# ─── 9. occ_run: OCC falha (exit != 0) → exit 16 ───────────────────────────
@test "occ_run: OCC com exit code != 0 retorna exit 16" {
  _setup_mock_docker_inspect "true" "Error: something" 1
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'user:list'
  "
  [ "$status" -eq 16 ]
  [[ "$output" == *"occ_command_failed"* ]]
}

# ─── 10. occ_run: sucesso com subcmd nao-json → stdout preservado ───────────
@test "occ_run: subcmd nao-json captura stdout e retorna exit 0" {
  _setup_mock_docker_inspect "true" "user1\nuser2" 0
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'maintenance:mode'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"schema_version"* ]]
}

# ─── 11. occ_run: OCC_JSON_CAPABLE → parsed_result preenchido ───────────────
@test "occ_run: subcmd json-capable popula parsed_result" {
  _setup_mock_docker_inspect "true" '{"users":{"admin":{}}}' 0
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'user:list'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"parsed_result"* ]]
  local pr
  pr="$(echo "$output" | jq -r '.parsed_result')"
  [[ "$pr" != "null" ]]
}

# ─── 12. occ_run: client_lock adquirido em verb mutavel ─────────────────────
@test "occ_run: client_lock adquirido e liberado em verb state-changing" {
  _setup_mock_docker_inspect "true" "ok" 0
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'maintenance:mode' --on
    # Apos return, lock deve ter sido liberado
    redis-cli -h '${WORKER_REDIS_HOST}' -p '${WORKER_REDIS_PORT}' -n '${WORKER_REDIS_DB}' \
      EXISTS 'nc:client_lock:testclient'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"0"* ]]
}

# ─── 13. occ_run: NEXTCLOUD_USER_PASSWORD via env, nao em argv ──────────────
@test "occ_run: senha passada via env NEXTCLOUD_USER_PASSWORD, nao em argv" {
  local mock_dir="${BATS_TEST_TMPDIR}/mock-pw-$$"
  mkdir -p "$mock_dir"
  # Mock que captura os args e verifica ausencia de senha
  cat > "${mock_dir}/docker" << 'MOCK_EOF'
#!/bin/bash
if [[ "$*" == *"inspect"* ]]; then echo "true"; exit 0; fi
# Verificar que nenhum arg contem a senha literal
for arg in "$@"; do
  if [[ "$arg" == *"s3cr3t"* ]]; then
    echo "SENHA_EM_ARGV_DETECTADA: $arg" >&2
    exit 99
  fi
done
echo "ok"
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/docker"
  export PATH="${mock_dir}:${PATH}"
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    export NEXTCLOUD_USER_PASSWORD='s3cr3t'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'user:add' 'johndoe'
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"SENHA_EM_ARGV"* ]]
  rm -rf "$mock_dir"
}

# ─── 14. occ_run: duration_ms registrado no output ──────────────────────────
@test "occ_run: duration_ms presente no JSON de sucesso" {
  _setup_mock_docker_inspect "true" "ok" 0
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${LIB_DIR}/occ_bridge.sh'
    occ_run testclient 'user:list'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"duration_ms"* ]]
  local dm
  dm="$(echo "$output" | jq '.duration_ms')"
  [[ "$dm" =~ ^[0-9]+$ ]]
}
