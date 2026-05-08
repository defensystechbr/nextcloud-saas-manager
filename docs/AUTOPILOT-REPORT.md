# Autopilot Report

> Gerado automaticamente pelo pipeline (`scripts/pipeline.sh`).

## Sprint D1 — CONCLUIDA — Fundacao (Tests + CI + Refactor Base)

**Commit**: `2788fe3 feat(sprint-D1): Fundação — tests skeleton, lib/*.sh e refactor manage.sh`
**Branch**: `sprint/D1`
**Data**: 2026-05-07

### Tasks completadas (10/11)

| Task | Status | Artefato |
|------|--------|----------|
| 1.1 — Validar bats.yml | DONE | `.github/workflows/bats.yml` |
| 1.2 — Validar shellcheck.yml | DONE | `.github/workflows/shellcheck.yml` |
| 1.3 — Validar contracts-check.yml | DONE | `.github/workflows/contracts-check.yml` |
| 1.4 — Estruturar tests/ | DONE | `tests/helpers/setup.bash`, `tests/helpers/redis_fixture.bash`, `tests/sanity.bats`, `tests/install-deps.sh`, `Makefile` |
| 1.5 — validators.sh + testes | DONE | `scripts/lib/validators.sh`, `tests/unit/test_validators.bats` |
| 1.6 — output_json.sh + testes | DONE | `scripts/lib/output_json.sh`, `tests/unit/test_output_json.bats` |
| 1.7 — job_queue.sh + testes | DONE | `scripts/lib/job_queue.sh`, `tests/integration/test_job_queue.bats` |
| 1.8 — job_runner.sh + testes | DONE | `scripts/lib/job_runner.sh`, `tests/unit/test_job_runner.bats` |
| 1.9 — ssh_audit.sh + testes | DONE | `scripts/lib/ssh_audit.sh`, `tests/unit/test_ssh_audit.bats` |
| 1.10 — Refatorar manage.sh | DONE | `scripts/manage.sh` (sources lib/*.sh, legacy_helpers.sh extraido) |
| 1.11 — Atualizar deploy-server.sh | DEFERRED | F-D1-001: hook de seguranca bloqueia edicao (credenciais inline) |

### Findings (auditoria pos-sprint)

| ID | Severidade | Descricao | Status |
|----|-----------|-----------|--------|
| F-D1-001 | LOW | deploy-server.sh nao editavel por hook | DEFERRED D2 |
| F-D1-002 | LOW | get_state awk parser nao escapa aspas | DEFERRED D2 |
| F-D1-003 | INFO | worker_status "null" string vs JSON null | DEFERRED D2 |
| F-D1-004 | INFO | manage.sh > 500 LOC (refactor parcial) | ACCEPTED |
| F-D1-005 | INFO | validators.sh set -euo pipefail em source | ACCEPTED |

**CRITICAL/HIGH: 0** | **Bloqueadores: 0** | **Resultado: APROVADA**

### Artefatos entregues

- 6 bibliotecas em `scripts/lib/` (validators, output_json, job_queue, job_runner, ssh_audit, legacy_helpers)
- 7 arquivos de teste Bats (1 sanity + 4 unit + 2 integration)
- 4 fixtures de teste (`tests/fixtures/`)
- Makefile com alvos test-unit, test-integration, test-e2e, test
- 3 workflows CI validados (bats, shellcheck, contracts-check)
- manage.sh refatorado para invocar lib/*.sh mantendo compatibilidade legado

## Sprint D2 — APROVADA VIA F1 — Async Core (Queue + Worker + SSH + Observabilidade)

**Branch**: `sprint/D2`
**Data**: 2026-05-08

### Tasks completadas (11/11)

| Task | Status | Artefato |
|------|--------|----------|
| 2.1 — manage-cli parte 2: parser hibrido + dispatch async | DONE | `scripts/manage.sh` (914 LOC), `scripts/lib/dispatch.sh`, `scripts/lib/validators.sh` |
| 2.2 — Idempotency idem_check integrado ao manage-cli | DONE | `scripts/lib/job_queue.sh::idem_check` + `dispatch_enqueue` |
| 2.3 — worker.sh daemon (BRPOP + callback HMAC + lock duplo) | DONE | `scripts/worker.sh` (396 LOC) |
| 2.4 — Instalar systemd units via setup-worker.sh | DONE | `scripts/setup-worker.sh` (AOF + units + jobs dir) |
| 2.5 — SSH gateway ncsaas-api + shim | DONE | `scripts/setup-ssh-gateway.sh`, `scripts/ncsaas-api-shim` |
| 2.6 — Wiring observability (NDJSON + journald retention) | DONE | `journald.conf.d/50-nextcloud-saas.conf`, log_event em dispatch/worker/shim |
| 2.7 — worker status --json | DONE | `scripts/lib/job_queue.sh::worker_status` |
| 2.8 — job status/logs/cancel + job list (Q-1/Q-2/Q-4) | DONE | `scripts/lib/job_queue.sh::job_cancel/job_list`, `scripts/manage.sh` dispatcher |
| 2.9 — worker stats --by-cmd/--by-client (Q-3) | DONE | `scripts/lib/job_queue.sh::worker_stats` (SCAN MATCH) |
| 2.10 — Tests integration e2e async | DONE | 8 test files em `tests/integration/` |
| 2.11 — Atualizar README + ADMINISTRATION | DONE | `README.md`, `docs/ADMINISTRATION.md` |

### Findings D2 bloqueadores

| ID | Severidade | Descricao | Status |
|----|-----------|-----------|--------|
| F-D2-001 | CRITICAL | `manage.sh` e `worker.sh` falham no startup por sobrescrita de `SCRIPT_DIR` | FIXED |
| F-D2-002 | CRITICAL | `get_state` gera JSON invalido para jobs async reais com `args_json` | FIXED |
| F-D2-003 | HIGH | `--password=*` e removido antes da validacao de seguranca | FIXED |
| F-D2-004 | HIGH | `--async --json` mistura evento de audit e `EnqueuedJob` em stdout | FIXED |
| F-D2-005 | HIGH | Callback pode ser enviado sem HMAC real quando secret esta ausente | FIXED |
| F-D2-006 | HIGH | Testes D2 de idempotencia estao incompatíveis com a assinatura atual | FIXED |
| F-D2-007 | HIGH | Ambiente local nao consegue executar o gate dinamico da Sprint D2 | FIXED |

**CRITICAL/HIGH: 0** | **Bloqueadores: 0** | **Resultado: APROVADA via Sprint F1**

### Evidencia de revalidacao F1

- `make shellcheck` = PASS
- `npm exec --yes --package bats -- bats --tap tests/sanity.bats` = 1/1 PASS
- `npm exec --yes --package bats -- bats --tap --recursive tests/unit` = 50/50 PASS
- `timeout 240 npm exec --yes --package bats -- bats --tap --recursive tests/integration` = 96/96 PASS (Docker daemon disponivel; Redis fixture via `redis:7-alpine`)

### Findings D1 herdados

| ID | Severidade | Descricao | Status |
|----|-----------|-----------|--------|
| F-D1-001 | LOW | deploy-server.sh nao editavel por hook | DEFERRED (hook de seguranca) |
| F-D1-002 | LOW | get_state awk parser nao escapa aspas | DEFERRED D3 |
| F-D1-003 | INFO | worker_status "null" string vs JSON null | DEFERRED D3 |

**CRITICAL/HIGH: 0** | **Bloqueadores: 0** | **Resultado: APROVADA via F1**

### Artefatos entregues

- `scripts/lib/dispatch.sh` — dispatcher hibrido (legado posicional + namespaces hierarquicos)
- `scripts/lib/validators.sh` — estendido com parse_global_flags, RESERVED_NAMESPACES, ASYNC_ALLOWED, has_password_in_argv, compute_args_hash
- `scripts/lib/job_queue.sh` — estendido com idem_check, idem_lookup, dequeue (BRPOP), client_lock_*, worker_lock_*, worker_status, job_cancel, worker_stats, job_list
- `scripts/worker.sh` — daemon completo: BRPOP loop, process_job, callback HMAC-SHA256 com retry exponencial, lock duplo (flock+Redis), client lock por cliente, watchdog systemd notify, SIGTERM graceful shutdown
- `scripts/ncsaas-api-shim` — ForceCommand SSH: validacao metacaracteres, allowlist hierarquica, audit log NDJSON, sanitizacao de senhas, sudo exec
- `scripts/setup-worker.sh` — instalador idempotente: worker binary, systemd units, env, jobs-gc timer, AOF no shared-redis
- `scripts/setup-ssh-gateway.sh` — instalador idempotente: usuario ncsaas-api, shim, sshd configs, sudoers, inbox dir, journald retention
- `journald.conf.d/50-nextcloud-saas.conf` — retencao 30d, 2G max, compress
- `scripts/manage.sh` — estendido para 914 LOC: dispatcher raiz com worker/job/client paths, parse_global_flags, namespace detection
- 8 arquivos de teste integration Bats (async dispatch, idempotency, worker loop, worker callback, job management, ssh shim, observability, e2e async)
- `README.md` + `docs/ADMINISTRATION.md` — secoes "Modo assincrono e API REST consumidora"

## Sprint F1 — CONCLUIDA — Fix Gate D2

**Origem**: `/pmo fix` apos `/qa validar` reprovar D2.
**Bloqueadores corrigidos**: `F-D2-001` a `F-D2-007` (+ `F-D2-008`/`F-D2-009` detectados na revalidacao)
**Proximo passo**: registrar commit da F1 e retomar D3.
