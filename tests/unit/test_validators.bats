#!/usr/bin/env bats
# tests/unit/test_validators.bats — Testes unitários de scripts/lib/validators.sh
# Budget: 18 testes

load '../helpers/setup'
load 'bats-support/load'
load 'bats-assert/load'

setup() {
  # shellcheck source=scripts/lib/validators.sh
  source "${REPO_ROOT}/scripts/lib/validators.sh"
}

# ============================================================
# is_valid_client_name
# ============================================================

@test "is_valid_client_name: nome válido 'acme' retorna 0" {
  run is_valid_client_name "acme"
  assert_success
}

@test "is_valid_client_name: maiúsculas 'ACME' retorna 1" {
  run is_valid_client_name "ACME"
  assert_failure
}

@test "is_valid_client_name: underscore 'acme_corp' retorna 1" {
  run is_valid_client_name "acme_corp"
  assert_failure
}

@test "is_valid_client_name: 65 chars retorna 1" {
  local name
  name=$(printf '%0.s-' {1..65} | tr -d '\n' | sed 's/^-/a/;s/-$/a/')
  # Garante 65 chars com apenas a-z0-9-
  name="$(python3 -c "print('a' * 65)")"
  run is_valid_client_name "$name"
  assert_failure
}

@test "is_valid_client_name: string vazia retorna 1" {
  run is_valid_client_name ""
  assert_failure
}

@test "is_valid_client_name: underscore reservado '_' retorna 1" {
  run is_valid_client_name "_"
  assert_failure
}

# ============================================================
# is_valid_uuid_v4
# ============================================================

@test "is_valid_uuid_v4: UUID v4 lowercase válido retorna 0" {
  run is_valid_uuid_v4 "550e8400-e29b-41d4-a716-446655440000"
  assert_success
}

@test "is_valid_uuid_v4: UUID v3 (versão 3) retorna 1" {
  run is_valid_uuid_v4 "550e8400-e29b-31d4-a716-446655440000"
  assert_failure
}

@test "is_valid_uuid_v4: UUID uppercase retorna 1" {
  run is_valid_uuid_v4 "550E8400-E29B-41D4-A716-446655440000"
  assert_failure
}

# ============================================================
# is_valid_https_url
# ============================================================

@test "is_valid_https_url: URL https válida retorna 0" {
  run is_valid_https_url "https://api.example.com/hook"
  assert_success
}

@test "is_valid_https_url: URL http (não https) retorna 1" {
  run is_valid_https_url "http://api.example.com/hook"
  assert_failure
}

@test "is_valid_https_url: IP privado RFC1918 192.168.x.x retorna 1" {
  run is_valid_https_url "https://192.168.1.1/hook"
  assert_failure
}

@test "is_valid_https_url: IP privado RFC1918 10.x.x.x retorna 1" {
  run is_valid_https_url "https://10.0.0.1/hook"
  assert_failure
}

@test "is_valid_https_url: IP privado RFC1918 172.16.x.x retorna 1" {
  run is_valid_https_url "https://172.16.0.1/hook"
  assert_failure
}

# ============================================================
# parse_global_flags
# ============================================================

@test "parse_global_flags: flags simples setadas corretamente" {
  run parse_global_flags --async --json
  assert_success
  # Re-executar sem subshell para verificar PARSED_FLAGS
  parse_global_flags --async --json
  assert_equal "${PARSED_FLAGS[async]}" "1"
  assert_equal "${PARSED_FLAGS[json]}" "1"
}

@test "parse_global_flags: --callback sem --async retorna exit 5" {
  run parse_global_flags --callback="https://api.example.com/hook"
  assert_equal "$status" "5"
}

@test "parse_global_flags: --callback com --async é aceito" {
  run parse_global_flags --async --callback="https://api.example.com/hook"
  assert_success
}

@test "parse_global_flags: flag booleana com =value retorna exit 5" {
  run parse_global_flags --async=true
  assert_equal "$status" "5"
}

# ============================================================
# is_async_allowed_cmd
# ============================================================

@test "is_async_allowed_cmd: 'create' é permitido" {
  run is_async_allowed_cmd "create"
  assert_success
}

@test "is_async_allowed_cmd: 'status' não é permitido" {
  run is_async_allowed_cmd "status"
  assert_failure
}

@test "is_async_allowed_cmd: 'user-create' é permitido" {
  run is_async_allowed_cmd "user-create"
  assert_success
}
