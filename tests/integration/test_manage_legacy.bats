#!/usr/bin/env bats
# tests/integration/test_manage_legacy.bats — Smoke regressivo de scripts/manage.sh
# Verifica que o comportamento legado (F01-F10) é preservado após o refactor.
# Budget: 10 testes

load '../helpers/setup'
load 'bats-support/load'
load 'bats-assert/load'

setup() {
  # Fixtures mock no PATH (docker, redis-cli)
  export PATH="${REPO_ROOT}/tests/fixtures:${PATH}"

  # Pular verificação de root
  export MANAGE_SKIP_ROOT_CHECK=1

  # Diretórios temporários de teste
  export BASE_DIR="${BATS_TEST_TMPDIR}/customers"
  export SHARED_DIR="${BATS_TEST_TMPDIR}/shared"
  mkdir -p "${BASE_DIR}" "${SHARED_DIR}"

  # Mock docker compose version
  export DOCKER_FAKE_OUTPUT=""
  export DOCKER_FAKE_EXIT=0

  # Mock redis-cli (job_queue.sh não é usada por cmd_* legados, mas source não pode quebrar)
  export REDIS_CLI_FAKE_OUTPUT=""
  export REDIS_CLI_FAKE_EXIT=0

  MANAGE="${REPO_ROOT}/scripts/manage.sh"
}

_create_client_fixture() {
  local name="${1:?_create_client_fixture: name obrigatorio}"
  local domain="${2:-${name}.example.com}"
  mkdir -p "${BASE_DIR}/${name}"
  cat > "${BASE_DIR}/${name}/.env" << ENV_EOF
CLIENT_NAME=${name}
DOMAIN=${domain}
REDIS_DB=1
MYSQL_DATABASE=nextcloud_${name}
MYSQL_USER=nc_${name}
ENV_EOF
  cat > "${BASE_DIR}/${name}/docker-compose.yml" << YML_EOF
name: '${name}'
services:
  app:
    image: nextcloud:latest
YML_EOF
  cat > "${BASE_DIR}/${name}/.credentials" << CRED_EOF
=== Credenciais da Instância: ${name} ===
URL: https://${domain}
Usuário: admin
CRED_EOF
}

# ============================================================

@test "manage.sh sem args: exibe usage (exit 0)" {
  run bash "$MANAGE"
  assert_success
  assert_output --partial "Uso:"
}

@test "manage.sh --help: exibe usage (exit 0)" {
  run bash "$MANAGE" --help
  assert_success
  assert_output --partial "Uso:"
}

@test "manage.sh list: retorna 0 com BASE_DIR vazio" {
  run bash "$MANAGE" list
  assert_success
  assert_output --partial "Instâncias Nextcloud"
}

@test "manage.sh list: lista 1 cliente existente" {
  _create_client_fixture "acme" "acme.example.com"
  export DOCKER_INSPECT_STATUS="running"

  run bash "$MANAGE" list
  assert_success
  assert_output --partial "acme"
}

@test "manage.sh <cliente> _ status: status da instância" {
  _create_client_fixture "acme" "acme.example.com"
  export DOCKER_INSPECT_STATUS="running"

  run bash "$MANAGE" acme _ status
  assert_success
  assert_output --partial "Status da Instância: acme"
}

@test "manage.sh <cliente> _ credentials: exibe credenciais" {
  _create_client_fixture "acme" "acme.example.com"

  run bash "$MANAGE" acme _ credentials
  assert_success
  assert_output --partial "Credenciais da Instância: acme"
}

@test "manage.sh <cliente> _ stop: chama docker compose stop (exit 0)" {
  _create_client_fixture "acme" "acme.example.com"

  run bash "$MANAGE" acme _ stop
  assert_success
  assert_output --partial "Instância parada"
}

@test "manage.sh <cliente> _ start: chama docker compose up -d (exit 0)" {
  _create_client_fixture "acme" "acme.example.com"

  run bash "$MANAGE" acme _ start
  assert_success
  assert_output --partial "Instância iniciada"
}

@test "manage.sh com --dry-run: flag parseada (PARSED_FLAGS[dry_run]=1)" {
  run bash "$MANAGE" --dry-run list
  assert_success
}

@test "manage.sh com --json: flag parseada sem alterar comportamento" {
  run bash "$MANAGE" --json list
  assert_success
  assert_output --partial "Instâncias Nextcloud"
}
