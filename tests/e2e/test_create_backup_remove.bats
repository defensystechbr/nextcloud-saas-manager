#!/usr/bin/env bats
# E2E gate for Sprint D5.3: create -> backup -> remove.

setup_file() {
  export MANAGE_SKIP_ROOT_CHECK=1
  export E2E_ROOT
  E2E_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nc-e2e.XXXXXX")"
  export BASE_DIR="${E2E_ROOT}/customers"
  export SHARED_DIR="${E2E_ROOT}/shared"
  export MOCK_BIN="${E2E_ROOT}/bin"
  export MANAGE="${BATS_TEST_DIRNAME}/../../scripts/manage.sh"

  mkdir -p "$BASE_DIR" "$SHARED_DIR/hpb" "$SHARED_DIR/recording" "$MOCK_BIN"

  {
    printf '%s=%s\n' 'DB_ROOT_PASSWORD' 'test-root'
    printf '%s=%s\n' 'TURN_SECRET' 'test-turn'
    printf '%s=%s\n' 'SIGNALING_SECRET' 'test-signaling'
    printf '%s=%s\n' 'SIGNALING_HASH_KEY' 'test-hash'
    printf '%s=%s\n' 'SIGNALING_BLOCK_KEY' 'test-block'
    printf '%s=%s\n' 'SIGNALING_INTERNAL_SECRET' 'test-internal'
    printf '%s=%s\n' 'RECORDING_SECRET' 'test-recording'
    printf '%s=%s\n' 'HARP_SHARED_KEY' 'test-harp'
    printf '%s=%s\n' 'SERVER_IP' '200.50.151.21'
    printf '%s=%s\n' 'COLLABORA_DOMAIN' 'collabora.local'
    printf '%s=%s\n' 'SIGNALING_DOMAIN' 'signaling.local'
    printf '%s=%s\n' 'TURN_DOMAIN' 'turn.local'
    printf '%s=%s\n' 'COLLABORA_ALLOWLIST' ''
  } > "${SHARED_DIR}/.env"

  cat > "${MOCK_BIN}/dig" <<'MOCK_DIG'
#!/usr/bin/env bash
echo "200.50.151.21"
MOCK_DIG

  cat > "${MOCK_BIN}/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
if [[ "$1 $2" == "compose version" ]]; then
  exit 0
fi

if [[ "$1" == "exec" && "$*" == *"occ status"* ]]; then
  echo "installed: true"
  exit 0
fi

if [[ "$1" == "exec" && "$*" == *"mariadb-dump"* ]]; then
  echo "-- e2e database dump"
  exit 0
fi

exit 0
MOCK_DOCKER

  chmod +x "${MOCK_BIN}/dig" "${MOCK_BIN}/docker"
  ln -sf "${MOCK_BIN}/docker" "${MOCK_BIN}/docker-compose"
  export PATH="${MOCK_BIN}:${PATH}"
}

teardown_file() {
  rm -rf "${E2E_ROOT:-}"
}

@test "create acme instance writes customer files" {
  run bash "$MANAGE" acme cloud.acme.test create
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
  [ -d "${BASE_DIR}/acme" ]
  [ -f "${BASE_DIR}/acme/.env" ]
  [ -f "${BASE_DIR}/acme/docker-compose.yml" ]
}

@test "backup acme after create succeeds in a new process" {
  run bash "$MANAGE" acme _ backup
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup conclu"* ]]

  local backup_count
  backup_count="$(find "${BASE_DIR}/backups" -maxdepth 1 -name 'acme_*.tar.gz' | wc -l)"
  [ "$backup_count" -ge 1 ]
  [ ! -f "${BASE_DIR}/acme/database.sql" ]
}

@test "remove acme after backup succeeds in a new process" {
  run bash "$MANAGE" acme _ remove --force
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
  [ ! -d "${BASE_DIR}/acme" ]
}
