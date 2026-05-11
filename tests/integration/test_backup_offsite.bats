#!/usr/bin/env bats
# tests/integration/test_backup_offsite.bats — Integration tests: manage.sh backup-offsite

# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  # Instalar fake_restic no PATH (antes do restic real)
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cp "${REPO_ROOT}/tests/helpers/fake_restic.sh" "${BATS_TEST_TMPDIR}/bin/restic"
  chmod +x "${BATS_TEST_TMPDIR}/bin/restic"
  # Docker/redis mocks exigidos por manage.sh ao subir o script
  export PATH="${BATS_TEST_TMPDIR}/bin:${REPO_ROOT}/tests/fixtures:${PATH}"
  export DOCKER_FAKE_EXIT=0
  export REDIS_CLI_FAKE_EXIT=0

  # Secrets tmpdir
  export BACKUP_OFFSITE_SECRETS_DIR="${BATS_TEST_TMPDIR}/secrets"
  mkdir -p "${BACKUP_OFFSITE_SECRETS_DIR}"

  # BASE_DIR tmpdir
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc"
  mkdir -p "${BASE_DIR}/testclient/data"

  unset FAKE_RESTIC_FAIL FAKE_RESTIC_INIT_FAIL FAKE_RESTIC_NO_CONFIG
}

# ok 1 — manage.sh backup-offsite --dry-run --json com secrets e cliente → exit 0, result:dry_run
@test "manage.sh backup-offsite --dry-run --json: retorna JSON result dry_run" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  run env MANAGE_SKIP_ROOT_CHECK=1 bash "${REPO_ROOT}/scripts/manage.sh" \
    testclient _ backup-offsite --dry-run --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"dry_run"'
  echo "$output" | grep -q '"schema_version":"1"'
}

# ok 2 — manage.sh backup-offsite --json (backup real) → exit 0, snapshot_id presente
@test "manage.sh backup-offsite --json: backup real retorna snapshot_id" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  run env MANAGE_SKIP_ROOT_CHECK=1 bash "${REPO_ROOT}/scripts/manage.sh" \
    testclient _ backup-offsite --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"success"'
  echo "$output" | grep -q '"snapshot_id"'
}

# ok 3 — manage.sh backup-offsite sem secrets → exit 12, JSON error backup_secrets_missing
@test "manage.sh backup-offsite sem secrets: exit 12 com JSON error" {
  run env MANAGE_SKIP_ROOT_CHECK=1 bash "${REPO_ROOT}/scripts/manage.sh" \
    testclient _ backup-offsite --json
  [ "$status" -eq 12 ]
  echo "$output" | grep -q 'backup_secrets_missing'
}
