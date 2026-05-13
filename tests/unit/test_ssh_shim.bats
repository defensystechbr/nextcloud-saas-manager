#!/usr/bin/env bats
# tests/unit/test_ssh_shim.bats
# Testa _sanitize_for_log do ncsaas-api-shim (QA-001 N1.1).
# Nao requer Redis. Extrai a funcao de sanitizacao via sed e executa em subshell.

SHIM_PATH="${BATS_TEST_DIRNAME}/../../scripts/ncsaas-api-shim"

# Wrapper: extrai _sanitize_for_log do shim e executa em subshell isolado.
# Evita executar o corpo principal do shim (que requer SSH_ORIGINAL_COMMAND).
_call_sanitize() {
  local fn_def
  fn_def="$(sed -n '/^_sanitize_for_log()/,/^}/p' "$SHIM_PATH")"
  bash -c "${fn_def}
_sanitize_for_log \"\$@\"" -- "$@"
}

# ─── QA-001: Forma 1 — --password=VALUE (com =) ─────────────────────────────
@test "sanitize: --password=VALUE (forma =) e mascarado" {
  run _call_sanitize "nextcloud-manage acme user create john --password=mysecret --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--password=***"* ]]
  [[ "$output" != *"mysecret"* ]]
}

# ─── QA-001: Forma 2 — --password VALUE (separado por espaco) ────────────────
@test "sanitize: --password VALUE (forma espaco) e mascarado" {
  run _call_sanitize "nextcloud-manage acme user create john --password mysecret --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--password ***"* ]]
  [[ "$output" != *"mysecret"* ]]
}

# ─── QA-001: --password sozinho (sem valor) nao e alterado ───────────────────
@test "sanitize: --password sem valor nao introduz asteriscos" {
  run _call_sanitize "nextcloud-manage acme user create john --password"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--password"* ]]
  [[ "$output" != *"--password ***"* ]]
  [[ "$output" != *"--password=***"* ]]
}

# ─── Regressao: --password-from-env=VALUE tambem e mascarado ─────────────────
@test "sanitize: --password-from-env=VALUE e mascarado" {
  run _call_sanitize "nextcloud-manage acme user create john --password-from-env=SOME_VAR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--password-from-env=***"* ]]
  [[ "$output" != *"SOME_VAR"* ]]
}

# ─── Regressao: comando sem senha nao e alterado ─────────────────────────────
@test "sanitize: comando sem senha retorna linha inalterada" {
  run _call_sanitize "nextcloud-manage acme _ backup --async --json"
  [ "$status" -eq 0 ]
  [ "$output" = "nextcloud-manage acme _ backup --async --json" ]
}
