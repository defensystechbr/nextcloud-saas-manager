#!/usr/bin/env bash
# tests/helpers/setup.bash — Ambiente comum para todos os testes Bats
# Carregado via: load 'helpers/setup'

# Sentinel: verificar que estamos dentro de um contexto Bats
if [[ -z "${BATS_TEST_DIRNAME:-}" ]]; then
  echo "setup.bash: BATS_TEST_DIRNAME nao definido. Deve ser carregado via 'load' dentro do Bats." >&2
  return 1
fi

# ============================================================
# Caminhos
# ============================================================
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
TESTS_DIR="${REPO_ROOT}/tests"

# Bats helper libs (instalados em tests/lib/ via install-deps.sh)
# Prepend local libs para CI-compat (BATS_LIB_PATH pode já ter /usr/lib/bats)
export BATS_LIB_PATH="${TESTS_DIR}/lib${BATS_LIB_PATH:+:${BATS_LIB_PATH}}"

# Scripts acessíveis sem caminho absoluto
export PATH="${SCRIPTS_DIR}:${PATH}"

# ============================================================
# Variáveis de ambiente padrão para testes (seguras / mocked)
# ============================================================
export BASE_DIR="/tmp/nc-test-base-$$"
export SHARED_DIR="/tmp/nc-test-shared-$$"
export WORKER_JOB_TIMEOUT_SEC="${WORKER_JOB_TIMEOUT_SEC:-5}"
export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
export WORKER_REDIS_HOST="${WORKER_REDIS_HOST:-127.0.0.1}"
export WORKER_REDIS_PORT="${WORKER_REDIS_PORT:-6379}"

# ============================================================
# mock_docker — injeta wrapper falso de docker/docker compose
# Uso: mock_docker <stdout_output> [exit_code]
# Exporta DOCKER_FAKE_OUTPUT que o wrapper mock usa.
# ============================================================
mock_docker() {
  local output="${1:-}"
  local exit_code="${2:-0}"
  export DOCKER_FAKE_OUTPUT="$output"
  export DOCKER_FAKE_EXIT="${exit_code}"

  # Criar mock binário temporário em diretório que ficará no PATH
  local mock_dir="${BATS_TEST_TMPDIR:-/tmp}/mock-bin-$$"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/docker" << 'MOCK_EOF'
#!/bin/bash
echo "${DOCKER_FAKE_OUTPUT:-}"
exit "${DOCKER_FAKE_EXIT:-0}"
MOCK_EOF
  chmod +x "${mock_dir}/docker"

  # docker-compose alias
  cp "${mock_dir}/docker" "${mock_dir}/docker-compose"

  export PATH="${mock_dir}:${PATH}"
}

# ============================================================
# create_test_client_fixture — cria estrutura mínima de cliente
# Uso: create_test_client_fixture <client_name> [domain]
# ============================================================
create_test_client_fixture() {
  local name="${1:?client_name obrigatorio}"
  local domain="${2:-${name}.example.com}"
  local dir="${BASE_DIR}/${name}"

  mkdir -p "${dir}"
  cat > "${dir}/.env" << ENV_EOF
CLIENT_NAME=${name}
DOMAIN=${domain}
REDIS_DB=1
ENV_EOF
  cat > "${dir}/docker-compose.yml" << YML_EOF
name: '${name}'
services:
  app:
    image: nextcloud:latest
    container_name: ${name}-app
YML_EOF
}
