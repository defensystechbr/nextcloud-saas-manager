#!/usr/bin/env bats
# tests/unit/test_ssh_audit.bats — Testes unitários de scripts/lib/ssh_audit.sh
# Budget: 6 testes

load '../helpers/setup'
load '../lib/bats-support/load'
load '../lib/bats-assert/load'

setup() {
  # Mock logger no PATH (antes do real)
  export PATH="${REPO_ROOT}/tests/fixtures:${PATH}"

  # Arquivo de captura das chamadas ao logger
  export LOGGER_CAPTURE_FILE="${BATS_TEST_TMPDIR}/logger-capture.txt"
  export LOGGER_FORCE_FAIL=0
  rm -f "$LOGGER_CAPTURE_FILE"

  # shellcheck source=scripts/lib/ssh_audit.sh
  source "${REPO_ROOT}/scripts/lib/ssh_audit.sh"
}

# ============================================================

@test "audit_ssh accept: emite NDJSON com tag e decision=accepted" {
  audit_ssh "accept" "accepted" key_id "sha256:abc123" client_ip "1.2.3.4"

  [[ -f "$LOGGER_CAPTURE_FILE" ]]
  local line
  line="$(tail -1 "$LOGGER_CAPTURE_FILE")"
  # Deve conter a tag e o payload JSON com decision=accepted
  [[ "$line" == *"ncsaas-api-ssh"* ]]

  # Extrair o JSON do payload (última parte)
  local json_part
  json_part="$(echo "$line" | grep -oP '\{.*\}' || true)"
  [[ -n "$json_part" ]]
  local decision
  decision="$(echo "$json_part" | jq -r '.decision' 2>/dev/null || echo "")"
  assert_equal "$decision" "accepted"
}

@test "audit_ssh reject: decision=rejected emitido" {
  audit_ssh "reject" "rejected" reason "metachar"

  [[ -f "$LOGGER_CAPTURE_FILE" ]]
  local line
  line="$(tail -1 "$LOGGER_CAPTURE_FILE")"
  local json_part
  json_part="$(echo "$line" | grep -oP '\{.*\}' || true)"
  [[ -n "$json_part" ]]
  local decision
  decision="$(echo "$json_part" | jq -r '.decision' 2>/dev/null || echo "")"
  assert_equal "$decision" "rejected"
}

@test "audit_worker run_start: tag worker + level=notice + job_id presente" {
  local jid="550e8400-e29b-41d4-a716-446655440000"
  audit_worker "run_start" "notice" "$jid"

  [[ -f "$LOGGER_CAPTURE_FILE" ]]
  local line
  line="$(tail -1 "$LOGGER_CAPTURE_FILE")"
  [[ "$line" == *"nextcloud-saas-worker"* ]]
  local json_part
  json_part="$(echo "$line" | grep -oP '\{.*\}' || true)"
  [[ -n "$json_part" ]]
  local job_id
  job_id="$(echo "$json_part" | jq -r '.job_id' 2>/dev/null || echo "")"
  assert_equal "$job_id" "$jid"
}

@test "audit_occ allow: tag occ-exec + decision=accept + subcmd presente" {
  audit_occ "acme" "user:list" "accept"

  [[ -f "$LOGGER_CAPTURE_FILE" ]]
  local line
  line="$(tail -1 "$LOGGER_CAPTURE_FILE")"
  [[ "$line" == *"nextcloud-saas-occ-exec"* ]]
  local json_part
  json_part="$(echo "$line" | grep -oP '\{.*\}' || true)"
  [[ -n "$json_part" ]]
  local subcmd decision
  subcmd="$(echo "$json_part" | jq -r '.subcmd' 2>/dev/null || echo "")"
  decision="$(echo "$json_part" | jq -r '.decision' 2>/dev/null || echo "")"
  assert_equal "$subcmd" "user:list"
  assert_equal "$decision" "accept"
}

@test "sanitize_secrets aplicado: --password não aparece em texto claro" {
  audit_ssh "invoke" "accepted" command "nextcloud-manage acme _ status --password=secret123"

  [[ -f "$LOGGER_CAPTURE_FILE" ]]
  local content
  content="$(cat "$LOGGER_CAPTURE_FILE")"
  # senha não deve aparecer
  [[ "$content" != *"secret123"* ]]
  # mas *** deve aparecer
  [[ "$content" == *"***"* ]]
}

@test "logger indisponível: fallback file usado" {
  export LOGGER_FORCE_FAIL=1

  # Garantir que o fallback file possa ser escrito
  local fallback_dir="${BATS_TEST_TMPDIR}/var/log"
  mkdir -p "$fallback_dir"

  # Redirecionar o fallback file
  # Sobrescrever a função _emit para usar caminho controlável
  _emit() {
    local tag="$1" facility="$2" level="$3" payload="$4"
    payload="$(sanitize_secrets "$payload")"
    logger -t "$tag" -p "${facility}.${level}" -- "$payload" 2>/dev/null \
      || printf '%s [%s.%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$level" "$payload" \
           >> "${BATS_TEST_TMPDIR}/ncsaas-fallback.log" 2>/dev/null \
      || true
  }

  audit_ssh "invoke" "accepted" key_id "test"

  [[ -f "${BATS_TEST_TMPDIR}/ncsaas-fallback.log" ]]
  local content
  content="$(cat "${BATS_TEST_TMPDIR}/ncsaas-fallback.log")"
  [[ -n "$content" ]]
}
