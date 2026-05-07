#!/usr/bin/env bats
# tests/unit/test_job_runner.bats — Testes unitários de scripts/lib/job_runner.sh
# Budget: 8 testes

load '../helpers/setup'
load 'bats-support/load'
load 'bats-assert/load'

setup() {
  # Fixtures mock no PATH
  export PATH="${REPO_ROOT}/tests/fixtures:${PATH}"

  # shellcheck source=scripts/lib/job_runner.sh
  source "${REPO_ROOT}/scripts/lib/job_runner.sh"

  # Diretório temporário para logs de teste
  export TEST_LOG_DIR="${BATS_TEST_TMPDIR}/logs"
  mkdir -p "$TEST_LOG_DIR"
}

# ============================================================

@test "run_job: comando rápido (exit 0) retorna '0'" {
  export NCM_EXIT=0
  export NCM_OUTPUT="ok"
  local log="${TEST_LOG_DIR}/test1.log"

  run run_job "test-job-1" "$log" "nextcloud-manage" "acme" "_" "status"
  assert_success
  assert_output "0"
  [[ -f "$log" ]]
}

@test "run_job: log criado após execução" {
  export NCM_EXIT=0
  local log="${TEST_LOG_DIR}/test2.log"

  run_job "test-job-2" "$log" "nextcloud-manage" "acme" "_" "status"
  [[ -f "$log" ]]
}

@test "run_job: comando que falha (exit 1) retorna '1'" {
  export NCM_EXIT=1
  local log="${TEST_LOG_DIR}/test3.log"

  run run_job "test-job-3" "$log" "nextcloud-manage" "acme" "_" "status"
  assert_success
  assert_output "1"
}

@test "run_job: timeout (NCM_SLEEP > WORKER_JOB_TIMEOUT_SEC) retorna 124" {
  export NCM_SLEEP=60
  export WORKER_JOB_TIMEOUT_SEC=1
  local log="${TEST_LOG_DIR}/test4.log"

  run run_job "test-job-4" "$log" "nextcloud-manage" "acme" "_" "status"
  assert_success
  assert_output "124"
}

@test "sanitize_log: MYSQL_PASSWORD substituído no arquivo de log" {
  local log="${TEST_LOG_DIR}/test5.log"
  echo "MYSQL_PASSWORD=supersecret123 some log line" > "$log"

  run sanitize_log "$log"
  assert_success
  run grep -q "supersecret123" "$log"
  assert_failure
}

@test "run_job: argv com aspas preservado (sem injection)" {
  export NCM_EXIT=0
  local log="${TEST_LOG_DIR}/test6.log"

  run run_job "test-job-6" "$log" "nextcloud-manage" "acme" "_" "status" "--dry-run"
  assert_success
  assert_output "0"
}

@test "sanitize_log: idempotente — chamar 2x = chamar 1x" {
  local log="${TEST_LOG_DIR}/test7.log"
  echo "MYSQL_PASSWORD=supersecret123 some log" > "$log"
  sanitize_log "$log"
  local after_first
  after_first="$(cat "$log")"
  sanitize_log "$log"
  local after_second
  after_second="$(cat "$log")"
  assert_equal "$after_first" "$after_second"
}

@test "run_job: argv[0] != nextcloud-manage retorna exit 5 (security)" {
  local log="${TEST_LOG_DIR}/test8.log"

  run run_job "test-job-8" "$log" "evil-command" "do-something"
  assert_equal "$status" "5"
}
