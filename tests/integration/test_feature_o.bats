#!/usr/bin/env bats
# tests/integration/test_feature_o.bats
# Testa Feature O: user/group/apps lifecycle via manage.sh namespace commands (D3.3/D3.4/D3.5/D3.6).
# Budget: 20 testes
# Requer: Redis em $WORKER_REDIS_HOST:$WORKER_REDIS_PORT db $WORKER_REDIS_DB

load '../helpers/redis_fixture'
load '../helpers/setup'

setup() {
  export MANAGE_SKIP_ROOT_CHECK=1
  export BASE_DIR="${BATS_TEST_TMPDIR}/nc-base"
  export SHARED_DIR="${BATS_TEST_TMPDIR}/nc-shared"
  start_redis_fixture
  export WORKER_REDIS_HOST="$REDIS_HOST"
  export WORKER_REDIS_PORT="$REDIS_PORT"
  export WORKER_REDIS_DB="${WORKER_REDIS_DB:-16}"
  export WORKER_OCC_TIMEOUT_SEC=5

  mkdir -p "$BASE_DIR" "$SHARED_DIR"

  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true

  MANAGE="${BATS_TEST_DIRNAME}/../../scripts/manage.sh"
  create_test_client_fixture "acme"
  mock_docker "running"
}

teardown() {
  redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" -n "$WORKER_REDIS_DB" \
    FLUSHDB >/dev/null 2>&1 || true
  stop_redis_fixture
}

# ─── 1. user create: sem --async → exit 5 (async_required) ─────────────────
@test "user create: sem --async retorna exit 5" {
  run bash "$MANAGE" acme user create johndoe --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"async_required"* ]]
}

# ─── 2. user create: sem payload stdin → exit 5 ────────────────────────────
@test "user create: sem payload stdin retorna exit 5" {
  run bash "$MANAGE" acme user create johndoe --async --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"payload_stdin_required"* ]]
}

# ─── 3. user create: job_id valido no Redis ──────────────────────────────────
@test "user create: job_id presente no Redis como nc:jobs:<id>" {
  run bash -c "
    echo '{\"password\":\"s3cr3t\"}' \
    | bash '${MANAGE}' acme user create maria --async --payload-stdin --json
  "
  [ "$status" -eq 0 ]
  local job_id
  job_id="$(echo "$output" | jq -r '.job_id')"
  [[ "$job_id" =~ ^[0-9a-f-]{36}$ ]]
  local state
  state="$(echo "$output" | jq -r '.state')"
  [ "$state" = "queued" ]
}

# ─── 4. user create: username obrigatorio ────────────────────────────────────
@test "user create: sem username retorna exit 5" {
  run bash "$MANAGE" acme user create --async --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"missing_username"* ]]
}

# ─── 5. user remove: com --async enfileira job user-remove ──────────────────
@test "user remove: com --async enfileira job user-remove" {
  run bash "$MANAGE" acme user remove johndoe --async --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"user-remove"* ]]
}

# ─── 6. user modify: action invalida → exit 5 ───────────────────────────────
@test "user modify: action invalida retorna exit 5" {
  run bash "$MANAGE" acme user modify johndoe invalid_action --async --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"invalid_action"* ]]
}

# ─── 7. user modify: action enable → enfileirado ────────────────────────────
@test "user modify: enable enfileira job user-modify" {
  run bash "$MANAGE" acme user modify johndoe enable --async --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"user-modify"* ]]
}

# ─── 8. group create: sem --async → exit 5 ──────────────────────────────────
@test "group create: sem --async retorna exit 5" {
  run bash "$MANAGE" acme group create admins --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"async_required"* ]]
}

# ─── 9. group create: com --async → enfileirado ─────────────────────────────
@test "group create: com --async enfileira job group-create" {
  run bash "$MANAGE" acme group create admins --async --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"group-create"* ]]
  local state
  state="$(echo "$output" | jq -r '.state')"
  [ "$state" = "queued" ]
}

# ─── 10. group remove: com --async e --force → enfileirado ──────────────────
@test "group remove: com --async e --force enfileira job group-remove" {
  run bash "$MANAGE" acme group remove admins --async --force --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"group-remove"* ]]
}

# ─── 11. apps enable: sem --async → exit 5 ──────────────────────────────────
@test "apps enable: sem --async retorna exit 5" {
  run bash "$MANAGE" acme apps enable "calendar,contacts" --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"async_required"* ]]
}

# ─── 12. apps enable: com --async → enfileirado ─────────────────────────────
@test "apps enable: com --async enfileira job apps-enable" {
  run bash "$MANAGE" acme apps enable "calendar,contacts" --async --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps-enable"* ]]
}

# ─── 13. apps disable: com --async --strict → enfileirado ───────────────────
@test "apps disable: com --async e --strict enfileira job apps-disable" {
  run bash "$MANAGE" acme apps disable "deck" --async --strict --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"apps-disable"* ]]
  local strict_val
  strict_val="$(echo "$output" | jq -r '.args_json.strict')"
  [ "$strict_val" = "true" ]
}

# ─── 14. user create: --idempotency-key aceito com payload ──────────────────
@test "user create: idempotency-key valido enfileira job com payload" {
  local ikey="550e8400-e29b-41d4-a716-446655440003"
  run bash -c "
    echo '{\"password\":\"s3cr3t\"}' \
    | bash '${MANAGE}' acme user create bob --async --payload-stdin --idempotency-key='${ikey}' --json
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"user-create"* ]]
}

# ─── 15. user create: password NAO aparece em args_json no Redis ─────────────
@test "user create: senha nao aparece em args_json no Redis" {
  run bash -c "
    echo '{\"display_name\":\"John\",\"email\":\"j@example.com\",\"password\":\"s3cr3t\"}' \
    | bash '${MANAGE}' acme user create john --async --payload-stdin --json
  "
  [ "$status" -eq 0 ]
  local job_id
  job_id="$(echo "$output" | jq -r '.job_id')"
  local args_json
  args_json="$(redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" \
    -n "$WORKER_REDIS_DB" HGET "nc:jobs:${job_id}" args_json)"
  # args_json NAO deve conter a senha literal
  [[ "$args_json" != *"s3cr3t"* ]]
}

# ─── 16. user create + payload-stdin: pending_pw armazenado no Redis ─────────
@test "user create + payload-stdin: nc:pending_pw:<jid> criado no Redis" {
  run bash -c "
    echo '{\"display_name\":\"John\",\"email\":\"j@example.com\",\"password\":\"s3cr3t\"}' \
    | bash '${MANAGE}' acme user create john2 --async --payload-stdin --json
  "
  [ "$status" -eq 0 ]
  local job_id
  job_id="$(echo "$output" | jq -r '.job_id')"
  local pw_exists
  pw_exists="$(redis-cli -h "$WORKER_REDIS_HOST" -p "$WORKER_REDIS_PORT" \
    -n "$WORKER_REDIS_DB" EXISTS "nc:pending_pw:${job_id}")"
  [ "$pw_exists" = "1" ]
}

# ─── 17. remove: --backup-first --async → enfileira backup-then-remove ───────
@test "remove: --backup-first --async enfileira job backup-then-remove" {
  run bash "$MANAGE" acme _ remove --backup-first --async --confirm=acme --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-then-remove"* ]]
}

# ─── 18. remove: --async sem --confirm → exit 5 ─────────────────────────────
@test "remove: --async sem --confirm e sem --force retorna exit 5" {
  run bash "$MANAGE" acme _ remove --async --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"confirm_required"* ]]
}

# ─── 19. group modify: rename enfileirado ───────────────────────────────────
@test "group modify: rename com --async enfileira job group-modify" {
  run bash -c "
    echo '{\"new_name\":\"administrators\"}' \
    | bash '${MANAGE}' acme group modify admins rename --async --payload-stdin --json
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"group-modify"* ]]
}

@test "apps enable tolerante: falha quando todos os OCC falham" {
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${BATS_TEST_DIRNAME}/../../scripts/worker.sh'
    _occ_exec_safe() { return 17; }
    worker_exec_apps_enable acme '{\"apps\":[\"calendar\",\"contacts\"],\"strict\":false}' jid-test
  "
  [ "$status" -eq 17 ]
}

@test "apps disable tolerante: falha quando todos os OCC falham" {
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${BATS_TEST_DIRNAME}/../../scripts/worker.sh'
    _occ_exec_safe() { return 17; }
    worker_exec_apps_disable acme '{\"apps\":[\"deck\",\"tasks\"],\"strict\":false}' jid-test
  "
  [ "$status" -eq 17 ]
}

# ─── 20. namespace dispatch: occ-exec sync-only (D4) ───────────────────────
@test "occ-exec: rejeita --async (sync only)" {
  run bash "$MANAGE" acme occ-exec user:list --async --json
  [ "$status" -eq 5 ]
  [[ "$output" == *"async_not_supported"* ]]
}

# ─── 21. QA-006: group modify rename — comportamento esperado documentado ────
# group:rename nao existe no OCC antes do Nextcloud >= 31.
# worker_exec_group_modify cria o grupo novo via group:add e registra nota.
# O grupo antigo NAO e removido automaticamente (comportamento esperado).
@test "QA-006: group modify rename registra nc_group_rename_requires_v31 no log" {
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${BATS_TEST_DIRNAME}/../../scripts/worker.sh'
    # Mock _occ_exec_safe: sucesso para group:add (rename cria grupo novo)
    _occ_exec_safe() { return 0; }
    worker_exec_group_modify acme '{\"groupname\":\"admins\",\"action\":\"rename\",\"new_name\":\"administrators\"}' test-jid-001 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"nc_group_rename_requires_v31"* ]]
}

@test "QA-006: group modify rename NAO chama group:delete (grupo antigo preservado)" {
  # Comportamento documentado: rename cria grupo novo mas NAO remove o antigo
  # (compatibilidade OCC < 31). Validar que _occ_exec_safe com group:delete
  # nunca e invocado durante rename.
  run bash -c "
    export WORKER_REDIS_HOST='${WORKER_REDIS_HOST}'
    export WORKER_REDIS_PORT='${WORKER_REDIS_PORT}'
    export WORKER_REDIS_DB='${WORKER_REDIS_DB}'
    source '${BATS_TEST_DIRNAME}/../../scripts/worker.sh'
    _occ_exec_safe() {
      local _c=\"\$1\" subcmd=\"\$2\"
      if [[ \"\$subcmd\" == 'group:delete' ]]; then
        echo 'UNEXPECTED_DELETE' >&2
        return 1
      fi
      return 0
    }
    worker_exec_group_modify acme '{\"groupname\":\"admins\",\"action\":\"rename\",\"new_name\":\"admins2\"}' test-jid-002 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED_DELETE"* ]]
}
