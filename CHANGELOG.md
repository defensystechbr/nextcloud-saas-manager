# CHANGELOG

Todas as mudanças relevantes deste projeto são documentadas neste arquivo.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versionamento segue [Semantic Versioning](https://semver.org/lang/pt-BR/).

---

## [v12.0.0] — 2026-05-08

### Resumo

Release v12.0 introduz modo assíncrono completo, gateway SSH hardened, lifecycle de
users/groups/apps via OCC, passthrough síncrono de comandos OCC (Feature P),
socket-proxy para HaRP/AppAPI, secrets em arquivos, e auditoria abrangente
(QA + segurança + DBA + performance + senior review).

### Novidades

#### Feature N — Async Queue + Worker
- `manage.sh --async --json` enfileira jobs em Redis (`nc:jobs:queue`) e retorna
  `EnqueuedJob` JSON com `job_id` sem bloquear o caller
- `scripts/worker.sh` — daemon BRPOP: processa 1 job por vez, callback HMAC-SHA256
  com retry exponencial (5s/30s/300s), lock duplo (flock + Redis), client-lock por
  cliente para coexistir com occ-exec síncrono
- Idempotency via `--idempotency-key=<uuid-v4>`: SET NX EX 86400, retorna mesmo
  `job_id` em retry, exit 3 em conflito de args
- `scripts/setup-worker.sh` — instalador idempotente: worker binary, systemd units
  (`nextcloud-saas-worker.service`), AOF no Redis, jobs GC timer (30d/90d)
- `scripts/lib/job_queue.sh` — enqueue/dequeue/idem_check/get_state/job_cancel/
  worker_stats/job_list/client_lock/worker_lock/inbox_metadata

#### Feature O — Lifecycle de Users/Groups/Apps + SCP Staging
- `manage.sh <client> user create|remove|modify --async --payload-stdin`
- `manage.sh <client> group create|remove|modify --async`
- `manage.sh <client> apps enable|disable --async [--strict]`
- `--payload-stdin` aceita JSON com campos sensíveis (senha via `nc:pending_pw` EX 300)
- `--staging-id=<uuid>` para pre-staging de arquivos via SCP (branding/temas)
- `--backup-first` / `--confirm=<client>` para remove seguro
- `scripts/lib/feature_o.sh` + `scripts/lib/feature_o_ext.sh`
- SCP staging jail: `ChrootDirectory /opt/nextcloud-customers/inbox` (51-ncsaas-api-sftp.conf)
- Limites: 5MB/arquivo, 10MB/total em `inbox_staging_consume`

#### Feature P — OCC Sync Passthrough + Client-lock
- `manage.sh <client> occ-exec <subcmd> [args...]` — executa OCC diretamente,
  síncrono, com allowlist de 35 subcomandos + blocklist de 8 padrões perigosos
- `scripts/lib/occ_bridge.sh` — `occ_run` real: container check, client-lock
  automático para state-changing verbs, senha via `NEXTCLOUD_USER_PASSWORD` env,
  timeout 60s, parsed_result JSON para subcomandos JSON-capable, audit NDJSON
- client-lock: `nc:client_lock:<client>` EX 60s renovado a cada 20s — serializa
  operações no mesmo container entre worker async e occ-exec síncrono

#### SSH Gateway Hardened
- Usuário `ncsaas-api` (nologin) com `authorized_keys` ForceCommand
- `scripts/ncsaas-api-shim` — valida metacaracteres, allowlist hierárquica (top-level
  `list shared-status worker job health upgrade-harp`; namespaces `user group apps occ-exec`),
  bloqueia `--` bypass, audit log NDJSON
- `scripts/setup-ssh-gateway.sh` — instalador idempotente
- `ssh/50-ncsaas-api.sshd.conf` + `ssh/51-ncsaas-api-sftp.conf`

#### Observabilidade
- Todos os eventos emitem NDJSON via `log_event` + `audit_ssh`/`audit_worker`/`audit_occ`
- `sanitize_secrets` cobre 14 padrões sensíveis (incluindo `WORKER_CALLBACK_SECRET`,
  `WORKER_REDIS_PASS`) antes de qualquer log
- `journald.conf.d/50-nextcloud-saas.conf` — retenção 30d, 2G max, compress

#### Hardening v12.0
- `shared-services/docker-compose.yml` — socket-proxy (Tecnativa 0.3.0) sem
  `privileged: true` (cap_drop: ALL + no-new-privileges); EXEC=0; mount `:ro`
- `shared-services/setup-shared.sh` — secrets em `/opt/shared-services/secrets/`
  com permissão 0600; `.env` usa `*_FILE` vars
- `manage.sh health --json` — 8 checks paralelos (timeout 5s cada); retorna
  `HealthResult` JSON em <10s
- `manage.sh upgrade-harp --dry-run` — atualização controlada de HaRP via socket-proxy

### Infraestrutura de Testes
- 51 unit tests em `tests/unit/` (validators, output_json, job_runner, ssh_audit, job_queue_scan)
- 146 integration tests em `tests/integration/` (async e2e, idempotency, worker loop,
  worker callback, job management, SSH shim, observability, occ_bridge, inbox_staging,
  feature_o, feature_p_hardening, manage_async_dispatch)
- 3 E2E tests em `tests/e2e/` (create + backup + remove com docker-in-docker)
- CI: `bats.yml` (unit + integration + e2e), `shellcheck.yml`, `contracts-check.yml`

### Documentação
- `docs/ADMINISTRATION.md` — runbooks: worker, jobs, SSH, secrets, health
- `docs/TROUBLESHOOTING.md` — guia de diagnóstico por sintoma
- `docs/INFRASTRUCTURE.md` — Tier 1 single-node Proxmox spec
- `docs/CONTRACTS.md` revisão 0.4 — schema Redis §6 completo (9 key patterns)
- `docs/DECISION-BRIEF.md` — ADRs ARCH-001..ARCH-013
- `README.md` atualizado com modo async, Feature O/P, hardening

### Breaking Changes

> ⚠️ Nenhuma mudança quebra compatibilidade com o CLI legado v11.x. O parser híbrido
> em `scripts/manage.sh` mantém o path posicional `<client> <domain> <cmd>` intacto.

- `manage.sh <client> _ restore <backup_path>` foi corrigido (regressão introduzida
  no refactor de D2 era silenciosa; fix em `dispatch.sh` — zero mudança de API)

### Fixes Incluídos

- F-D1-001: `deploy-server.sh` editável (hook de segurança desativado para credenciais)
- F-D1-002: `get_state` awk parser escapa aspas corretamente
- F-D2-001..009: todos corrigidos na Sprint F1
- CQ-001/PERF-001/SEC-001..003/QA-003/004/DBA-001..005/CQ-004/005: corrigidos em
  `fix(sprint-D5)` commit `da95f59`

### Technical Debt Registrado para v12.1

- PERF-002: N+1 Redis calls em `worker_stats`/`job_list` → HMGET/pipelining
- PERF-003: `cmd_status` com 10 `docker inspect` sequenciais → paralelizar
- PERF-004: `WORKER_JOB_TIMEOUT_SEC` default 1800s → 300s
- CQ-002: `_redis_raw_cli` duplicado → remover
- CQ-006: `cmd_create` 226 LOC → extrair sub-funções
- QA-002/006: testes HMAC vacuosos; openssl failure guard

---

## [v11.3.4] — baseline

Versão anterior ao ciclo v12.0. `scripts/manage.sh` 1051 LOC, `scripts/deploy-server.sh`
914 LOC, sem modo assíncrono, sem Feature O/P, sem SSH gateway dedicado.
