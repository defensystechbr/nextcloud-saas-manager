#!/usr/bin/env bats
# tests/integration/test_observability.bats
# Testa wiring de observabilidade (D2.6):
#   - log_event emite NDJSON válido
#   - audit_ssh, audit_worker sanitizam secrets
#   - sanitize_secrets remove passwords
# Budget: 6 testes

load '../helpers/setup'

setup() {
  SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../../scripts"
}

# ─── log_event ─────────────────────────────────────────────
@test "log_event: emite NDJSON com campos obrigatórios" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    log_event notice enqueue job_id 'test-job' client 'acme'
  "
  [ "$status" -eq 0 ]
  # Deve ser JSON válido com ts, level, event
  echo "$output" | jq -e '.ts and .level and .event' >/dev/null
}

@test "log_event: sanitiza --password= em extras" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    log_event notice enqueue job_id 'test' detail '--password=supersecret'
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"supersecret"* ]]
  [[ "$output" == *"***"* ]]
}

# ─── audit_ssh ─────────────────────────────────────────────
@test "audit_ssh: aceita evento válido sem erro" {
  run bash -c "
    export SSH_CONNECTION='1.2.3.4 12345 5.6.7.8 22'
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/ssh_audit.sh'
    audit_ssh invoke accepted command 'nextcloud-manage list'
  "
  [ "$status" -eq 0 ]
}

@test "audit_ssh: rejeita evento inválido com erro" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/ssh_audit.sh'
    audit_ssh invalid_event accepted
  "
  [ "$status" -ne 0 ] || [[ "$output" == *"invalido"* ]] || [[ "$stderr" == *"invalido"* ]]
}

# ─── audit_worker ──────────────────────────────────────────
@test "audit_worker: run_start emite log sem erro" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    source '${SCRIPTS_DIR}/lib/validators.sh'
    source '${SCRIPTS_DIR}/lib/ssh_audit.sh'
    audit_worker run_start notice 'test-job-id' client 'acme' cmd 'create'
  "
  [ "$status" -eq 0 ]
}

# ─── sanitize_secrets ──────────────────────────────────────
@test "sanitize_secrets: substitui padrões de senha por ***" {
  run bash -c "
    source '${SCRIPTS_DIR}/lib/output_json.sh'
    sanitize_secrets 'MYSQL_PASSWORD=abc123 NEXTCLOUD_ADMIN_PASSWORD=xyz789 normal=value'
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"abc123"* ]]
  [[ "$output" != *"xyz789"* ]]
  [[ "$output" == *"MYSQL_PASSWORD=***"* ]]
  [[ "$output" == *"normal=value"* ]]
}
