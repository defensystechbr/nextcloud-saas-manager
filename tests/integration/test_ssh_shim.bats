#!/usr/bin/env bats
# tests/integration/test_ssh_shim.bats
# Testa o shim ncsaas-api-shim (D2.5):
#   - Rejeição de metacaracteres
#   - Rejeição de binários não-nextcloud-manage
#   - Rejeição de verbos não allowlistados
#   - Rejeição de --password= em argv
#   - Aceitação de comandos válidos (sudo mockado)
# Budget: 10 testes

load '../helpers/setup'

setup() {
  SHIM="${BATS_TEST_DIRNAME}/../../scripts/ncsaas-api-shim"
  chmod +x "$SHIM" 2>/dev/null || true

  # Mock sudo para não precisar de root
  local mock_dir="${BATS_TEST_TMPDIR}/mock-bin"
  mkdir -p "$mock_dir"
  cat > "${mock_dir}/sudo" << 'MOCK_EOF'
#!/bin/bash
# Mock sudo: apenas executa o comando sem privilege escalation
shift  # remove -n flag
exec "$@"
MOCK_EOF
  chmod +x "${mock_dir}/sudo"

  # Mock logger (não temos journald em CI)
  cat > "${mock_dir}/logger" << 'MOCK_EOF'
#!/bin/bash
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/logger"

  # Mock nextcloud-manage
  cat > "${mock_dir}/nextcloud-manage" << 'MOCK_EOF'
#!/bin/bash
echo "nextcloud-manage: $*"
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/nextcloud-manage"

  export PATH="${mock_dir}:${PATH}"
  export SSH_CONNECTION="1.2.3.4 12345 5.6.7.8 22"
  export SSH_USER_AUTH="test-key-fingerprint"
}

# ─── 1. Comando vazio ──────────────────────────────────────
@test "shim: SSH_ORIGINAL_COMMAND vazio → exit 100" {
  SSH_ORIGINAL_COMMAND="" run bash "$SHIM"
  [ "$status" -eq 100 ]
  [[ "$output" == *"command_required"* ]]
}

# ─── 2. Metacaracteres ─────────────────────────────────────
@test "shim: metacar ';' em comando → exit 100" {
  SSH_ORIGINAL_COMMAND="nextcloud-manage list; rm -rf /" run bash "$SHIM"
  [ "$status" -eq 100 ]
  [[ "$output" == *"metacharacter"* ]]
}

@test "shim: metacar '|' em comando → exit 100" {
  SSH_ORIGINAL_COMMAND="nextcloud-manage list | cat /etc/passwd" run bash "$SHIM"
  [ "$status" -eq 100 ]
  [[ "$output" == *"metacharacter"* ]]
}

@test "shim: metacar '&' em comando → exit 100" {
  SSH_ORIGINAL_COMMAND="nextcloud-manage list &" run bash "$SHIM"
  [ "$status" -eq 100 ]
  [[ "$output" == *"metacharacter"* ]]
}

# ─── 3. Binário errado ─────────────────────────────────────
@test "shim: argv[0] = bash → exit 101" {
  SSH_ORIGINAL_COMMAND="bash" run bash "$SHIM"
  [ "$status" -eq 101 ]
  [[ "$output" == *"command_not_allowed"* ]]
}

@test "shim: argv[0] = sh -c 'id' → exit 101" {
  SSH_ORIGINAL_COMMAND="sh -c id" run bash "$SHIM"
  [ "$status" -eq 101 ]
  [[ "$output" == *"command_not_allowed"* ]]
}

# ─── 4. --password= em argv ────────────────────────────────
@test "shim: --password=secret em argv → exit 5" {
  SSH_ORIGINAL_COMMAND="nextcloud-manage acme user create john --password=secret" run bash "$SHIM"
  [ "$status" -eq 5 ]
  [[ "$output" == *"password_in_argv_forbidden"* ]]
}

# ─── 5. Cmd legado não allowlistado ────────────────────────
@test "shim: cmd 'shell' não allowlistado → exit 101" {
  SSH_ORIGINAL_COMMAND="nextcloud-manage acme cloud.acme.com shell" run bash "$SHIM"
  [ "$status" -eq 101 ]
  [[ "$output" == *"cmd_not_allowed"* ]]
}

# ─── 6. Comandos válidos ───────────────────────────────────
@test "shim: nextcloud-manage list → aceito e executado" {
  SSH_ORIGINAL_COMMAND="nextcloud-manage list" run bash "$SHIM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nextcloud-manage: list"* ]]
}

@test "shim: nextcloud-manage acme cloud.acme.com status → aceito" {
  SSH_ORIGINAL_COMMAND="nextcloud-manage acme cloud.acme.com status" run bash "$SHIM"
  [ "$status" -eq 0 ]
}
