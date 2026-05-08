#!/usr/bin/env bats
# tests/unit/test_job_queue_scan.bats — Falhas de SCAN sem Redis real

load '../helpers/setup'
load '../lib/bats-support/load'
load '../lib/bats-assert/load'

setup() {
  # shellcheck source=scripts/lib/output_json.sh
  source "${REPO_ROOT}/scripts/lib/output_json.sh"
  # shellcheck source=scripts/lib/job_queue.sh
  source "${REPO_ROOT}/scripts/lib/job_queue.sh"

  _redis_cli() {
    return 127
  }
}

@test "job_list: falha rapidamente quando SCAN nao retorna cursor" {
  run job_list "" "" "" 20 0
  assert_failure
  assert_output --partial "redis_scan_failed"
}

@test "worker_stats: falha rapidamente quando SCAN nao retorna cursor" {
  run worker_stats "" ""
  assert_failure
  assert_output --partial "redis_scan_failed"
}
