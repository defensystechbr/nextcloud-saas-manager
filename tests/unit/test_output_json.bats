#!/usr/bin/env bats
# tests/unit/test_output_json.bats — Testes unitários de scripts/lib/output_json.sh
# Budget: 12 testes

load '../helpers/setup'
load 'bats-support/load'
load 'bats-assert/load'

setup() {
  # shellcheck source=scripts/lib/output_json.sh
  source "${REPO_ROOT}/scripts/lib/output_json.sh"
}

# ============================================================
# emit_json
# ============================================================

@test "emit_json: strings simples inclui schema_version=1" {
  run emit_json foo "bar"
  assert_success
  local val
  val="$(echo "$output" | jq -r '.schema_version')"
  assert_equal "$val" "1"
}

@test "emit_json: valor string simples preservado" {
  run emit_json foo "bar"
  assert_success
  local val
  val="$(echo "$output" | jq -r '.foo')"
  assert_equal "$val" "bar"
}

@test "emit_json: prefixo @number: produz tipo number no JSON" {
  run emit_json count "@number:42"
  assert_success
  local val
  val="$(echo "$output" | jq -r '.count')"
  assert_equal "$val" "42"
  # Verificar que é número (não string)
  local type
  type="$(echo "$output" | jq -r '.count | type')"
  assert_equal "$type" "number"
}

@test "emit_json: prefixo @json: embeda objeto JSON corretamente" {
  run emit_json data '@json:{"a":1}'
  assert_success
  local val
  val="$(echo "$output" | jq -r '.data.a')"
  assert_equal "$val" "1"
}

@test "emit_json: string com unicode preservado" {
  run emit_json city "São Paulo"
  assert_success
  local val
  val="$(echo "$output" | jq -r '.city')"
  assert_equal "$val" "São Paulo"
}

@test "emit_json: string com aspas internas escapada corretamente" {
  run emit_json name "O\"Brian"
  assert_success
  local val
  val="$(echo "$output" | jq -r '.name')"
  assert_equal "$val" 'O"Brian'
}

# ============================================================
# emit_error
# ============================================================

@test "emit_error: payload com code + message + retry_after" {
  run emit_error "idempotency_conflict" "key already used" 30
  assert_success
  local err msg ra
  err="$(echo "$output" | jq -r '.error')"
  msg="$(echo "$output" | jq -r '.message')"
  ra="$(echo "$output" | jq -r '.retry_after')"
  assert_equal "$err" "idempotency_conflict"
  assert_equal "$msg" "key already used"
  assert_equal "$ra" "30"
}

# ============================================================
# log_event
# ============================================================

@test "log_event: saída é NDJSON válido com ts + level + event" {
  run log_event "notice" "run_start" job_id "abc-123"
  assert_success
  # Deve parsear como JSON
  echo "$output" | jq -e . >/dev/null
  local level event
  level="$(echo "$output" | jq -r '.level')"
  event="$(echo "$output" | jq -r '.event')"
  assert_equal "$level" "notice"
  assert_equal "$event" "run_start"
}

# ============================================================
# sanitize_secrets
# ============================================================

@test "sanitize_secrets: MYSQL_PASSWORD=abc123 substituído por ***" {
  run sanitize_secrets "MYSQL_PASSWORD=abc123 some log"
  assert_success
  assert_output --partial "MYSQL_PASSWORD=***"
}

@test "sanitize_secrets: --password=secret substituído por ***" {
  run sanitize_secrets "cmd --password=secret123"
  assert_success
  assert_output --partial "--password=***"
}

@test "sanitize_secrets: texto sem segredo não alterado" {
  run sanitize_secrets "texto normal sem segredos"
  assert_success
  assert_output "texto normal sem segredos"
}

@test "sanitize_secrets: idempotente (chamar 2x = chamar 1x)" {
  local once
  once="$(sanitize_secrets "MYSQL_PASSWORD=abc123")"
  local twice
  twice="$(sanitize_secrets "$once")"
  assert_equal "$once" "$twice"
}

@test "log_event: auto-sanitiza payload com senha" {
  run log_event "info" "test_event" cmd "--password=mysecret"
  assert_success
  # Senha não deve aparecer em texto claro
  refute_output --partial "mysecret"
  assert_output --partial "***"
}
