#!/usr/bin/env bats
# tests/unit/test_backup_offsite.bats — Unit tests para scripts/lib/backup_offsite.sh

# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FAKE_RESTIC_DIR="${REPO_ROOT}/tests/helpers"

setup() {
  mkdir -p "${BATS_TEST_TMPDIR}"
  cp "${FAKE_RESTIC_DIR}/fake_restic.sh" "${BATS_TEST_TMPDIR}/restic"
  chmod +x "${BATS_TEST_TMPDIR}/restic"
  export PATH="${BATS_TEST_TMPDIR}:${PATH}"

  # Secrets tmpdir
  export BACKUP_OFFSITE_SECRETS_DIR="${BATS_TEST_TMPDIR}/secrets"
  mkdir -p "${BACKUP_OFFSITE_SECRETS_DIR}"

  # Variáveis de controle
  unset FAKE_RESTIC_FAIL FAKE_RESTIC_INIT_FAIL FAKE_RESTIC_NO_CONFIG

  # Source backup_offsite.sh (reset source guard)
  unset BACKUP_OFFSITE_SH_SOURCED
  # shellcheck source=scripts/lib/output_json.sh
  source "${REPO_ROOT}/scripts/lib/output_json.sh"
  source "${REPO_ROOT}/scripts/lib/backup_offsite.sh"
}

# ok 1 — backup_offsite_read_secrets com secrets presentes carrega variáveis
@test "backup_offsite_read_secrets: secrets presentes exporta RESTIC_REPOSITORY e RESTIC_PASSWORD" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  backup_offsite_read_secrets
  [ "$RESTIC_REPOSITORY" = "s3://bucket/path" ]
  [ "$RESTIC_PASSWORD" = "supersecret" ]
}

# ok 2 — backup_offsite_read_secrets sem backup-repo-url → exit 12
@test "backup_offsite_read_secrets: sem backup-repo-url retorna exit 12" {
  run backup_offsite_read_secrets
  [ "$status" -eq 12 ]
}

# ok 3 — backup_offsite_do_backup dry_run → JSON result:dry_run
@test "backup_offsite_do_backup: dry_run retorna JSON com result dry_run" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  backup_offsite_read_secrets
  mkdir -p "${BATS_TEST_TMPDIR}/nc/testclient/data"
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc"
  run backup_offsite_do_backup "testclient" "1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"dry_run"'
}

# ok 4 — backup_offsite_do_backup real → JSON result:success com snapshot_id
@test "backup_offsite_do_backup: backup real retorna JSON com snapshot_id" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  backup_offsite_read_secrets
  mkdir -p "${BATS_TEST_TMPDIR}/nc/testclient/data"
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc"
  run backup_offsite_do_backup "testclient" "0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"result":"success"'
  echo "$output" | grep -q '"snapshot_id":"abc123fake"'
}

# ok 5 — backup_offsite_do_backup com FAKE_RESTIC_FAIL=1 → exit não-zero
@test "backup_offsite_do_backup: restic falha → exit não-zero" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  backup_offsite_read_secrets
  mkdir -p "${BATS_TEST_TMPDIR}/nc2/testclient/data"
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc2"
  export FAKE_RESTIC_FAIL=1
  run backup_offsite_do_backup "testclient" "0"
  [ "$status" -ne 0 ]
}

# ok 6 — backup_offsite_prune → exit 0
@test "backup_offsite_prune: retorna exit 0 com fake_restic" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  backup_offsite_read_secrets
  run backup_offsite_prune
  [ "$status" -eq 0 ]
}

# ok 7 — backup_offsite_verify → exit 0
@test "backup_offsite_verify: retorna exit 0 com fake_restic" {
  echo "s3://bucket/path" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-url"
  echo "supersecret" > "${BACKUP_OFFSITE_SECRETS_DIR}/backup-repo-password"
  backup_offsite_read_secrets
  run backup_offsite_verify
  [ "$status" -eq 0 ]
}
