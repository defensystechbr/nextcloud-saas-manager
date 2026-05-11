#!/usr/bin/env bats
# Sprint D4 — Feature P + hardening.

load '../helpers/redis_fixture'
load '../helpers/setup'

setup() {
  export MANAGE_SKIP_ROOT_CHECK=1
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc-base"
  export SHARED_DIR="${BATS_TEST_TMPDIR}/nc-shared"
  mkdir -p "$BASE_DIR" "$SHARED_DIR"
  start_redis_fixture
  export WORKER_REDIS_HOST="$REDIS_HOST"
  export WORKER_REDIS_PORT="$REDIS_PORT"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" FLUSHDB >/dev/null
  MANAGE="${BATS_TEST_DIRNAME}/../../scripts/manage.sh"
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" FLUSHDB >/dev/null 2>&1 || true
  stop_redis_fixture
}

mock_docker_occ() {
  local mock_dir="${BATS_TEST_TMPDIR}/mock-occ"
  mkdir -p "$mock_dir"
  cat > "${mock_dir}/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == "compose" && "$2" == "version" ]]; then
  echo "Docker Compose version v2"
  exit 0
fi
if [[ "$1" == "inspect" && "$2" == "-f" ]]; then
  echo "true"
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  echo '[{"HostConfig":{"Binds":["/var/run/docker.sock:/var/run/docker.sock:ro"]}}]'
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  echo '{"users":[]}'
  exit 0
fi
exit 0
MOCK
  chmod +x "${mock_dir}/docker"
  export PATH="${mock_dir}:${PATH}"
}

@test "occ-exec user:list retorna OccExecResult com parsed_result" {
  mock_docker_occ
  run bash "$MANAGE" acme occ-exec user:list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"occ_command":"user:list"'* ]]
  [[ "$output" == *'"parsed_result":{"users":[]}'* ]]
}

@test "occ-exec user:add exige --payload-stdin para senha" {
  mock_docker_occ
  run bash "$MANAGE" acme occ-exec user:add john --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"payload_stdin_required"* ]]
}

@test "occ-exec mutavel bloqueia quando client-lock ja existe" {
  mock_docker_occ
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    SET "nc:client_lock:acme" "worker-pid" EX 30 >/dev/null

  run bash "$MANAGE" acme occ-exec app:enable calendar --json
  [ "$status" -eq 17 ]
  [[ "$output" == *"client_busy_async_job_running"* ]]
}

@test "health --json retorna 8 checks em menos de 10s" {
  mock_docker_occ
  local start end elapsed count
  start="$(date +%s)"
  run bash "$MANAGE" health --json
  end="$(date +%s)"
  elapsed=$((end - start))
  [ "$elapsed" -lt 10 ]
  count="$(echo "$output" | jq '.checks | length')"
  [ "$count" -eq 8 ]
}

@test "upgrade-harp --dry-run emite OperationResult" {
  create_test_client_fixture "acme" "cloud.acme.com"
  mock_docker_occ
  run bash "$MANAGE" upgrade-harp acme --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"operation":"upgrade-harp"'* ]]
  [[ "$output" == *'"dry_run":true'* ]]
}
