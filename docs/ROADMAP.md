# Roadmap Tecnico — Nextcloud SaaS Manager v12.0

> Gerado em: 2026-05-07
> Fase: 9 — Planejamento Tecnico (concluido)
> Baseado em: docs/REQUIREMENTS.md (rev 0.3) + docs/ARCHITECTURE.md (1.0 Aprovada) + docs/CONTRACTS.md (rev 0.3) + docs/INFRASTRUCTURE.md (Tier 1)
> Status: Proposta — aguardando aprovacao do usuario para `/pmo sprint`
> Modo de execucao: **Autopilot** (`/jarvis pipeline` ou `/sprint-all`) — auditoria e o unico gate de qualidade entre sprints
> Branch de trabalho: `development` → tag `v12.0` ao final da Sprint D5
> Baseline: v11.3.4 (scripts/manage.sh 1.051 LOC, scripts/deploy-server.sh 914 LOC)

---

## Resumo

| Metrica | Valor |
|---------|-------|
| Total de tarefas | 48 |
| Total de sprints D | 5 (D1..D5) |
| Tarefas P (atomicas) | 22 |
| Tarefas M (com executor_prompt) | 26 |
| Tarefas G | 0 (proibido — decompostas) |
| Tasks `critica: true` (Best-of-N) | 4 — D2.1, D2.3, D3.1, D3.3 |
| Caminho critico | 12 tarefas sequenciais (D1.5 → D1.7 → D1.8 → D1.10 → D2.1 → D2.3 → D3.1 → D3.3 → D4.1 → D4.4 → D5.3 → D5.9) |
| Modulos cobertos | 15 (todos do `.cursorsession.modulos`) |
| Features endereçadas | N, A, B, C, D, M, O, P (P0 + P1 da v12.0) |
| ADRs propostas | ARCH-001..ARCH-008 + ADR-009 (SCP staging) + ADR-010 (OCC allowlist) + ADR-011 (traducao vocabularios) + ADR-012 (slug 64 chars) + ADR-013 (occ-bridge drift gate) |

---

## Indice de Sprints

> Agentes: leiam ESTE indice primeiro. So facam Read da secao completa se precisarem de notas tecnicas ou detalhes de tasks.

| Sprint | Categoria | Gate (resumo) | Status | Tasks | Modulos | Resumo | Linhas |
|--------|-----------|---------------|--------|-------|---------|--------|--------|
| D1 | D | tests/unit + tests/integration verde no CI; lib/*.sh extraido sem mudar comportamento | **concluida** | 11/11 | tests-bats, ci-shellcheck, manage-cli (refactor base) | Foundation: testes + CI + extracao de lib | 102-617 |
| D2 | D | API consegue create --async --json em <2s via SSH; worker executa real; callback HMAC dispara; idempotency 24h | **aprovada via F1** | 11/11 | manage-cli (parte 2), idempotency, worker, ssh-gateway, observability, queue-introspection | Async core: queue + worker + SSH + observabilidade | 618-1532 |
| F1 | F | Revalidar D2 sem CRITICAL/HIGH: CLI/worker iniciam, JSON de job state valido, senha/callback seguros, testes D2 coerentes | **concluida** | 7/7 | manage-cli, job_queue, worker, dispatch, tests, validation-env | Fix gate D2: corrigir blockers F-D2-001..007 antes de D3 | 1533-1592 |
| D3 | D | API consegue user/group/apps lifecycle async via SSH; SCP staging funciona em jail; senha nunca em journald | pendente | 8 | inbox-staging, user-group-apps, occ-bridge (Parte 1) | Feature O: lifecycle de users/groups/apps + SCP staging + occ-bridge interno | 1593-2276 |
| D4 | D | occ-exec sync passthrough em <60s; client-lock impede concorrencia; health 8 checks <10s; socket-proxy interposto; secrets em /opt/.../secrets | pendente | 8 | occ-bridge (Parte 2), client-lock, health-command, socket-proxy, secrets-file | Feature P + hardening: occ-exec + client-lock + health + socket-proxy + secrets | 2217-2650 |
| D5 | D | E2E docker-in-docker passa; auditorias verde; ADRs registradas; deploy staging validado; tag v12.0 publicado | pendente | 10 | docs, ADRs, e2e, auditorias | Estabilizacao + polish + deploy v12.0 | 2651-2763 |

---

## Estratégia de Auditoria

> Modo: **Autopilot** (definido pelo usuario em /pmo plan; ver `~/.cursor/skills/planejador-tarefas/references/phase-6-5-audit-strategy.md`)
> Decisao: Pipeline `/jarvis pipeline` / `/sprint-all` — auditoria entre sprints é o único gate de qualidade. Sem revisão humana entre sprints, nivel base e `senior+qa`; `comprehensive` na ultima.

| Sprint | Review | Motivo |
|--------|--------|--------|
| D1 | skip | Foundation: testes Bats + CI + extracao lib/*.sh **sem mudar comportamento**. Bats verde + ShellCheck verde + smoke do manage.sh atual sao gate suficiente. Nenhuma logica nova de negocio. |
| D2 | senior+qa | Async core entrega worker daemon (root, exec sudo), idempotencia, callback HMAC, observability sanitizada. Logica de negocio + seguranca. Senior code review + QA Fase 1 (cenarios de teste fechados). |
| D3 | senior+qa | Feature O toca senha de usuario (LGPD: `--payload-stdin` obrigatorio + scrub regex), SCP staging em jail SFTP, multi-step OCC. Auditor senior + QA validam cenarios de seguranca + LGPD. |
| D4 | senior+qa | Feature P expoe shell command externo (occ-exec via SSH) com allowlist de 33 OCC subcommands. Hardening de socket-proxy e secrets sao primeiros toques nessas superficies. Senior + QA revisam allowlist + bloqueio. |
| D5 | comprehensive | **Ultima sprint — pre-deploy v12.0**. Triage completa: senior code review + QA full + DBA (Redis schema, AOF, retencao) + performance (latencia <2s, health <10s) + seguranca (R-O-1..R-O-7 + vetores top-3 §7.3). E2E docker-in-docker passa. |

**Niveis** (referencia rapida):
- `skip`: testes bastam. Sem subagents de auditoria.
- `senior+qa`: 1 subagent (Senior Code Review + QA Fase 1). Sem triage.
- `comprehensive`: triage completa + auditores relevantes (senior + qa + dba + performance + security).

> Modo autopilot: metadata `review:` seguida sem perguntar; pipeline para na primeira sprint que falhar auditoria, abre `Sprint F` automatico via `/pmo fix`.

---

## Grafo de Dependencias

```
[D1.1 Bats CI] ─┐
[D1.2 ShellCheck CI] ─┤
[D1.3 Contracts CI] ─┤
[D1.4 tests/ skeleton] ─┼─► [D1.5 lib/validators.sh] ─┬─► [D1.10 manage.sh refactor]
[D1.11 deploy-server deps] ─┘                          ├─► [D1.6 lib/output_json.sh]
                                                       ├─► [D1.7 lib/job_queue.sh] ─► [D2.2 idempotency]
                                                       ├─► [D1.8 lib/job_runner.sh] ─► [D2.3 worker]
                                                       └─► [D1.9 lib/ssh_audit.sh] ─► [D2.5 ssh-gateway]

[D1.10 manage.sh refactor] ─► [D2.1 manage-cli flags] ─┬─► [D2.2 idempotency]
                                                       ├─► [D2.3 worker]
                                                       ├─► [D2.7 worker status]
                                                       ├─► [D2.8 job <id> status/logs/cancel/list]
                                                       └─► [D2.9 worker stats]

[D2.3 worker] + [D2.5 ssh-gateway] ─► [D3.1 occ_bridge.sh occ_run] ─┬─► [D3.3 user-group-apps user]
                                                                    ├─► [D3.4 user-group-apps group/apps]
                                                                    └─► [D4.1 occ-exec public]

[D3.2 inbox-staging] ─► [D3.5 create estendido]
[D2.3 worker] ─► [D4.2 client-lock] ─► [D4.1 occ-exec public]
[D4.4 socket-proxy] ─► [D4.3 health-command (check_harp)]
[D4.5 secrets-file] ─► [D5.9 deploy staging]

[D5.1..D5.10] ─► tag v12.0
```

**Tarefas raiz** (podem comecar imediatamente em D1): D1.1, D1.2, D1.3, D1.4, D1.11.
**Caminho critico**: D1.5 → D1.7 → D1.8 → D1.10 → D2.1 → D2.3 → D3.1 → D3.3 → D4.1 → D4.4 → D5.3 → D5.9 (12 tarefas).
**Paralelizaveis em D1**: D1.5/D1.6/D1.7/D1.8/D1.9 podem ser feitas em qualquer ordem apos D1.4 (tests skeleton).

---

## Sprint D1 — Fundacao (Tests + CI + Refactor Base)
> Categoria: D
> Gate: `bats tests/unit` + `bats tests/integration` verdes em CI; ShellCheck warning-clean em scripts/ e shared-services/; `lib/{validators,output_json,job_queue,job_runner,ssh_audit}.sh` extraidos com cobertura ≥60% das funcoes puras; `scripts/manage.sh` continua passando smoke test (todas as F01-F10 listadas em REQUIREMENTS §4.1 funcionam identicamente em ambiente de staging local).
> review: skip

| Status | Tamanho | Tarefa | Skill/Command | Depende de |
|--------|---------|--------|---------------|------------|
| [x] | P | 1.1 — Validar `.github/workflows/bats.yml` (job unit + integration com service redis:7-alpine) | `bash` + GitHub Actions UI | — |
| [x] | P | 1.2 — Validar `.github/workflows/shellcheck.yml` (severity=warning bloqueia, scandir scripts/+shared-services/+systemd/+ssh/) | `shellcheck` | — |
| [x] | P | 1.3 — Validar `.github/workflows/contracts-check.yml` (extrai JSON Schemas + OpenAPI + drift gate OCC allowlist §3.10.1 vs `lib/occ_bridge.sh`) | `check-jsonschema` + `redocly` | — |
| [x] | M | 1.4 — Estruturar `tests/` (helpers/setup.bash, helpers/redis_fixture.bash, estrutura unit/integration/e2e + Makefile alvo `make test`) | `bats` | — |
| [x] | M | 1.5 — Implementar `scripts/lib/validators.sh` + 6 testes unit | `bash` + `bats` | 1.4 |
| [x] | M | 1.6 — Implementar `scripts/lib/output_json.sh` + 5 testes unit | `bash` + `jq` + `bats` | 1.4 |
| [x] | M | 1.7 — Implementar `scripts/lib/job_queue.sh` + 6 testes integration (Redis) | `bash` + `redis-cli` + `bats` | 1.4 |
| [x] | M | 1.8 — Implementar `scripts/lib/job_runner.sh` + 4 testes unit (mock docker/redis) | `bash` + `bats` | 1.4 |
| [x] | M | 1.9 — Implementar `scripts/lib/ssh_audit.sh` + 3 testes unit (mock logger) | `bash` + `bats` | 1.4 |
| [x] | M | 1.10 — Refatorar `scripts/manage.sh` para invocar `lib/*.sh` mantendo comportamento legado (sem ainda dispatch async/namespaces — so estrutura) | `bash` + `bats` | 1.5–1.9 |
| [~] | P | 1.11 — Atualizar `scripts/deploy-server.sh` para `apt install -y jq redis-tools bats` e instalar `tests/` no server (somente smoke) | `bash` | — | DEFERRED → D2 (F-D1-001) |

**Notas tecnicas (tarefas M):**

<details>
<summary>1.4 — Estruturar tests/ (skeleton Bats + helpers)</summary>

- **Arquivo(s)**:
  - `tests/helpers/setup.bash` (export `BATS_LIB_PATH`, `PATH=$PWD/scripts:$PATH`, mock `docker` e `docker compose` opcional)
  - `tests/helpers/redis_fixture.bash` (start/stop redis container `redis:7-alpine` em port aleatorio; export `REDIS_HOST`/`REDIS_PORT`)
  - `tests/unit/.gitkeep`, `tests/integration/.gitkeep`, `tests/e2e/.gitkeep`
  - `Makefile` alvos: `test-unit`, `test-integration`, `test-e2e`, `test`
- **Abordagem**: usar Bats 1.10+ via `apt-get install -y bats`; `bats-core`, `bats-assert`, `bats-support` instalados via submodulo git em `tests/lib/` (script de setup `tests/install-deps.sh`).
- **Decisoes**: NAO usar `npm i -g bats` (premissa §8 REQUIREMENTS — sem dependencia node); apt do Ubuntu 24.04 ja tem Bats 1.10.
- **Edge cases**: CI sem rede para clonar `bats-assert` → mirror em `tests/lib/` versionado no repo (submodulo OK; tarball OK; CI cacheable). Redis ja disponivel via service container do bats.yml.
- **Anti-patterns**: nao testar `cmd_create` real em unit — exige docker-in-docker; deixar para `tests/e2e/`. Nao globar `*.bash` no `setup.bash` carregar — fontes explicitas para nao explodir contexto.
- **Validacoes**: `setup.bash` valida que `BATS_TEST_DIRNAME` esta setado (sentinel); `redis_fixture.bash` faz `redis-cli ping` antes de retornar.
- **Cenarios de teste**: (esta task estabelece infra; testes serao escritos em 1.5..1.9)
- **Budget**: 0 testes nesta task (infra sem logica) — apenas `tests/sanity.bats` smoke com 1 teste `assert_equal "1" "1"`.
- **References**:
  - `~/.cursor/skills/capabilities/testing-knowledge-base/testing-knowledge-base.md` — Secao 2 (input boundaries) referenciado em 1.5+
- **Criterio de aceite**:
  - `make test` retorna 0 com 1 teste passando (sanity)
  - `make test-unit` e `make test-integration` rodam separadamente
  - CI bats.yml verde
- **executor_prompt**: |
    Criar a estrutura `tests/` para Bats no projeto `nextcloud-saas-manager`.

    Arquivos a criar:
    1. `tests/helpers/setup.bash` — exporta BATS_LIB_PATH=tests/lib, prepende `$PWD/scripts` ao PATH, define helper `mock_docker()` que exporta DOCKER_FAKE_OUTPUT.
    2. `tests/helpers/redis_fixture.bash` — funcoes `start_redis_fixture()` (sobe redis:7-alpine em porta aleatoria via `docker run -d -p 0:6379`; espera `redis-cli ping` retornar PONG; export REDIS_HOST/REDIS_PORT) e `stop_redis_fixture()`.
    3. `tests/install-deps.sh` — script que clona `bats-core/bats-support` e `bats-core/bats-assert` em `tests/lib/` (idempotente; skip se ja existe).
    4. `tests/sanity.bats` — 1 teste smoke `@test "sanity" { assert_equal "1" "1"; }` que carrega setup.bash + bats-assert.
    5. `Makefile` na raiz com alvos `test-unit` (`bats tests/unit`), `test-integration` (`bats tests/integration`), `test-e2e` (`bats tests/e2e`), `test` (todos).
    6. `.gitignore` adicionar `tests/lib/`.

    NAO usar npm. Usar apenas apt e git submodules ou clone direto.
    Seguir convencao de naming: `test_<modulo>_<aspecto>.bats`.
    Imports padrao em todo `.bats`: `load 'helpers/setup'`, `load '../lib/bats-support/load'`, `load '../lib/bats-assert/load'`.
    Verificar: `make test` retorna 0 com 1 teste passando (`tests/sanity.bats`).
</details>

<details>
<summary>1.5 — Implementar scripts/lib/validators.sh + testes</summary>

- **Arquivo(s)**:
  - `scripts/lib/validators.sh` (funcoes puras — sem efeito colateral)
  - `tests/unit/test_validators.bats`
- **Abordagem**: Bash 5 (Ubuntu 24.04). Cada validador e funcao que retorna 0 (valido) ou 1 (invalido) e nao imprime nada por padrao; modo verboso opcional via `VALIDATORS_VERBOSE=1`. Validators sao **funcoes puras**: input via `$1...$N`, output via exit code.
- **Funcoes a criar**:
  - `is_valid_client_name <name>` — regex `^[a-z0-9-]{1,64}$` (CONTRACTS §3.4 atualizado para 64 chars)
  - `is_valid_fqdn <fqdn>` — regex `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$` + tamanho ≤253
  - `is_valid_uuid_v4 <uuid>` — regex `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`
  - `is_valid_https_url <url>` — comecar com `https://`, parse rudimentar de host, rejeitar IPs privados RFC1918 (defesa em profundidade contra SSRF do callback)
  - `parse_global_flags <argv...>` — assoc array de saida via `declare -gA PARSED_FLAGS` com chaves `async, idempotency_key, callback, json, dry_run, confirm, payload_stdin, staging_id, strict, no_async_pickup`
  - `is_async_allowed_cmd <cmd>` — lista hardcoded ASYNC_ALLOWED=(create remove backup restore update stop start user-create user-remove user-modify group-create group-remove group-modify apps-enable apps-disable)
- **Decisoes**: regex compiladas como variaveis `readonly` no topo do arquivo. `set -euo pipefail` no inicio do source-file (validators.sh). `parse_global_flags` aceita `--key=value` e `--key value`; rejeita `=` em flags booleanas (`--async=true` → exit 5).
- **Edge cases**:
  - Cliente `_` → invalido (uso reservado para "no domain")
  - FQDN com unicode → rejeitar (so ASCII a-z0-9-)
  - URL com IP privado (`https://192.168.1.1/hook`) → exit 1 (defesa SSRF)
  - UUID em maiusculas (`550E8400-...`) → invalido (so lowercase para padronizar hash de idempotency)
  - `--callback=https://api.example/hook` SEM `--async` → erro (callback_requires_async, exit 5) — validar em `parse_global_flags`
- **Anti-patterns**: nao usar `[[ "$x" =~ regex ]]` sem aspas no regex (Bash quebra com `*`); usar variavel intermediaria `local re='^[a-z0-9-]{1,64}$'; [[ "$x" =~ $re ]]`.
- **Validacoes**: cada funcao tem entrada, saida e exit code documentados em comentario `# usage:`.
- **Cenarios de teste** (Budget: 18 testes — Secao 2 KB input boundaries):
  - is_valid_client_name: "acme" → 0; "ACME" → 1; "acme_corp" → 1 (underscore proibido); 65 chars → 1; "" → 1; "_" → 1
  - is_valid_uuid_v4: "550e8400-e29b-41d4-a716-446655440000" → 0; "550e8400-e29b-31d4-..." (versao 3) → 1
  - is_valid_https_url: "https://api.example.com/hook" → 0; "http://api.example.com/hook" → 1; "https://192.168.1.1/hook" → 1
  - parse_global_flags: `--async --json --idempotency-key=<uuid> --callback=<url>` → flags setadas; `--callback=<url>` sem `--async` → exit 5
  - is_async_allowed_cmd: "create" → 0; "status" → 1; "user-create" → 0
- **Budget**: 18 testes
- **References**:
  - `~/.cursor/skills/capabilities/testing-knowledge-base/testing-knowledge-base.md` — Secao 2 (input boundaries: vazio, max+1, unicode, trim)
- **Criterio de aceite**:
  - `bats tests/unit/test_validators.bats` retorna 0 com ≥18 testes passando
  - ShellCheck warning-clean em `scripts/lib/validators.sh`
  - Funcoes podem ser sourcadas em isolamento (sem efeitos colaterais ao source)
- **executor_prompt**: |
    Criar `scripts/lib/validators.sh` com 6 funcoes puras: is_valid_client_name, is_valid_fqdn, is_valid_uuid_v4, is_valid_https_url, parse_global_flags, is_async_allowed_cmd.

    Convencoes:
    - Cabecalho `#!/bin/bash` + `set -euo pipefail` (no source nao roda; e para chamadas diretas em testes).
    - Cada funcao: comentario `# usage: <funcao> <argv>` + `# returns: 0=valido, 1=invalido`.
    - Regex em variaveis readonly no topo: RE_CLIENT_NAME, RE_FQDN, RE_UUID_V4, RE_HTTPS_URL.
    - parse_global_flags exporta `declare -gA PARSED_FLAGS` (assoc array global) com chaves: async, idempotency_key, callback, json, dry_run, confirm, payload_stdin, staging_id, strict, no_async_pickup. Aceita `--key=value` e `--key value`. Rejeita `=` em booleans com exit 5.
    - is_valid_https_url DEVE rejeitar IPs RFC1918 (192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12) — usar regex ou parse manual via `${url#https://}` + cut.
    - ASYNC_ALLOWED=(create remove backup restore update stop start user-create user-remove user-modify group-create group-remove group-modify apps-enable apps-disable) — referenciar CONTRACTS §3.6.

    Testes em `tests/unit/test_validators.bats`:
    - 18 testes cobrindo casos da Secao "Cenarios de teste" da nota tecnica.
    - Cada teste carrega `lib/validators.sh` via `source` no setup.
    - Usar `bats-assert` (`assert_success`, `assert_failure`, `assert_equal`).

    Ao final: `bats tests/unit/test_validators.bats` retorna 0; `shellcheck scripts/lib/validators.sh` sem warning.

    NAO usar `[[ ... =~ ... ]]` com aspas no regex (Bash quebra) — usar variavel intermediaria.
    NAO ter efeito colateral ao source — apenas declarar funcoes e readonly.
</details>

<details>
<summary>1.6 — Implementar scripts/lib/output_json.sh + testes</summary>

- **Arquivo(s)**:
  - `scripts/lib/output_json.sh`
  - `tests/unit/test_output_json.bats`
- **Abordagem**: wrapper sobre `jq -nc --arg/--argjson` para gerar JSON seguro sem string-concat. Funcao mestre `emit_json <key1> <val1> <key2> <val2> ...` que monta payload com `schema_version=1` automatico.
- **Funcoes a criar**:
  - `emit_json` — gera payload JSON com `schema_version="1"` + pares chave-valor; tipo string por default; prefixo `@number:` ou `@bool:` ou `@json:` no value para forcar tipo
  - `emit_error <code> <message> [retry_after]` — payload de erro padrao (CONTRACTS §3.6)
  - `log_event <level> <event> [k1 v1 ...]` — NDJSON em stdout com timestamp ISO8601 UTC + `level` + `event` + extras + sanitizacao via `sanitize_secrets`
  - `sanitize_secrets <text>` — regex global substituindo `(MYSQL_PASSWORD|NEXTCLOUD_ADMIN_PASSWORD|REDIS_PASSWORD|SIGNALING_SECRET|RECORDING_SECRET|TURN_SECRET|--password=)\S+` → `\1***`
- **Decisoes**: JSON sempre 1 linha (NDJSON). Cabecalho universal: todo emit_json injeta `schema_version="1"` (CONTRACTS §1.3). Sanitizacao e idempotente (chamar 2x produz mesmo output).
- **Edge cases**:
  - Strings com aspas, quebras de linha, unicode → `jq --arg` lida corretamente
  - Senha em meio de log via subshell (`bash -x`) → sanitizar regex tambem captura `=<value>` apos token reservado
  - Stdout buffered em pipe → usar `printf '%s\n'` ou `jq -nc` (auto-flush por linha)
- **Anti-patterns**:
  - **NUNCA** `echo "{\"key\":\"$value\"}"` — quebra com aspas, quebras de linha, unicode em $value. **SEMPRE** `jq -nc --arg key "$value" '{key:$key}'`.
  - Nao misturar humano + JSON na mesma linha — sempre 1 JSON por linha (NDJSON).
  - Nao confiar que `sanitize_secrets` foi chamada upstream — chamar **na origem** (em log_event sempre).
- **Validacoes**: `emit_json` valida que numero de args e par; rejeita keys vazias.
- **Cenarios de teste** (Budget: 12 testes):
  - emit_json com strings simples: `{"schema_version":"1","foo":"bar"}`
  - emit_json com numero: `emit_json count "@number:42"` → `{"schema_version":"1","count":42}`
  - emit_json com objeto JSON: `emit_json data "@json:{\"a\":1}"` → embedado correto
  - emit_json com unicode: `"São Paulo"` preservado
  - emit_json com aspa interna: `'O"Brian'` escapado
  - emit_error: `emit_error idempotency_conflict "key already used" 30` → `{schema_version,error,message,retry_after}`
  - log_event basico: stdout linha NDJSON com ts + level + event
  - sanitize_secrets: `MYSQL_PASSWORD=abc123` → `MYSQL_PASSWORD=***`
  - sanitize_secrets: `--password=secret123` → `--password=***`
  - sanitize_secrets: `senha normal` → inalterado
  - sanitize_secrets idempotente: chamar 2x = chamar 1x
  - log_event auto-sanitiza payload com senha
- **Budget**: 12 testes
- **References**:
  - `docs/CONTRACTS.md §1.3` (cabecalho universal schema_version)
  - `docs/CONTRACTS.md §3.5` (scrub agressivo)
- **Criterio de aceite**:
  - `bats tests/unit/test_output_json.bats` retorna 0 com 12 testes
  - ShellCheck warning-clean
  - Todo output JSON valida em `jq -e .` (parse-able)
- **executor_prompt**: |
    Criar `scripts/lib/output_json.sh` com 4 funcoes: emit_json, emit_error, log_event, sanitize_secrets.

    emit_json:
    - Args: pares <key> <value>; numero de args deve ser par (validar; exit 5 se impar).
    - Default tipo string; prefixos: `@number:`, `@bool:`, `@json:` forçam tipo.
    - Sempre injeta `schema_version="1"` na raiz.
    - Implementacao: construir array de --arg/--argjson dinamicamente e chamar `jq -nc`.

    Exemplo de uso interno:
    ```
    emit_json job_id "$jid" state "queued" queued_at "$ts" args_json "@json:$args"
    ```

    emit_error: wrapper que chama emit_json com keys fixas (error, message, retry_after opcional).

    log_event:
    - Args: <level> <event> [k1 v1 ...].
    - Output NDJSON em stdout com ts (ISO8601 UTC `date -u +%Y-%m-%dT%H:%M:%SZ`), level, event, extras.
    - Aplicar sanitize_secrets ao payload final ANTES de imprimir.

    sanitize_secrets:
    - Regex global (sed): `s/(MYSQL_PASSWORD|NEXTCLOUD_ADMIN_PASSWORD|REDIS_PASSWORD|SIGNALING_SECRET|RECORDING_SECRET|TURN_SECRET|--password|--password-from-env)=\S+/\1=***/g`.
    - Idempotente: aplicar 2x = aplicar 1x (regex casa apenas valor real, nao ***).
    - Refinar: apos primeiro replace, regex nao casa novamente porque `***` nao e `\S+` que comece com nao-`*`. Validar com teste de idempotencia.

    Testes (12) em `tests/unit/test_output_json.bats` cobrindo cenarios da nota tecnica.

    Ao final: bats verde + shellcheck warning-clean. NAO usar string-concat para JSON; SEMPRE jq.
</details>

<details>
<summary>1.7 — Implementar scripts/lib/job_queue.sh + testes integration</summary>

- **Arquivo(s)**:
  - `scripts/lib/job_queue.sh`
  - `tests/integration/test_job_queue.bats`
- **Abordagem**: wrappers sobre `redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" -n "$WORKER_REDIS_DB"`. Cada funcao recebe contexto via env vars (REDIS_*); nao tem state interno.
- **Funcoes a criar**:
  - `enqueue <job_id> <hash_key1> <hash_value1> ...` — `HSET nc:jobs:<id>` + `LPUSH nc:jobs:queue <id>`; pipelined via redis-cli `--pipe` ou `MULTI/EXEC`
  - `set_state <job_id> <state> [extra_key extra_value ...]` — atualiza estado + timestamps + EXPIRE 604800 quando finished
  - `get_state <job_id>` — `HGETALL` parsed via jq → JSON
  - `idem_check <key> <args_hash>` — `SET nc:idem:<key> <job_id>:<args_hash> NX EX 86400`; retorna `new|same|conflict|invalid`
  - `idem_lookup <key>` — `GET nc:idem:<key>` parsed → `<job_id> <args_hash>`
  - `dequeue` — `BRPOP nc:jobs:queue 0` (block infinito); retorna job_id ou vazio se SIGTERM
  - `client_lock_acquire <client> [ttl_sec]` — `SET nc:client_lock:<client> <pid> NX EX ${ttl_sec:-5}`
  - `client_lock_release <client>` — `DEL nc:client_lock:<client>` (com Lua check pid para evitar liberar lock alheio)
  - `client_lock_renew <client>` — `EXPIRE nc:client_lock:<client> 5`
  - `worker_lock_acquire <pid>` — `SET nc:worker:lock <pid> NX EX 60`
  - `worker_lock_renew <pid>` — Lua `if GET == pid then EXPIRE 60 else return error`
  - `worker_status` — retorna JSON com queue_depth, current_job, jobs_today, last_failure
  - `job_list <state> <client> <cmd> <limit> <offset|after>` — SCAN MATCH `nc:jobs:*`; filtra por hash field; paginacao por offset OU after (cursor-based)
- **Decisoes**: dbindex 16 (CONTRACTS §6.1, ARCH-001). Prefixo `nc:` em tudo. Lua scripts para operacoes atomicas (release com check de pid). `redis-cli --no-raw` para evitar parse ambíguo.
- **Edge cases**:
  - `idem_check` com chave existente + mesmo args_hash → `same` (retornar job_id antigo)
  - `idem_check` com chave existente + hash diferente → `conflict`
  - Worker reinicia: `worker_lock_acquire` falha pois lock antigo nao expirou; aceitar (systemd ja garante 1 instancia via `Restart=on-failure` apenas, lock e defesa em profundidade)
  - `dequeue` recebe SIGTERM durante BRPOP → trapped no worker.sh, mas job_queue.sh em si nao precisa tratar (caller decide)
  - `job_list` com 1000+ jobs → SCAN COUNT 1000 + jq filter; **nunca** usar `KEYS nc:jobs:*` (bloqueia Redis)
  - Senhas em hash_value → caller deve sanitizar ANTES de chamar enqueue (defesa em profundidade: enqueue nao filtra; sanitizacao acontece em manage-cli)
- **Anti-patterns**:
  - **Nunca** `KEYS nc:jobs:*` — usar `SCAN MATCH nc:jobs:* COUNT 1000`
  - Nao montar comandos redis via string-concat com argumentos do usuario — usar redis-cli argv array
  - Nao confiar em ordem de retorno de `HGETALL` em multiplas chamadas; parsear sempre via jq
- **Validacoes**: `enqueue` valida que job_id e UUID v4 antes de tocar Redis (chama `is_valid_uuid_v4`).
- **Cenarios de teste** (Budget: 14 testes integration):
  - enqueue + get_state retorna estado completo
  - set_state running → success: timestamps populados; EXPIRE setado
  - idem_check primeira chamada: `new`; segunda mesma: `same`; segunda diferente: `conflict`
  - dequeue retorna job_id em ordem FIFO (LPUSH + BRPOP)
  - client_lock_acquire 2x mesmo cliente → segundo falha
  - worker_lock_renew com pid errado → retorna erro (Lua script garante)
  - worker_status com fila vazia: queue_depth=0
  - worker_status com 3 jobs: queue_depth=3
  - job_list filtrado por client="acme": retorna so jobs de acme
  - job_list paginacao --limit=2 --offset=0 vs --limit=2 --offset=2
  - SCAN com 100 jobs: retorna todos sem usar KEYS (validar via MONITOR no fixture)
  - sanitizacao: hash_value com `MYSQL_PASSWORD=abc` chega cru no Redis (caller deve sanitizar — testar comportamento documentado)
  - get_state job inexistente → JSON vazio `{}`
  - idem com key invalida (nao UUID) → exit 5
- **Budget**: 14 testes integration
- **References**:
  - `docs/CONTRACTS.md §6.1, §6.2, §6.3` (Redis schema canonico)
  - `docs/ARCHITECTURE.md §8.3` (transicoes de estado)
- **Patterns**:
  - `~/.cursor/skills/capabilities/service-composition/references/orchestration-patterns.md` (Lua scripts atomicos)
- **Criterio de aceite**:
  - `bats tests/integration/test_job_queue.bats` retorna 0 com 14 testes
  - ShellCheck warning-clean
  - Nenhum `KEYS` no codigo (verificar via `grep -nE "redis-cli .*KEYS" scripts/lib/job_queue.sh` retornar vazio)
- **executor_prompt**: |
    Criar `scripts/lib/job_queue.sh` com 13 funcoes wrappers sobre redis-cli para a fila de jobs e locks.

    Convencao de chamadas redis-cli:
    ```
    _redis() { redis-cli -h "${REDIS_HOST:-shared-redis}" -p "${REDIS_PORT:-6379}" \
      -a "${REDIS_PASSWORD:-}" -n "${WORKER_REDIS_DB:-16}" "$@"; }
    ```

    Funcoes (assinatura, retorno):
    - enqueue <job_id> <k1> <v1> [<k2> <v2> ...] — HSET nc:jobs:<id> + LPUSH nc:jobs:queue
    - set_state <job_id> <new_state> [<k> <v> ...] — HSET + EXPIRE 604800 se finished
    - get_state <job_id> — HGETALL + jq → JSON 1 linha (vazio = `{}`)
    - idem_check <key> <args_hash> <job_id> — SET nc:idem:<key> "<jid>:<hash>" NX EX 86400; retorna palavra: new|same|conflict
    - idem_lookup <key> — GET; sai com 1 se vazio
    - dequeue — BRPOP nc:jobs:queue 0 (bloqueante); imprime job_id
    - client_lock_acquire <client> [ttl] — SET nc:client_lock:<c> <pid> NX EX ${ttl:-5}
    - client_lock_release <client> — Lua: if GET==my_pid then DEL else nop
    - client_lock_renew <client> — EXPIRE nc:client_lock:<c> 5
    - worker_lock_acquire <pid> — SET nc:worker:lock <pid> NX EX 60
    - worker_lock_renew <pid> — Lua check
    - worker_status — JSON com queue_depth (LLEN nc:jobs:queue), current_job (GET nc:worker:current), jobs_today (GET nc:worker:metrics:jobs_today), last_failure (SCAN+filtro)
    - job_list [--state=...] [--client=...] [--cmd=...] [--limit=N] [--offset=N|--after=<jid>] — SCAN MATCH nc:jobs:* COUNT 1000 + jq filter

    Para client_lock_release usar EVAL Lua:
    ```
    local v = redis.call('GET', KEYS[1])
    if v == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end
    ```

    Validacoes:
    - enqueue: `is_valid_uuid_v4 "$job_id"` antes de tocar Redis (source `lib/validators.sh`).
    - idem_check: `is_valid_uuid_v4 "$key"` antes.

    NUNCA usar KEYS nc:* — sempre SCAN MATCH ... COUNT 1000.
    NUNCA usar string-concat para argumentos do usuario.

    Testes integration (14) em `tests/integration/test_job_queue.bats`:
    - Setup carrega `tests/helpers/redis_fixture.bash` e starts redis 7-alpine.
    - Cada teste roda em estado limpo (FLUSHDB no setup).
    - Cobrir cenarios da nota tecnica.

    Ao final: `bats tests/integration/test_job_queue.bats` retorna 0; shellcheck warning-clean; `grep -nE "redis-cli .*KEYS " scripts/lib/job_queue.sh | grep -v "MATCH"` retorna vazio.
</details>

<details>
<summary>1.8 — Implementar scripts/lib/job_runner.sh + testes</summary>

- **Arquivo(s)**:
  - `scripts/lib/job_runner.sh`
  - `tests/unit/test_job_runner.bats`
- **Abordagem**: wrapper que executa `nextcloud-manage <argv> --json --no-async-pickup` com timeout, captura stdout/stderr/exit_code, log dual (arquivo + stdout NDJSON via `output_json::log_event`).
- **Funcoes a criar**:
  - `run_job <job_id> <log_path> <argv...>` — exec com timeout `WORKER_JOB_TIMEOUT_SEC` (default 1800); stdout+stderr → log_path + tee para journald via printf
  - `sanitize_log <log_path>` — aplica `sanitize_secrets` no arquivo de log apos execucao (in-place via temp file)
- **Decisoes**: usar `timeout --signal=TERM --kill-after=30 "$WORKER_JOB_TIMEOUT_SEC" -- nextcloud-manage "${argv[@]}" --json --no-async-pickup`. Capturar exit_code via `$?`. Trap `EXIT` no caller (worker.sh) garante sanitize_log mesmo em SIGKILL parcial.
- **Edge cases**:
  - Comando demora >timeout → `timeout` envia TERM; processo nao responde → kill-after 30s envia KILL; exit_code=124 ou 137; job marcado `failed` com `error_msg=timeout`
  - Disco cheio durante log → exit code do `tee` !=0; capturar via `set -o pipefail` e marcar falha com aviso
  - Argv com aspas internas → invocar via array `"${argv[@]}"` (nunca string `"$argv"`)
  - log_path nao existe → criar via `install -m 0640 -o root -g adm /dev/null "$log_path"`
- **Anti-patterns**:
  - **Nunca** `bash -c "$cmd"` — vulneravel a injection. **Sempre** array argv.
  - Nao deixar log com permissao 0644 — exigir 0640 root:adm (ARCHITECTURE §7.1)
  - Nao retornar antes de sanitizar log — racing window onde dump cru fica visivel
- **Validacoes**: argv[0] DEVE ser `nextcloud-manage` (defesa em profundidade; worker tambem valida).
- **Cenarios de teste** (Budget: 8 testes):
  - run_job comando rapido (sleep 0): exit 0, log criado, log permissao 0640
  - run_job comando que falha (false): exit 1
  - run_job comando que timeout (sleep 60 com WORKER_JOB_TIMEOUT_SEC=1): exit 124
  - sanitize_log com `MYSQL_PASSWORD=abc` no log → substituido por `***`
  - run_job com argv com aspas: argv preservado
  - run_job com log_path em diretorio inexistente: cria diretorio (ou exit erro claro)
  - sanitize_log idempotente
  - run_job invocacao com argv[0] != nextcloud-manage: exit 5 (security)
- **Budget**: 8 testes
- **References**:
  - `docs/ARCHITECTURE.md §10 manage-cli decisoes` (run_runner)
- **Criterio de aceite**:
  - `bats tests/unit/test_job_runner.bats` 0 com 8 testes
  - shellcheck warning-clean
  - Mocks `nextcloud-manage` via `tests/helpers/setup.bash::mock_docker` ou wrapper similar
- **executor_prompt**: |
    Criar `scripts/lib/job_runner.sh` com 2 funcoes: run_job e sanitize_log.

    run_job assinatura:
    ```
    run_job <job_id> <log_path> <argv0> [<argv1> ...]
    ```
    Comportamento:
    1. Validar argv0 == "nextcloud-manage" (security; exit 5 senao).
    2. Criar log_path com `install -m 0640 -o root -g adm /dev/null "$log_path"` (aceitar EACCES no test mode).
    3. Executar via `timeout --signal=TERM --kill-after=30 "${WORKER_JOB_TIMEOUT_SEC:-1800}" -- "${argv[@]}" --json --no-async-pickup` com stdout+stderr → log_path (`>>"$log_path" 2>&1`).
    4. Capturar exit_code via `$?`.
    5. Chamar sanitize_log "$log_path".
    6. Imprimir exit_code via stdout (caller le).

    sanitize_log assinatura:
    ```
    sanitize_log <log_path>
    ```
    Comportamento:
    1. Criar temp file (`mktemp`).
    2. Aplicar regex sed sobre log_path → temp file.
    3. `mv` temp file → log_path (preserva inode? testar; aceitavel quebrar inode em troca de atomicity).
    4. Regex: `s/(MYSQL_PASSWORD|NEXTCLOUD_ADMIN_PASSWORD|REDIS_PASSWORD|SIGNALING_SECRET|RECORDING_SECRET|TURN_SECRET|--password|--password-from-env)=\S+/\1=***/g`.

    Source:
    ```
    source scripts/lib/output_json.sh
    source scripts/lib/validators.sh
    ```

    Testes (8) em `tests/unit/test_job_runner.bats`:
    - Mock `nextcloud-manage` via wrapper script em `tests/fixtures/mock-nextcloud-manage` que aceita argv e respeita exit code passado via NCM_EXIT env.
    - Cenarios da nota tecnica.

    NUNCA usar `bash -c "$cmd"`.
    Validar argv0 antes de tocar filesystem.
</details>

<details>
<summary>1.9 — Implementar scripts/lib/ssh_audit.sh + testes</summary>

- **Arquivo(s)**:
  - `scripts/lib/ssh_audit.sh`
  - `tests/unit/test_ssh_audit.bats`
- **Abordagem**: wrappers para emit eventos NDJSON em journald via `logger -t <tag> -p <facility>.<level>`. Sem dependencia de daemon — `logger` e parte do util-linux.
- **Funcoes a criar**:
  - `audit_ssh <event> <decision> [k1 v1 ...]` — tag `ncsaas-api-ssh`, prioridade `auth.notice|auth.warning`; campos: ts, event, decision (accepted|rejected), key_id, client_ip, command, argv (sanitizado)
  - `audit_worker <event> <level> <job_id> [k1 v1 ...]` — tag `nextcloud-saas-worker`, daemon.notice/info/warning
  - `audit_occ <client> <subcmd> <decision> [exit_code] [duration_ms]` — tag `nextcloud-saas-occ-exec` (Feature P)
- **Decisoes**: facility `auth.*` para SSH (audit trail compliant); `daemon.*` para worker/occ. Sempre NDJSON 1 linha. Sanitizar TODO payload via `sanitize_secrets` antes de emit (defesa em profundidade).
- **Edge cases**:
  - `client_ip` vazio (caso de SSH local sem $SSH_CONNECTION) → registrar como `"local"`
  - `key_id` desconhecido → `"unknown"` (compatibilidade com sshd antigos sem `SSH_USER_AUTH`)
  - logger indisponivel → fallback para `printf '%s\n' "$line" >> /var/log/ncsaas-fallback.log` (warning no stderr)
  - argv com 100+ chars → truncar em 500 chars com sufixo `...`
- **Anti-patterns**:
  - Nao logar secrets via key/value — sanitizar **payload** antes
  - Nao depender de daemon journald rodando — use logger (aciona syslog API; tolera journald off)
- **Validacoes**: event nome em allowlist (invoke, accept, reject, run_start, run_finish, callback_attempt, callback_failed, occ_exec_attempt, occ_exec_complete).
- **Cenarios de teste** (Budget: 6 testes):
  - audit_ssh accept: 1 linha NDJSON com tag correta + ts + decision=accepted
  - audit_ssh reject por metachar: decision=rejected + reason=metachar
  - audit_worker run_start: tag worker + level=notice + job_id presente
  - audit_occ allowed: tag occ-exec + decision=accept + subcmd
  - sanitize_secrets aplicado em command field (mock argv com `--password=secret`)
  - logger indisponivel (mock via PATH) → fallback file usado
- **Budget**: 6 testes
- **References**:
  - `docs/ARCHITECTURE.md §9 (Observabilidade)` + `§7.2 (Fronteiras de Confianca)`
- **Criterio de aceite**:
  - `bats tests/unit/test_ssh_audit.bats` 0 com 6 testes
  - shellcheck warning-clean
- **executor_prompt**: |
    Criar `scripts/lib/ssh_audit.sh` com 3 funcoes audit_ssh, audit_worker, audit_occ que emitem NDJSON em journald via logger(1).

    Convencao:
    ```
    _emit() {
      local tag="$1" facility="$2" level="$3" payload="$4"
      payload=$(sanitize_secrets <<< "$payload")
      logger -t "$tag" -p "${facility}.${level}" -- "$payload" 2>/dev/null \
        || printf '%s [%s.%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$level" "$payload" >> /var/log/ncsaas-fallback.log 2>/dev/null \
        || true
    }
    ```

    audit_ssh: tag=ncsaas-api-ssh, facility=auth, level=notice (accept) ou warning (reject).
    audit_worker: tag=nextcloud-saas-worker, facility=daemon.
    audit_occ: tag=nextcloud-saas-occ-exec, facility=daemon.

    Cada funcao monta payload via `emit_json` (de output_json.sh) com keys obrigatorias (ts, event, decision_or_level) + extras passados como argumentos.

    Validar event em allowlist (case in invoke|accept|reject|run_start|run_finish|callback_attempt|callback_failed|occ_exec_attempt|occ_exec_complete).

    Truncar argv > 500 chars com sufixo "...".

    Testes (6) em `tests/unit/test_ssh_audit.bats`:
    - Mock logger via wrapper em PATH (`tests/fixtures/mock-logger`) que captura args em arquivo temp.
    - Validar formato NDJSON (1 linha; jq -e .).

    Source: `output_json.sh`, `validators.sh`.
</details>

<details>
<summary>1.10 — Refatorar scripts/manage.sh para invocar lib/*.sh (sem mudar comportamento)</summary>

- **Arquivo(s)**:
  - `scripts/manage.sh` (reescrita preservando 100% do comportamento legado)
  - `tests/integration/test_manage_legacy.bats` (smoke regressivo)
- **Abordagem**: top-down — `manage.sh` vira dispatcher fino que (a) faz `source` das libs, (b) parseia argv legado posicional `<cliente> <dom|_> <cmd>`, (c) chama `cmd_<verb>` (funcoes que ja existem). Nao adicionar `--async`/namespaces ainda — apenas reorganizar para caber as funcoes em lib/. Mover funcoes utilitarias (parse_args originais, validate_dns, generate_password, etc) para lib/legacy_helpers.sh **se elas continuarem em uso pelos cmd_* legados**. Para cmd_* nao tocar.
- **Decisoes**:
  - `manage.sh` mantem ~300 linhas (so dispatcher + cmd_*)
  - Funcoes de geracao de senha vao para `lib/legacy_helpers.sh` (a refatorar nas sprints seguintes para usar `output_json::sanitize_secrets`)
  - `parse_global_flags` (de validators.sh) e chamado **antes** do parse posicional legado; flags globais novas (--json, --dry-run) sao **aceitas mas nao executadas ainda** em D1 (so registradas em PARSED_FLAGS)
  - Source guards (`[ "${VALIDATORS_SH_SOURCED:-0}" = "1" ] && return`) em todas as libs
- **Edge cases**:
  - Comando legado `manage.sh acme nextcloud.acme.com.br create` continua funcionando (sem aceitar `--async` — async-only e Sprint D2)
  - Comando legado `manage.sh acme _ status` continua funcionando
  - F01-F10 do REQUIREMENTS §4.1 todas em smoke
- **Anti-patterns**:
  - Nao mexer em `cmd_create`/`cmd_remove`/etc nesta task — aposenta D2
  - Nao adicionar nova feature aqui — refactor pulhista
  - Nao quebrar idempotencia atual de `cmd_status` (read-only ja era idempotente; preservar)
- **Validacoes**: smoke test passa em ambiente local com docker compose mockado.
- **Cenarios de teste** (Budget: 10 testes):
  - manage.sh sem args → help
  - manage.sh acme nextcloud.acme.com.br status → status output (mock docker compose)
  - manage.sh acme _ credentials → credentials output
  - manage.sh list → lista vazia (sem clientes em fixture)
  - manage.sh acme _ stop / start → docker compose calls corretos
  - manage.sh com `--dry-run` → flag e parseada (PARSED_FLAGS[dry_run]=1) mas comportamento atual segue
  - manage.sh com `--json` → flag parseada
  - manage.sh shellcheck warning-clean (auto-test)
  - manage.sh source-able sem argv (para tests carregarem funcoes)
  - manage.sh exit code preservado (cmd_status ok = 0; falha = !=0)
- **Budget**: 10 testes integration
- **References**:
  - `docs/ARCHITECTURE.md §3 (estrutura de pastas)` — alvo
  - Codigo atual de `scripts/manage.sh` (1051 LOC) — preservar
- **Patterns**:
  - `~/.cursor/skills/capabilities/service-composition/references/decomposition-patterns.md` (refactor em modulos preservando interface)
- **Criterio de aceite**:
  - smoke test (10) passa em CI bats.yml integration job
  - `manage.sh` reduzido para ≤500 LOC (sem contar comentarios)
  - `lib/*.sh` somam ≤800 LOC com codigo extraido
  - Diff comportamental: `nextcloud-manage list` antes vs depois retorna identico (testar via fixture com 0/1/3 clientes)
- **executor_prompt**: |
    Refatorar `scripts/manage.sh` (atualmente 1.051 LOC) para virar dispatcher fino que invoca `lib/*.sh` (criados em D1.5..D1.9) + `lib/legacy_helpers.sh` (a criar nesta task com funcoes utilitarias migradas de manage.sh). NAO adicionar novas features; apenas extrair codigo.

    Estrategia top-down:
    1. Identificar funcoes utilitarias em `manage.sh` que NAO sao `cmd_*` — moves para `lib/legacy_helpers.sh`. Candidatas tipicas: validate_dns, generate_password, parse_args originais, helpers de docker compose detection.
    2. NAO mover `cmd_create`, `cmd_remove`, `cmd_backup`, `cmd_restore`, `cmd_update`, `cmd_stop`, `cmd_start`, `cmd_status`, `cmd_list`, `cmd_credentials` — eles ficam em `manage.sh` por ora; serao tocados em D2/D3.
    3. No topo de `manage.sh` adicionar:
    ```
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/lib/validators.sh"
    source "$SCRIPT_DIR/lib/output_json.sh"
    source "$SCRIPT_DIR/lib/job_queue.sh"   # ainda nao usada em cmd_* legados
    source "$SCRIPT_DIR/lib/job_runner.sh"  # ainda nao usada
    source "$SCRIPT_DIR/lib/ssh_audit.sh"   # ainda nao usada
    source "$SCRIPT_DIR/lib/legacy_helpers.sh"
    ```
    4. Chamar `parse_global_flags "$@"` antes do parse posicional. Resultado em PARSED_FLAGS[*]. Em D1, ignorar (so persistir o parse).
    5. Manter o parse posicional legado: argv[1]=cliente, argv[2]=dom_or_underscore, argv[3]=cmd.
    6. Manter dispatch: `case "$cmd" in create) cmd_create "$cliente" "$dom" ;; ...esac`.
    7. Header `set -euo pipefail` no topo (pode ja existir; preservar).
    8. Source guards em cada lib (`[ "${MODULE_SH_SOURCED:-}" = "1" ] && return; readonly MODULE_SH_SOURCED=1`).

    Smoke test em `tests/integration/test_manage_legacy.bats` (10 testes):
    - Cobrir cenarios da nota tecnica.
    - Mock docker via `tests/fixtures/mock-docker` que retorna stdout pre-canned conforme env vars.
    - Mock redis-cli via `tests/fixtures/mock-redis-cli` (em D1, lib/job_queue nao e usada por cmd_* legados, mas o source nao pode quebrar).

    NUNCA mexer no comportamento de `cmd_*` nesta task.
    SEMPRE preservar o exit code original.

    Validar com diff funcional: tests/integration/test_manage_legacy.bats antes da refactor (criar baseline com manage.sh ATUAL via git stash) e depois — devem dar exatamente o mesmo output em todos os cenarios.

    Ao final: bats verde + shellcheck warning-clean + manage.sh ≤500 LOC + lib/*.sh ≤800 LOC totais.
</details>

---

## Sprint D2 — Async Core (Queue + Worker + SSH + Observabilidade)
> Categoria: D
> Gate: API REST consegue invocar `ssh ncsaas-api@host nextcloud-manage acme nextcloud.acme.com.br create --async --json --idempotency-key=<uuid> --callback=https://api.example/hook`, recebe `EnqueuedJob` em <2s, worker daemon (systemd) executa `cmd_create` real, callback HMAC dispara, e idempotency-key reusado em 24h retorna mesmo `job_id`. `manage.sh worker status --json` e `manage.sh job <id> status --json` funcionam. AOF habilitado no shared-redis.
> review: senior+qa

| Status | Tamanho | Tarefa | Skill/Command | Depende de |
|--------|---------|--------|---------------|------------|
| [x] | M | 2.1 — manage-cli parte 2: parser hibrido (legado posicional + namespaces user/group/apps/occ-exec), dispatch sync vs enqueue, --json/--dry-run/--async/--idempotency-key/--callback/--confirm/--payload-stdin/--strict | `bash` + `bats` | D1.10 |
| [x] | M | 2.2 — Idempotency em `lib/job_queue.sh::idem_check` integrado ao manage-cli (consulta antes de enqueue; conflito = exit 3) | `bash` + `bats` | 2.1 |
| [x] | M | 2.3 — `scripts/worker.sh` daemon: BRPOP loop, set_state running, exec via job_runner, sanitize log, callback HMAC com retry exponencial 5s/30s/300s, lock duplo flock+Redis, watchdog systemd notify | `bash` + `bats` | 2.1, D1.8 |
| [x] | M | 2.4 — Instalar systemd units em deploy-server.sh: nextcloud-saas-worker.service + .env + jobs-gc.timer/.service; habilitar AOF em shared-redis (setup-shared.sh) — via setup-worker.sh (deploy-server.sh bloqueado por hook) | `bash` + `systemd` | 2.3 |
| [x] | M | 2.5 — ssh-gateway: criar usuario ncsaas-api + sshd_config.d/50-ncsaas-api.conf + sudoers/ncsaas-api + binario `/usr/local/bin/ncsaas-api-shim` em deploy-server.sh — via setup-ssh-gateway.sh | `bash` + `sshd` | 2.1 |
| [x] | M | 2.6 — Wiring observability: log_event NDJSON em manage-cli (enqueue), worker (run_start/finish, callback_attempt) e shim (invoke/accept/reject); journald.conf.d/50-nextcloud-saas.conf (SystemMaxUse=2G, MaxRetentionSec=30day) | `bash` + `journald` | 2.3, 2.5 |
| [x] | P | 2.7 — `manage.sh worker status [--json]` lendo nc:worker:current + LLEN nc:jobs:queue + jobs_today | `bash` | 2.3 |
| [x] | M | 2.8 — `manage.sh job <id> {status\|logs\|cancel}` + `manage.sh job list [--state=...] [--client=...] [--cmd=...] [--limit=N] [--offset=N\|--after=<id>]` (Q-1, Q-2, Q-4) | `bash` + `bats` | 2.1 |
| [x] | P | 2.9 — `manage.sh worker stats [--by-cmd] [--by-client] [--json]` (Q-3 — counts agregados via SCAN MATCH; v12.1+ pode promover para counters incrementais) | `bash` | 2.7 |
| [x] | M | 2.10 — Tests integration end-to-end async: dispatch + enqueue + idempotency + worker pickup + callback HMAC validation (mock callback receiver) | `bats` | 2.1, 2.3 |
| [x] | P | 2.11 — Atualizar `README.md` + `docs/ADMINISTRATION.md` com secao "Modo assincrono e API REST consumidora" | `bash` (manual edit) | 2.1..2.10 |

**Notas tecnicas (tarefas M):**

<details>
<summary>2.1 — manage-cli parte 2 (parser hibrido + dispatch async) [critica: true]</summary>

### Mini Design Doc

- **Escopo**: Adicionar suporte completo a `--async`, `--json`, `--dry-run`, `--idempotency-key`, `--callback`, `--confirm`, `--payload-stdin`, `--strict`, `--no-async-pickup` em `manage.sh`. Adicionar parser para namespaces hierarquicos: token-2 != legado `<dom|_>` e palavra reservada (`user`, `group`, `apps`, `occ-exec`) → dispatch para handler de namespace.
- **Componentes**: `manage.sh` (dispatcher), `lib/validators.sh::parse_global_flags`, novos handlers stub `cmd_user_*`, `cmd_group_*`, `cmd_apps_*`, `cmd_occ_exec` (em D2 retornam `not_implemented_yet exit 99`; implementacao em D3/D4); enqueue path em `lib/job_queue.sh::enqueue`.
- **Riscos**: (R-1) Parser ambiguo entre legacy `<cliente> <dom> create` e namespace `<cliente> user create <username>` — mitigar via lookup do token-2 contra palavra reservada **antes** de tratar como FQDN. (R-2) Quebrar comportamento legado de F01-F10 — mitigar com smoke test (regressao do D1.10). (R-3) Senha em argv em `user create` legado se API mandar — mitigar com warning no stderr + exit 5 quando `--password=` aparecer; obrigar `--payload-stdin`.

### Quality Brief (Sprint D2)

**Quality Constraints (5)**:
1. Parser de token-2 valida contra `RESERVED_NAMESPACES=(user group apps occ-exec)` ANTES de tratar como FQDN. Se match → namespace path. Se nao → legacy `<dom|_>` path.
2. Toda flag de seguranca (`--callback`, `--idempotency-key`) e validada via funcoes de `lib/validators.sh` ANTES de qualquer tocar Redis.
3. `--callback` rejeita IPs RFC1918 (defesa em profundidade SSRF) — `is_valid_https_url`.
4. `--password=*` em argv (legado ou novo) → exit 5 (`password_in_argv_forbidden`); senha **deve** vir via `--payload-stdin`.
5. Sanitizacao de senhas em journald NDJSON e em log de job acontece NA ORIGEM (em manage-cli, antes do dispatch para worker).

**Technical Advisory (3)**:
- Ao parsear `--idempotency-key=<value>` E `--idempotency-key <value>`, normalize para um unico path; rejeitar `=` em booleanas (`--async=true`).
- Para namespaces, usar funcao despachadora `dispatch_namespace_cmd <client> <namespace> <verb> <argv...>` para evitar duplicacao em cada cmd_<ns>_*.
- Para enqueue path: cmd handler nao executa nada — apenas constroi o `args_json` (jq array de strings) e chama `lib/job_queue.sh::enqueue`. Trabalho real fica no worker.

- **Arquivo(s)**:
  - `scripts/manage.sh` (extensao do dispatcher)
  - `scripts/lib/validators.sh` (extensao de `parse_global_flags`, RESERVED_NAMESPACES)
  - `scripts/lib/dispatch.sh` (NOVO — `dispatch_async_cmd` e `dispatch_sync_cmd`)
- **Abordagem**:
  - Pos-parse de global flags via `parse_global_flags`, separar argv positional (sem flags) em `POS_ARGS`.
  - Detectar token-2 (POS_ARGS[1]):
    - Em `RESERVED_NAMESPACES` → `dispatch_namespace_cmd "${POS_ARGS[0]}" "${POS_ARGS[1]}" "${POS_ARGS[@]:2}"`.
    - Senao → legacy path com `<cliente> <dom|_> <cmd>`.
  - dispatch_namespace despacha para `cmd_<ns>_<verb>` (user-create → cmd_user_create); em D2 retorna `emit_error not_implemented_yet ...; exit 99` (handlers reais em D3).
  - Sync vs async:
    - Comando esta em ASYNC_ALLOWED **e** PARSED_FLAGS[async]=1 → enqueue path.
    - Senao se PARSED_FLAGS[async]=1 → exit 5 (`async_not_supported`).
    - Senao → sync path (cmd_<verb> direto).
  - enqueue path:
    1. `is_valid_uuid_v4 "${PARSED_FLAGS[idempotency_key]}"` se setado.
    2. Se `--idempotency-key`, computar `args_hash` (sha256 de `<cmd>\n<client>\n<sorted_args_sem_metadados>`) e chamar `idem_check`. `same` → retornar EnqueuedJob com job_id antigo, exit 0. `conflict` → emit_error idempotency_conflict, exit 3.
    3. Gerar `job_id=$(uuidgen)`.
    4. Construir `args_json` via `jq -nc --argjson a '...' '$a'` (array de strings dos POS_ARGS).
    5. `enqueue "$job_id" schema_version "1" state "queued" cmd "$cmd" client "$client" args_json "$args_json" args_hash "$args_hash" idempotency_key "${PARSED_FLAGS[idempotency_key]:-}" callback_url "${PARSED_FLAGS[callback]:-}" caller_key_id "${SSH_USER_AUTH:-local}" caller_uid "$(id -u)" client_ip "${SSH_CONNECTION%% *}" queued_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" log_path "/opt/nextcloud-customers/jobs/${job_id}.log"`.
    6. emit_json job_id "$job_id" state "queued" queued_at "$ts".
    7. exit 0.
  - `--dry-run --async`: pular passos 4-6, retornar JSON descritivo das mudancas que seriam feitas, exit 0, sem tocar Redis.
- **Decisoes**:
  - `args_hash` = `sha256sum` da concatenacao `<cmd>\n<client>\n<sorted_remaining_flags_e_args>` (sem `--idempotency-key` nem `--callback`).
  - `--callback` sem `--async` → exit 5 (`callback_requires_async`) — validado em `parse_global_flags`.
  - `--no-async-pickup` (interno do worker) → impede recursao se vier setado em manage-cli direto; aceitar apenas em path sync.
- **Edge cases**:
  - Cliente passa `--async --json --idempotency-key=<uuid>` em comando sync (`status`) → exit 5 (`async_not_supported_for_cmd`)
  - Cliente passa `cmd=create` mas em instancia ja existente com mesmos args → idempotente exit 0 (logica de cmd_create — D2.1 nao muda; mas async com `--idempotency-key` e tratado antes pelo manage-cli)
  - Cliente passa `--callback=http://...` (HTTP nao HTTPS) → exit 5 (validador HTTPS only)
  - Cliente passa `--callback=https://192.168.1.1/hook` → exit 5 (validador SSRF)
  - Token-2 e palavra valida ambiguamente reservada (e.g. cliente legado chamado `apps`) → impossivel pois `is_valid_client_name` aceita `[a-z0-9-]{1,64}` mas `apps` e palavra reservada — documentar conflict; ja que `apps` nao casa pattern de FQDN, dispatch_namespace ganha
  - argv com `--password=secret123` em `user create` (legado) → exit 5; mensagem orienta `--payload-stdin`
- **Anti-patterns**:
  - Concatenar args para hash via `"$@"` sem normalizar — usar `printf '%s\n' "${POS_ARGS[@]}" | sort | sha256sum`
  - Usar `eval` em qualquer parse — sempre array argv
  - Setar PARSED_FLAGS antes de validar — validar **e** popular atomico
- **Cenarios de teste** (Budget: 16 testes):
  - dispatch legado: `manage.sh acme nextcloud.acme.com.br status` → cmd_status invocado
  - dispatch namespace: `manage.sh acme user create john --display-name=John ...` (sem --async) → exit 5 async_required (user-create esta em ASYNC_ALLOWED)
  - dispatch namespace async: `manage.sh acme user create john --async --json --payload-stdin <<<'{"password":"x"}'` → enqueue ok, EnqueuedJob retornado
  - parse_global_flags: `--idempotency-key=550e8400-e29b-41d4-a716-446655440000` → setado
  - parse_global_flags: `--idempotency-key=invalid` → exit 5
  - idem_check 1a chamada: enqueue cria job; 2a chamada mesmos args: retorna mesmo job_id; 3a chamada args diferentes: exit 3
  - --callback=http://... → exit 5
  - --callback=https://192.168.1.1 → exit 5
  - --callback sem --async → exit 5 callback_requires_async
  - --dry-run --async create → JSON descritivo sem tocar Redis (validar via FLUSHDB depois → 0 keys)
  - --password=secret em argv → exit 5
  - args_hash determinismo: mesmos args ordem diferente → mesmo hash
  - args_hash sensibilidade: 1 char diferente → hash diferente
  - cmd async sem --async → sync path (cmd_create chamado direto em sync — comportamento legacy preservado)
  - status com --async → exit 5 async_not_supported
  - args_json no Redis: HGET nc:jobs:<id> args_json → array JSON valido
- **Budget**: 16 testes
- **References**:
  - `docs/CONTRACTS.md §3.1 (CLI grammar)`, `§3.2 (flags globais)`, `§3.4 (regex de cliente)`, `§3.6 (exit codes)`, `§4.1-4.7 (JSON schemas)`
  - `docs/ARCHITECTURE.md §10 manage-cli`
- **Patterns**:
  - `~/.cursor/skills/capabilities/service-composition/references/orchestration-patterns.md` (dispatcher pattern)
  - `~/.cursor/skills/capabilities/service-composition/references/decomposition-patterns.md`
- **Criterio de aceite**:
  - bats integration verde com 16 testes
  - shellcheck warning-clean
  - smoke regressivo de D1.10 continua passando (legacy preservado)
  - performance: enqueue path completo (parse + idem + enqueue + emit) <500ms em hardware do CI
- **executor_prompt**: |
    ### Quality Brief (Sprint D2)

    **Quality Constraints**:
    1. Parser de token-2 valida contra RESERVED_NAMESPACES=(user group apps occ-exec) ANTES de tratar como FQDN.
    2. Toda flag de seguranca validada via lib/validators.sh ANTES de tocar Redis.
    3. --callback rejeita IPs RFC1918.
    4. --password=* em argv → exit 5; obrigar --payload-stdin.
    5. Sanitizacao de senhas acontece NA ORIGEM em manage-cli antes do enqueue.

    **Technical Advisory**:
    - Normalizar `--key=value` e `--key value` em parse_global_flags.
    - dispatch_namespace_cmd para evitar duplicacao em cmd_<ns>_*.
    - enqueue path: handler so constroi args_json e chama job_queue::enqueue; trabalho real no worker.

    ---

    Estender `scripts/manage.sh` (refatorado em D1.10) com:

    1. Em `lib/validators.sh`: adicionar `RESERVED_NAMESPACES=(user group apps occ-exec)`.

    2. Estender `parse_global_flags` para suportar todas as flags (--async, --json, --dry-run, --idempotency-key, --callback, --confirm, --payload-stdin, --strict, --no-async-pickup, --staging-id). Validar:
       - --idempotency-key: is_valid_uuid_v4
       - --callback: is_valid_https_url
       - --callback sem --async → exit 5 callback_requires_async
       - --password= em qualquer parte do argv → exit 5 password_in_argv_forbidden

    3. Criar `scripts/lib/dispatch.sh` com:
       - `dispatch_namespace_cmd <client> <namespace> <verb> <argv...>` — case namespace in user|group|apps|occ-exec) call cmd_<ns>_<verb>;; *) exit 5;; esac
       - Em D2, cmd_user_create / cmd_user_remove / etc retornam `emit_error not_implemented_yet "..."; exit 99` — implementacao real em D3.
       - cmd_occ_exec retorna not_implemented (D4).

    4. Em `manage.sh`, no main:
    ```
    parse_global_flags "$@"
    set -- "${POS_ARGS[@]}"
    client="$1"
    is_valid_client_name "$client" || { emit_error invalid_client; exit 5; }
    token2="${2:-}"
    if [[ " ${RESERVED_NAMESPACES[*]} " == *" $token2 "* ]]; then
      shift
      dispatch_namespace_cmd "$client" "$@"
    else
      # legacy path: client dom_or_underscore cmd ...
      dom="$2"; cmd="$3"; shift 3
      legacy_dispatch "$client" "$dom" "$cmd" "$@"
    fi
    ```

    5. legacy_dispatch verifica:
       - Se cmd em ASYNC_ALLOWED **e** PARSED_FLAGS[async]=1 → enqueue path.
       - Se cmd em ASYNC_ALLOWED e PARSED_FLAGS[async]=0 → cmd_<verb> sync (legacy).
       - Se cmd nao em ASYNC_ALLOWED e PARSED_FLAGS[async]=1 → exit 5 async_not_supported_for_cmd.

    6. enqueue path:
       - Computar args_hash = sha256sum < <(printf '%s\n' "$cmd" "$client" $(printf '%s\n' "${POS_ARGS[@]:2}" | sort)) | cut -d' ' -f1.
       - Se PARSED_FLAGS[idempotency_key]: idem_check "$key" "$args_hash" "$job_id" → new|same|conflict.
       - Se same: emit_json com job_id antigo, exit 0.
       - Se conflict: emit_error idempotency_conflict, exit 3.
       - Senao: job_id=$(uuidgen); enqueue ... (ver lista de campos na nota tecnica).
       - emit_json job_id state queued queued_at; exit 0.

    7. --dry-run --async: descrever mudancas planejadas em JSON; nao tocar Redis.

    Testes (16) em `tests/integration/test_manage_async_dispatch.bats`:
    - Mock redis-cli via fixture (port aleatoria); FLUSHDB no setup.
    - Cobrir cenarios listados.
    - Validar que apos --dry-run nao ha keys no Redis.

    NUNCA usar eval. NUNCA concatenar JSON via echo.
    Smoke regressivo de D1.10 deve continuar passando.

    `critica: true` — Best-of-N: 2 implementadores em paralelo; selecao pelo melhor coverage + menor LOC + zero shellcheck warnings.
</details>

<details>
<summary>2.2 — Idempotency em manage-cli</summary>

- **Arquivo(s)**: integrado em D2.1 (extensao de `manage.sh` enqueue path) + tests em `tests/integration/test_idempotency.bats`
- **Abordagem**: `idem_check` (de `lib/job_queue.sh`) implementa `SET nc:idem:<key> <job_id>:<args_hash> NX EX 86400`. manage-cli chama antes do enqueue.
- **Decisoes**: chave armazena `<job_id>:<args_hash>` separados por `:`. Conflito = 1 caracter de diferenca em args_hash.
- **Edge cases**: TTL expirou em retry agressivo (24h+1s) — tratar como new (aceitavel; raro). Mesma chave + mesmo cmd + cliente diferente → conflict (correto: resource diferente).
- **Anti-patterns**: confiar em `EXISTS` antes de `SET NX` (race condition); usar exclusivamente o retorno do SET NX.
- **Validacoes**: chave deve ser UUID v4.
- **Cenarios de teste** (Budget: 6 testes):
  - 1a chamada: SET NX retorna OK; idem_check retorna `new`
  - 2a chamada mesma chave + mesmo args_hash: SET NX retorna nil; idem_check retorna `same`; manage-cli retorna mesmo job_id
  - 2a chamada mesma chave + args_hash diferente: idem_check retorna `conflict`; manage-cli exit 3
  - TTL configurado em 86400s (validar via TTL nc:idem:<key>)
  - Chave com cliente diferente mas hash identico → comportamento documentado: conflict (chave e dimensao independente)
  - Chave invalida (UUID malformado) → exit 5
- **Budget**: 6 testes
- **References**: `docs/CONTRACTS.md §3.4`, `docs/ARCHITECTURE.md ADR-005`
- **Criterio de aceite**: bats verde + shellcheck warning-clean + cobertura nas tests integration de idem_check
- **executor_prompt**: |
    Implementar idem_check no fluxo de enqueue de manage.sh (parte da D2.1 mas com testes dedicados).

    Em manage.sh enqueue path, antes de uuidgen para job_id:
    ```
    if [[ -n "${PARSED_FLAGS[idempotency_key]:-}" ]]; then
      key="${PARSED_FLAGS[idempotency_key]}"
      candidate_job_id=$(uuidgen)
      result=$(idem_check "$key" "$args_hash" "$candidate_job_id")
      case "$result" in
        new) job_id="$candidate_job_id" ;;
        same)
          # Recuperar job_id antigo e retornar EnqueuedJob com ele
          old=$(idem_lookup "$key")
          job_id="${old%%:*}"
          # Read state do Redis e devolver na resposta
          state=$(get_state "$job_id" | jq -r .state)
          emit_json job_id "$job_id" state "$state" idempotent "@bool:true"
          exit 0
          ;;
        conflict)
          existing=$(idem_lookup "$key")
          emit_error idempotency_conflict "key already used with different args" 0 \
            existing_job_id "${existing%%:*}" existing_args_hash "${existing##*:}"
          exit 3
          ;;
      esac
    else
      job_id=$(uuidgen)
    fi
    ```

    Tests em `tests/integration/test_idempotency.bats`:
    - 6 testes cobrindo cenarios da nota tecnica.
    - Setup: redis fixture limpo + FLUSHDB.
    - Cada teste valida tanto o exit code quanto o conteudo do JSON via `jq`.
</details>

<details>
<summary>2.3 — scripts/worker.sh (daemon) [critica: true]</summary>

### Mini Design Doc

- **Escopo**: Daemon Bash que roda como systemd unit (root), faz BRPOP em `nc:jobs:queue`, executa `nextcloud-manage <argv>` via `lib/job_runner.sh`, atualiza estado em Redis, dispara callback HMAC.
- **Componentes**: `scripts/worker.sh` (loop principal), uses `lib/job_queue.sh` (BRPOP, set_state, locks), `lib/job_runner.sh` (run_job), `lib/output_json.sh` (log NDJSON), `lib/ssh_audit.sh` (audit_worker eventos).
- **Riscos**:
  - (R-1) Worker e morto por OOM/SIGKILL durante `cmd_create` → job em `running` fica inconsistente. Mitigar: ao startup, qualquer job em `nc:worker:current` e marcado `failed/error_msg=worker_killed` antes do BRPOP novo.
  - (R-2) Callback URL fica indisponivel por horas → retry exponencial com backoff (5s/30s/300s) total ~5min; apos 3 falhas marca `callback_failed=true` mas job permanece success/failed (estado real do cliente e o que importa).
  - (R-3) HMAC secret comprometido → policy de rotacao via secrets-file (D4.5); aqui apenas garantir leitura via LoadCredential do systemd (NAO ler do arquivo direto pelo worker).
  - (R-4) Deadlock no flock se host ficou em estado raro → systemd Watchdog 120s mata e reinicia.

### Quality Brief (Sprint D2)

**Quality Constraints (5)**:
1. Worker NUNCA executa `bash -c "$cmd"` — sempre `nextcloud-manage "${argv[@]}"` via array.
2. Worker NUNCA loga payload bruto — sempre via `lib/output_json::log_event` (sanitizacao automatica).
3. Lock duplo: `flock` no host (defesa primaria) + `nc:worker:lock` em Redis (defesa em profundidade).
4. Callback HMAC computado com `openssl dgst -sha256 -hmac "$WORKER_CALLBACK_SECRET" -hex`; secret lido via systemd LoadCredential (NAO via env file).
5. Trap SIGTERM marca job em `running` como `failed/error_msg=worker_terminated`, faz callback (best-effort), libera locks e sai com exit 0.

**Technical Advisory**:
- Renovacao do `nc:worker:lock` a cada 30s via background heartbeat (subshell trap-aware).
- BRPOP timeout=0 (block infinito); `kill -TERM $PID` interrompe via signal.
- Callback retry: 3 tentativas com backoff `5,30,300` (env WORKER_CALLBACK_BACKOFF override).

- **Arquivo(s)**:
  - `scripts/worker.sh` (NOVO)
  - `tests/integration/test_worker_loop.bats`
  - `tests/integration/test_worker_callback.bats`
- **Decisoes**:
  - Estrutura main loop:
    1. `flock /opt/nextcloud-saas-worker/lockfile`
    2. `worker_lock_acquire $$` (Redis)
    3. cleanup_orphan_jobs: para qualquer `nc:worker:current` apontando para job em `running` → set_state failed error_msg worker_killed; callback (best-effort); DEL nc:worker:current
    4. Iniciar heartbeat em background (renew worker_lock + client_lock a cada 30s)
    5. Trap SIGTERM/SIGINT: set state failed; callback; release locks; exit 0
    6. Loop:
       - `job_id=$(dequeue)` (BRPOP block infinito)
       - `set_state "$job_id" running started_at "$(now_iso)"`
       - `set worker_current "$job_id"`
       - argv=( $(jq -r '.[]' <<<"$(get_state "$job_id" | jq -r .args_json)") )
       - `client_lock_acquire "$client" 5` (renovar a cada 2s ate o fim do job)
       - `exit_code=$(run_job "$job_id" "$log_path" "${argv[@]}")`
       - new_state= [ exit_code -eq 0 ] && echo success || echo failed
       - `set_state "$job_id" "$new_state" exit_code "$exit_code" finished_at "$(now_iso)"`
       - `client_lock_release "$client"`
       - Se callback_url: `do_callback "$job_id" "$callback_url"` em background
       - `del worker_current`
       - `incr nc:worker:metrics:jobs_today`
- **Edge cases**:
  - Worker morre durante run_job: lockfile liberado pelo kernel; redis lock expira em 60s; nc:worker:current persiste -> cleanup_orphan_jobs no proximo startup
  - Disco cheio em /opt/nextcloud-customers/jobs/ → run_job retorna exit 1; worker continua
  - Callback timeout: 3 retries com sleep entre; total ~5min worst-case (5s + 30s + 300s); apos isso callback_failed=true mas job e success/failed
  - Sigterm durante callback retry: aborta retry; salva `callback_attempts=X callback_last_error=cancelled`; exit 0
- **Anti-patterns**:
  - `redis-cli HSET ... HGET ... HSET ...` em loop sequencial — overhead de TCP. Usar pipeline ou MULTI/EXEC.
  - `bash -c "..."` para reconstruir argv — sempre array.
  - Logger sync direto (block) com payload grande → use background or pipe.
- **Cenarios de teste** (Budget: 14 testes):
  - dequeue + set_state running → finished cycle: state transitions corretas
  - Worker morre durante run (mock SIGKILL durante cmd) → cleanup no next startup marca failed
  - Callback HMAC: validar header `X-Signature: sha256=<hex>` igual a `openssl dgst -sha256 -hmac SECRET` do body
  - Callback retry: 1 falha → 5s + retry → success: callback_attempts=2
  - Callback 3 falhas: callback_failed=true; job state preservado
  - Trap SIGTERM durante run → state=failed/error_msg=worker_terminated; callback disparado
  - Lock duplo: 2 instancias do worker iniciadas — segunda falha em flock + redis_lock
  - jobs_today INCR funciona (validar GET)
  - cleanup_orphan_jobs: pre-popular nc:worker:current=<jid> em estado running; restart → marca failed
  - heartbeat renova lock (validar TTL nao decai abaixo de 30s ao longo de 90s)
  - client_lock pegado durante job — outras invocacoes de occ-exec no mesmo cliente bloqueiam (testar em D4 quando occ-exec existir)
  - run_job timeout (1800s default, mockar 1s para testar) → state=failed/exit_code=124
  - Sanitizacao do log: senha em saida do cmd → log final tem `***`
  - Log permission 0640
- **Budget**: 14 testes
- **References**:
  - `docs/ARCHITECTURE.md §10 worker`, `Apêndice A.1 (systemd unit)`, `Apêndice A.2 (worker.env)`
  - `docs/CONTRACTS.md §5 (OpenAPI callback)` + `§3.6 (exit codes)`
- **Patterns**:
  - `~/.cursor/skills/capabilities/service-composition/references/orchestration-patterns.md` (worker daemon)
- **Seguranca**: HMAC secret via LoadCredential (nunca em env file plaintext); sanitizacao agressiva no log; argv array.
- **Performance**: enqueue->pickup latency <100ms (BRPOP block); 1 job/vez sequencial (ADR-002).
- **Criterio de aceite**:
  - bats verde com 14 testes
  - shellcheck warning-clean
  - systemd unit instalada via 2.4 e `systemctl status nextcloud-saas-worker` ativo
  - Logs em `journalctl -u nextcloud-saas-worker -o json` validam como JSON valido
- **executor_prompt**: |
    ### Quality Brief (Sprint D2)

    **Quality Constraints**:
    1. NUNCA bash -c — sempre array argv.
    2. NUNCA log bruto — sempre lib/output_json::log_event.
    3. Lock duplo: flock host + nc:worker:lock Redis.
    4. HMAC via openssl dgst -sha256 -hmac; secret via LoadCredential.
    5. Trap SIGTERM marca failed + callback + release locks.

    **Technical Advisory**:
    - Heartbeat renova locks a cada 30s.
    - BRPOP block infinito; signal interrompe.
    - Callback backoff 5,30,300; total ~5min.

    ---

    Criar `scripts/worker.sh` (~250 LOC) implementando o loop principal do worker.

    Source no topo:
    ```
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/lib/validators.sh"
    source "$SCRIPT_DIR/lib/output_json.sh"
    source "$SCRIPT_DIR/lib/job_queue.sh"
    source "$SCRIPT_DIR/lib/job_runner.sh"
    source "$SCRIPT_DIR/lib/ssh_audit.sh"
    ```

    Estrutura:
    ```
    main() {
      acquire_locks_or_die
      cleanup_orphan_jobs
      start_heartbeat &
      HEARTBEAT_PID=$!
      trap on_term SIGTERM SIGINT EXIT
      systemd_notify READY=1
      loop
    }

    loop() {
      while :; do
        job_id=$(dequeue) || break
        process_job "$job_id"
      done
    }

    process_job() {
      local jid="$1"
      local raw=$(get_state "$jid")
      local cmd=$(jq -r .cmd <<<"$raw")
      local client=$(jq -r .client <<<"$raw")
      local args_json=$(jq -r .args_json <<<"$raw")
      local callback=$(jq -r '.callback_url // empty' <<<"$raw")
      local log_path="/opt/nextcloud-customers/jobs/${jid}.log"

      mapfile -t ARGV < <(jq -r '.[]' <<<"$args_json")

      set_state "$jid" running started_at "$(now_iso)"
      _redis SET nc:worker:current "$jid"
      audit_worker run_start notice "$jid" cmd "$cmd" client "$client"

      client_lock_acquire "$client" 5

      local exit_code
      exit_code=$(run_job "$jid" "$log_path" nextcloud-manage "${ARGV[@]}")

      client_lock_release "$client"

      local new_state
      [[ "$exit_code" -eq 0 ]] && new_state=success || new_state=failed
      set_state "$jid" "$new_state" exit_code "$exit_code" finished_at "$(now_iso)"

      audit_worker run_finish notice "$jid" exit_code "$exit_code" state "$new_state"

      [[ -n "$callback" ]] && do_callback "$jid" "$callback" &
      _redis DEL nc:worker:current
      _redis INCR nc:worker:metrics:jobs_today
    }

    do_callback() {
      local jid="$1" url="$2"
      local body=$(get_state "$jid")
      local sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$WORKER_CALLBACK_SECRET" -hex | awk '{print $2}')
      local backoff=(5 30 300)
      local attempt=0
      for delay in "${backoff[@]}"; do
        attempt=$((attempt+1))
        _redis HINCRBY "nc:jobs:$jid" callback_attempts 1
        if curl -fsS --max-time "${WORKER_CALLBACK_TIMEOUT_SEC:-10}" -X POST \
              -H "X-Signature: sha256=$sig" \
              -H "Content-Type: application/json" \
              -d "$body" "$url"; then
          audit_worker callback_attempt notice "$jid" attempt "$attempt" status "success"
          return 0
        fi
        audit_worker callback_attempt warning "$jid" attempt "$attempt" status "failed"
        sleep "$delay"
      done
      _redis HSET "nc:jobs:$jid" callback_failed true
      audit_worker callback_failed warning "$jid" attempts "$attempt"
    }

    on_term() {
      local trap_signal=$?
      local current=$(_redis GET nc:worker:current 2>/dev/null || echo "")
      if [[ -n "$current" ]]; then
        set_state "$current" failed exit_code 137 finished_at "$(now_iso)" error_msg "worker_terminated"
        local cb=$(_redis HGET "nc:jobs:$current" callback_url || echo "")
        [[ -n "$cb" ]] && do_callback "$current" "$cb" &
        _redis DEL nc:worker:current
      fi
      kill "$HEARTBEAT_PID" 2>/dev/null || true
      release_locks
      exit 0
    }

    start_heartbeat() {
      while :; do
        sleep 30
        worker_lock_renew $$ 2>/dev/null || true
      done
    }

    cleanup_orphan_jobs() {
      local current=$(_redis GET nc:worker:current 2>/dev/null || echo "")
      [[ -n "$current" ]] || return 0
      set_state "$current" failed exit_code 137 finished_at "$(now_iso)" error_msg "worker_killed"
      local cb=$(_redis HGET "nc:jobs:$current" callback_url || echo "")
      [[ -n "$cb" ]] && do_callback "$current" "$cb" &
      _redis DEL nc:worker:current
    }

    main
    ```

    HMAC secret leitura: prefira `$CREDENTIALS_DIRECTORY/callback_secret` (systemd LoadCredential); fallback `/run/secrets/worker_callback_secret`.

    systemd_notify usa `systemd-notify` se disponivel; tolera ausencia (mock-friendly em CI).

    Tests integration:
    - test_worker_loop.bats (8 testes core de fluxo)
    - test_worker_callback.bats (6 testes callback HMAC + retry)

    NUNCA bash -c. NUNCA logar bruto. Sempre log_event.

    `critica: true` — Best-of-N: 2 implementadores em paralelo; selecao pelo melhor coverage + zero shellcheck warnings + menor footprint de memoria em smoke test.
</details>

<details>
<summary>2.4 — Instalar systemd units + AOF Redis</summary>

- **Arquivo(s)**:
  - Editar `scripts/deploy-server.sh` (instalacao das units)
  - Editar `shared-services/setup-shared.sh` (AOF Redis)
  - Validar artefatos ja em `systemd/*.service` (materializados por `/devops planejar`)
  - Tests integration `tests/integration/test_systemd_install.bats` (mock systemctl)
- **Abordagem**: extender deploy-server.sh com 4 chamadas idempotentes:
  1. `install -m 0644 systemd/nextcloud-saas-worker.service /etc/systemd/system/`
  2. `install -m 0644 systemd/nextcloud-saas-jobs-gc.timer /etc/systemd/system/`
  3. `install -m 0644 systemd/nextcloud-saas-jobs-gc.service /etc/systemd/system/`
  4. `install -m 0640 systemd/nextcloud-saas-worker.env.example /opt/nextcloud-saas-worker/.env` (somente se nao existir)
  5. `mkdir -p /opt/nextcloud-saas-worker /opt/nextcloud-customers/jobs`
  6. `systemctl daemon-reload && systemctl enable --now nextcloud-saas-worker.service && systemctl enable --now nextcloud-saas-jobs-gc.timer`
- **Decisoes**: AOF habilitado em `setup-shared.sh` editando `redis.conf`:
  ```
  appendonly yes
  appendfsync everysec
  auto-aof-rewrite-percentage 100
  auto-aof-rewrite-min-size 64mb
  ```
  Aplicar via `redis-cli CONFIG SET appendonly yes; CONFIG REWRITE` para nao precisar restart.
- **Edge cases**:
  - Worker.env ja existe → preservar (operador pode ter customizado WORKER_CONCURRENCY/timeouts); apenas avisar
  - systemd unit instalado mas worker.sh nao existe → systemctl start falha; mensagem clara
  - AOF ja habilitado → CONFIG SET e idempotente
- **Anti-patterns**: nao apagar /opt/nextcloud-saas-worker/.env existente sem backup
- **Validacoes**: idempotencia — rodar deploy-server.sh 2x nao quebra nada
- **Cenarios de teste** (Budget: 5 testes):
  - install novo (host limpo via mock) → unit em /etc/systemd/system/
  - install ja existente → preserva .env do operador
  - daemon-reload chamado apos copy
  - enable + start chamados em ordem correta
  - AOF: redis-cli CONFIG GET appendonly retorna yes apos setup
- **Budget**: 5 testes
- **References**: `docs/ARCHITECTURE.md Apêndice A.1, A.2, A.3`
- **Criterio de aceite**: bats verde + smoke deploy em VM staging mostra worker active
- **executor_prompt**: |
    Estender `scripts/deploy-server.sh` (existente, 914 LOC) com funcao `install_worker_units()` chamada apos a etapa de instalacao do `nextcloud-manage` symlink.

    Codigo a adicionar:
    ```
    install_worker_units() {
      log "Instalando systemd units do worker"
      install -m 0644 -o root -g root \
        "$REPO_DIR/systemd/nextcloud-saas-worker.service" /etc/systemd/system/
      install -m 0644 -o root -g root \
        "$REPO_DIR/systemd/nextcloud-saas-jobs-gc.service" /etc/systemd/system/
      install -m 0644 -o root -g root \
        "$REPO_DIR/systemd/nextcloud-saas-jobs-gc.timer" /etc/systemd/system/

      mkdir -p /opt/nextcloud-saas-worker
      mkdir -p /opt/nextcloud-customers/jobs

      if [[ ! -f /opt/nextcloud-saas-worker/.env ]]; then
        install -m 0640 -o root -g root \
          "$REPO_DIR/systemd/nextcloud-saas-worker.env.example" \
          /opt/nextcloud-saas-worker/.env
      else
        log "WARN: /opt/nextcloud-saas-worker/.env ja existe — preservando customizacoes"
      fi

      systemctl daemon-reload
      systemctl enable --now nextcloud-saas-worker.service
      systemctl enable --now nextcloud-saas-jobs-gc.timer
    }
    ```

    Em `shared-services/setup-shared.sh` adicionar:
    ```
    enable_redis_aof() {
      docker compose -f shared-services/docker-compose.yml exec -T shared-redis \
        redis-cli -a "$REDIS_PASSWORD" CONFIG SET appendonly yes
      docker compose -f shared-services/docker-compose.yml exec -T shared-redis \
        redis-cli -a "$REDIS_PASSWORD" CONFIG SET appendfsync everysec
      docker compose -f shared-services/docker-compose.yml exec -T shared-redis \
        redis-cli -a "$REDIS_PASSWORD" CONFIG REWRITE
    }
    ```

    Chamar `install_worker_units` no main de deploy-server.sh.
    Chamar `enable_redis_aof` no setup-shared.sh apos `docker compose up`.

    Tests em `tests/integration/test_systemd_install.bats`:
    - Mock systemctl/install via PATH wrapper que captura args.
    - Validar idempotencia.

    NUNCA usar systemctl start sem daemon-reload antes.
    NUNCA apagar .env existente.
</details>

<details>
<summary>2.5 — ssh-gateway: ncsaas-api user + sshd config + sudoers + shim</summary>

- **Arquivo(s)**:
  - Editar `scripts/deploy-server.sh` (criar usuario, instalar configs)
  - Criar `scripts/ncsaas-api-shim` (binario do shim — extraido do Apêndice A.7 de ARCHITECTURE)
  - Validar artefatos materializados em `ssh/{50-ncsaas-api.sshd.conf, 51-ncsaas-api-sftp.conf, ncsaas-api.sudoers, authorized_keys.example}`
  - Tests integration `tests/integration/test_ssh_shim.bats`
- **Abordagem**: deploy-server.sh ganha `setup_ssh_gateway()`:
  1. `useradd -r -m -d /home/ncsaas-api -s /usr/sbin/nologin ncsaas-api` (idempotente via `getent passwd`)
  2. Setup `~ncsaas-api/.ssh/` permissoes
  3. `install -m 0755 scripts/ncsaas-api-shim /usr/local/bin/ncsaas-api-shim`
  4. `install -m 0644 ssh/50-ncsaas-api.sshd.conf /etc/ssh/sshd_config.d/`
  5. `install -m 0644 ssh/51-ncsaas-api-sftp.conf /etc/ssh/sshd_config.d/` (jail SFTP — D3 ativa, em D2 pode ja instalar)
  6. `install -m 0440 ssh/ncsaas-api.sudoers /etc/sudoers.d/ncsaas-api && visudo -c -f /etc/sudoers.d/ncsaas-api`
  7. `mkdir -p /opt/nextcloud-customers/inbox && chown ncsaas-api:ncsaas-api /opt/nextcloud-customers/inbox && chmod 0700 /opt/nextcloud-customers/inbox` (D3 usa)
  8. `systemctl reload sshd`
- **Decisoes**: shim e Bash 80 linhas com source de `lib/output_json.sh`, `lib/ssh_audit.sh`, `lib/validators.sh` (allowlist de argv).
- **Edge cases**:
  - sshd_config.d nao suporta drop-ins na distro (improvavel no Ubuntu 24.04) → fallback warn + exit
  - visudo -c falha → reverter (rm sudoers.d/ncsaas-api); exit 5
  - Operador adicionou chave manualmente em authorized_keys → preservar (deploy-server nao mexe; apenas instala estrutura)
- **Anti-patterns**:
  - Permitir TTY/X11 forwarding na config sshd
  - Usar `eval $SSH_ORIGINAL_COMMAND` no shim (= como nao ter shim)
  - Sudoers com wildcard `/usr/local/bin/*` (= qualquer binario)
- **Validacoes**: visudo -c valida sudoers. sshd -T valida config. Shim valida argv contra allowlist.
- **Cenarios de teste** (Budget: 10 testes):
  - useradd ncsaas-api idempotente (rodar 2x ok)
  - Instalacao de configs ssh + sudoers
  - visudo -c verde (nao deve pular)
  - sshd -t verde apos install
  - Shim aceita `nextcloud-manage list` → exec sudo
  - Shim rejeita `bash` → exit 101
  - Shim rejeita argv com `;` → exit 100 metachar
  - Shim rejeita argv com `$(...)` → exit 100
  - Shim rejeita argv com `--password=secret` → exit 5
  - audit_ssh chamado em todo invoke (logger mock captura tag)
- **Budget**: 10 testes
- **References**: `docs/ARCHITECTURE.md Apêndice A.4, A.5, A.6, A.7`, `docs/CONTRACTS.md §3.7 (shim allowlist)`
- **Seguranca**: vetor #1 do §7.3 (chave SSH comprometida) — shim e a unica defesa apos chave roubada.
- **Criterio de aceite**:
  - bats verde com 10 testes
  - shellcheck warning-clean em ncsaas-api-shim
  - smoke em VM: `ssh -i <api_key> ncsaas-api@host nextcloud-manage list` retorna lista
  - smoke seguranca: `ssh -i <api_key> ncsaas-api@host bash` retorna exit 101 + log auth.warning
- **executor_prompt**: |
    Criar binario `scripts/ncsaas-api-shim` (Bash, ~80 linhas) e integrar no deploy-server.sh.

    `scripts/ncsaas-api-shim`:
    ```bash
    #!/bin/bash
    set -euo pipefail

    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    # As libs vivem em /opt/nextcloud-customers/scripts/lib (instalado pelo deploy)
    LIB_DIR="${SHIM_LIB_DIR:-/opt/nextcloud-customers/scripts/lib}"
    source "$LIB_DIR/output_json.sh"
    source "$LIB_DIR/validators.sh"
    source "$LIB_DIR/ssh_audit.sh"

    KEY_ID="${SSH_USER_AUTH:-unknown}"
    CLIENT_IP="${SSH_CONNECTION%% *}"
    ORIG="${SSH_ORIGINAL_COMMAND:-}"

    audit_ssh invoke accepted key_id "$KEY_ID" client_ip "$CLIENT_IP" command "$ORIG"

    if [[ -z "$ORIG" ]]; then
      audit_ssh reject rejected reason "interactive_shell_blocked"
      emit_error interactive_shell_not_allowed "shell interactive forbidden for ncsaas-api"
      exit 102
    fi

    # Reject metachars
    if [[ "$ORIG" == *[';|&$`'"$'\\\\'"']* ]]; then
      audit_ssh reject rejected reason "metachar" command "$ORIG"
      emit_error invalid_command "metacharacter detected"
      exit 100
    fi

    # Reject --password= em qualquer lugar
    if [[ "$ORIG" == *--password=* || "$ORIG" == *--password\ * ]]; then
      audit_ssh reject rejected reason "password_in_argv" command "$ORIG"
      emit_error password_in_argv_forbidden "password must come via --payload-stdin"
      exit 5
    fi

    # Tokenize
    read -r -a ARGV <<< "$ORIG"

    if [[ "${ARGV[0]:-}" != "nextcloud-manage" ]]; then
      audit_ssh reject rejected reason "binary_not_allowed" argv0 "${ARGV[0]:-}"
      emit_error command_not_allowed "binary not in allowlist"
      exit 101
    fi

    audit_ssh accept accepted argv "${ORIG}"
    unset 'ARGV[0]'
    exec sudo -n /usr/local/bin/nextcloud-manage "${ARGV[@]}"
    ```

    Estender `scripts/deploy-server.sh` com:
    ```
    setup_ssh_gateway() {
      log "Setup SSH gateway (ncsaas-api)"

      if ! getent passwd ncsaas-api >/dev/null; then
        useradd -r -m -d /home/ncsaas-api -s /usr/sbin/nologin ncsaas-api
      fi
      install -d -m 0700 -o ncsaas-api -g ncsaas-api /home/ncsaas-api/.ssh

      install -d -m 0700 -o ncsaas-api -g ncsaas-api /opt/nextcloud-customers/inbox

      install -m 0755 -o root -g root "$REPO_DIR/scripts/ncsaas-api-shim" \
        /usr/local/bin/ncsaas-api-shim

      install -m 0644 -o root -g root "$REPO_DIR/ssh/50-ncsaas-api.sshd.conf" \
        /etc/ssh/sshd_config.d/
      install -m 0644 -o root -g root "$REPO_DIR/ssh/51-ncsaas-api-sftp.conf" \
        /etc/ssh/sshd_config.d/

      install -m 0440 -o root -g root "$REPO_DIR/ssh/ncsaas-api.sudoers" \
        /etc/sudoers.d/ncsaas-api
      visudo -c -f /etc/sudoers.d/ncsaas-api || {
        rm -f /etc/sudoers.d/ncsaas-api
        log "FAIL: sudoers invalido — abortando"
        exit 5
      }

      sshd -t || {
        log "FAIL: sshd config invalido"
        exit 5
      }
      systemctl reload sshd

      # Instalar libs do shim em /opt/nextcloud-customers/scripts/lib
      install -d -m 0755 /opt/nextcloud-customers/scripts/lib
      cp -a "$REPO_DIR/scripts/lib/." /opt/nextcloud-customers/scripts/lib/
    }
    ```

    Tests (10) em `tests/integration/test_ssh_shim.bats`:
    - Mock useradd/install/visudo/sshd/systemctl via wrappers em PATH.
    - Mock logger via tests/fixtures/mock-logger captura args.
    - Cobrir cenarios da nota tecnica.

    NUNCA aceitar bash ou outros binarios no shim.
    NUNCA usar eval em SSH_ORIGINAL_COMMAND.
    SEMPRE audit_ssh antes de exit (auditoria mesmo em rejeicao).
</details>

<details>
<summary>2.6 — Wiring observability + journald retention</summary>

- **Arquivo(s)**:
  - Editar `scripts/manage.sh` (call sites de log_event no enqueue path)
  - Editar `scripts/worker.sh` (call sites — ja em 2.3)
  - Editar `scripts/ncsaas-api-shim` (call sites — ja em 2.5)
  - `journald.conf.d/50-nextcloud-saas.conf` (NOVO em ssh/ ou novo dir, instalado por deploy-server.sh)
  - Tests `tests/integration/test_observability.bats`
- **Abordagem**: observability ja foi wirada em 2.3 e 2.5; aqui validamos cobertura completa via tests + adicionamos config journald para retencao 30d.
- **Decisoes**: arquivo `journald.conf.d/50-nextcloud-saas.conf`:
  ```
  [Journal]
  SystemMaxUse=2G
  MaxRetentionSec=30day
  ForwardToSyslog=no
  ```
  Instalar via deploy-server.sh em `/etc/systemd/journald.conf.d/`.
- **Edge cases**:
  - 2 retencoes diferentes (30day em config + nosso GC de jobs em 30day) → coexistem; jobs/<id>.log e independente do journald
  - SystemMaxUse=2G + 50 instancias com worker rodando → suficiente; documentar em ADMINISTRATION.md
- **Anti-patterns**:
  - Logar payload bruto sem passar por log_event (perde sanitizacao)
  - Logger sync em path quente (manage-cli enqueue) sem fork — usar `audit_ssh & disown` se latencia critica
- **Cenarios de teste** (Budget: 6 testes):
  - log_event em manage-cli: stdout NDJSON parseavel
  - log_event sanitiza senha automaticamente
  - audit_ssh em shim: tag correta + level correto
  - audit_worker em worker: tag correta
  - journald.conf.d/50 instalado com permissoes corretas
  - SystemMaxUse e MaxRetentionSec setados
- **Budget**: 6 testes
- **References**: `docs/ARCHITECTURE.md §9 (Observabilidade)`
- **Criterio de aceite**: bats verde; smoke `journalctl -u nextcloud-saas-worker -o json | head -5 | jq -e .` retorna json valido
- **executor_prompt**: |
    Esta task e principalmente **integracao + validacao** — call sites ja estao em 2.3 (worker) e 2.5 (shim). Aqui:

    1. Auditar `scripts/manage.sh` para garantir que enqueue path chama:
       ```
       log_event info enqueue job_id "$job_id" cmd "$cmd" client "$client" idempotency_key "${PARSED_FLAGS[idempotency_key]:-}" caller_uid "$(id -u)"
       ```
       APOS o enqueue retornar sucesso.

    2. Adicionar `journald.conf.d/50-nextcloud-saas.conf` no repo (em `systemd/` ou novo dir `journald/`):
       ```
       [Journal]
       SystemMaxUse=2G
       MaxRetentionSec=30day
       ForwardToSyslog=no
       ```

    3. Estender deploy-server.sh:
       ```
       install -d -m 0755 /etc/systemd/journald.conf.d
       install -m 0644 -o root -g root \
         "$REPO_DIR/systemd/journald.conf.d/50-nextcloud-saas.conf" \
         /etc/systemd/journald.conf.d/
       systemctl restart systemd-journald
       ```

    Tests (6) em `tests/integration/test_observability.bats` validando call sites e instalacao.
</details>

<details>
<summary>2.8 — manage.sh job <id> {status|logs|cancel} + job list</summary>

- **Arquivo(s)**:
  - Editar `scripts/manage.sh` (handlers `cmd_job_status`, `cmd_job_logs`, `cmd_job_cancel`, `cmd_job_list`)
  - Tests `tests/integration/test_manage_job.bats`
- **Abordagem**:
  - `job <id> status [--json]`: `get_state "$id"` → JobStatus schema (CONTRACTS §4.4)
  - `job <id> logs`: cat /opt/nextcloud-customers/jobs/<id>.log; `--follow` deferido v12.1+
  - `job <id> cancel`: se state=queued → LREM nc:jobs:queue + set_state canceled; senao exit 5 (state_conflict_cannot_cancel)
  - `job list [--state] [--client] [--cmd] [--limit] [--offset|--after]`: SCAN MATCH nc:jobs:* COUNT 1000 + jq filter; paginacao por offset (default) ou cursor `--after=<job_id>`
- **Decisoes**:
  - `--limit` default 50, max 500
  - paginacao cursor mais eficiente que offset em fila grande; ambas suportadas
- **Edge cases**:
  - job nao existe → emit_error not_found exit 14
  - cancel em state=running → exit 5 (worker nao pode ser interrompido externamente)
  - logs grandes (>10MB) → tail -c 10485760 com aviso `truncated_at_10mb=true`
  - SCAN com 5000 jobs → paginar SCAN cursor; nao retornar tudo de uma vez
- **Anti-patterns**: `KEYS nc:jobs:*` (uso `SCAN`); cancelar via worker signal (apenas via Redis state)
- **Cenarios de teste** (Budget: 10 testes):
  - job status existente: JSON com schema_version, state, started_at, finished_at, exit_code, summary_json
  - job status nao existe: exit 14
  - job logs: cat OK
  - job logs grande: truncado com flag
  - job cancel queued: state=canceled; LREM
  - job cancel running: exit 5
  - job list sem filtros: retorna ate 50 ordenados por queued_at desc
  - job list --state=success: filtro funciona
  - job list --client=acme --cmd=create: filtro composto
  - job list --limit=2 --after=<jid>: cursor paginacao
- **Budget**: 10 testes
- **References**: `docs/CONTRACTS.md §4.4 (JobStatus)`, `§4.7.1 (QueueStats)`
- **Criterio de aceite**: bats verde + shellcheck warning-clean
- **executor_prompt**: |
    Adicionar 4 handlers em `scripts/manage.sh`:

    cmd_job_status() — args: <job_id>; lookups Redis via get_state; output JobStatus schema; exit 14 se nao existe.

    cmd_job_logs() — args: <job_id>; cat log_path do hash; truncar em 10MB com aviso.

    cmd_job_cancel() — args: <job_id>; case state in
      queued) LREM nc:jobs:queue 1 <job_id>; set_state canceled finished_at <ts>; exit 0 ;;
      *) emit_error state_conflict_cannot_cancel; exit 5 ;;
    esac

    cmd_job_list() — args: [--state=...] [--client=...] [--cmd=...] [--limit=N] [--offset=N|--after=<id>];
    delega para `lib/job_queue.sh::job_list` (criado em D1.7).

    Dispatch em manage.sh:
    ```
    case "$cmd" in
      job)
        sub="${ARGV[2]:-}"; jid="${ARGV[3]:-}"
        case "$sub" in
          status) cmd_job_status "$jid" ;;
          logs) cmd_job_logs "$jid" ;;
          cancel) cmd_job_cancel "$jid" ;;
          list) cmd_job_list "${ARGV[@]:3}" ;;
          *) emit_error invalid_subcommand; exit 5 ;;
        esac
        ;;
      ...
    esac
    ```

    Tests (10) em `tests/integration/test_manage_job.bats`.
</details>

<details>
<summary>2.10 — Tests integration end-to-end async</summary>

- **Arquivo(s)**: `tests/integration/test_async_e2e.bats` + `tests/fixtures/mock-callback-server.sh`
- **Abordagem**: spawn redis fixture + spawn callback receiver mock (Bash + nc -l) + invocar manage.sh via subprocess + worker.sh em background; validar fluxo completo.
- **Cenarios de teste** (Budget: 8 testes):
  - dispatch + enqueue: `manage.sh acme nextcloud.acme.com.br create --async --json` retorna EnqueuedJob; key existe em Redis
  - worker pickup: depois de iniciar worker, key transita para state=running em <1s
  - exec mock: cmd_create mockado retorna exit 0; state=success em <2s
  - callback HMAC: callback receiver recebe POST com X-Signature valido (validar HMAC contra body+secret)
  - callback retry: receiver retorna 500 nas 2 primeiras; 200 na 3a; callback_attempts=3 callback_failed=null
  - callback failed: receiver retorna 500 sempre; callback_failed=true apos 3 tentativas; job ainda success
  - idempotency: 2a invocacao mesma chave → mesmo job_id (sem tocar fila)
  - cancel queued: invocar cancel antes do worker pickup → state=canceled
- **Budget**: 8 testes
- **References**: `docs/CONTRACTS.md §5 (OpenAPI callback)`
- **Criterio de aceite**: bats verde com 8 e2e
- **executor_prompt**: |
    Criar suite de tests integration end-to-end em `tests/integration/test_async_e2e.bats`.

    Setup:
    ```
    setup() {
      load 'helpers/redis_fixture'
      start_redis_fixture
      load 'helpers/setup'
      export WORKER_REDIS_HOST="$REDIS_HOST"
      export WORKER_REDIS_PORT="$REDIS_PORT"
      export WORKER_REDIS_DB=16
      export WORKER_CALLBACK_SECRET="test-secret"
      # Mock cmd_create (legacy) returning exit 0
      export DOCKER_FAKE_OUTPUT='[]'
      # Spawn callback receiver
      export CALLBACK_PORT=$(get_free_port)
      tests/fixtures/mock-callback-server.sh "$CALLBACK_PORT" >/tmp/cb.log 2>&1 &
      CALLBACK_PID=$!
      sleep 0.2
    }

    teardown() {
      kill "$CALLBACK_PID" 2>/dev/null || true
      stop_redis_fixture
      rm -f /tmp/cb.log
    }
    ```

    Cobrir cenarios da nota tecnica.

    `tests/fixtures/mock-callback-server.sh` deve:
    - Aceitar arg <port>.
    - Loop de `nc -l -p $port` em while true.
    - Para cada request: parse body, salvar em /tmp/cb-receipt-<id>.json, retornar HTTP 200 (ou 500 conforme env CALLBACK_FAIL_ATTEMPTS).
    - Validar X-Signature comparando openssl dgst contra body + secret.

    NUNCA depender de internet — tudo via localhost.
</details>

---

## Sprint F1 — Fix Gate D2 (Async Core)
> Categoria: F
> Origem: `/qa validar` da Sprint D2 em 2026-05-08, registrado em `docs/FINDINGS.md`.
> Gate: D2 so pode ser considerada aprovada quando `docs/FINDINGS.md` tiver `F-D2-001..F-D2-006` como `FIXED`, `F-D2-007` com evidencia de CI/ambiente provisionado ou `DEFERRED` justificado, e os smokes `MANAGE_SKIP_ROOT_CHECK=1 bash scripts/manage.sh help`, `WORKER_TEST_MODE=1 bash scripts/worker.sh`, `bash -n scripts/*.sh scripts/lib/*.sh`, suites Bats D2, ShellCheck e Redis fixture estiverem verdes no ambiente disponivel.
> review: senior+qa

| Status | Tamanho | Tarefa | Skill/Command | Depende de |
|--------|---------|--------|---------------|------------|
| [x] | P | F1.1 — Corrigir sobrescrita global de `SCRIPT_DIR` em `scripts/lib/job_queue.sh`, preservando startup de `manage.sh` e `worker.sh` | `bash` | F-D2-001 |
| [x] | M | F1.2 — Substituir parser frágil de `get_state` por serializacao JSON segura para valores com aspas, barras e arrays (`args_json`) | `bash` + `jq` | F-D2-002, F-D1-002 |
| [x] | P | F1.3 — Garantir bloqueio de `--password=*` antes da remoção de flags/posicionais, cobrindo `manage.sh`, `dispatch.sh` e shim SSH | `bash` | F-D2-003 |
| [x] | P | F1.4 — Separar audit NDJSON do JSON contratual de enqueue para que `--async --json` emita uma unica raiz `EnqueuedJob` em stdout | `bash` + `jq` | F-D2-004 |
| [x] | P | F1.5 — Tornar callback HMAC fail-closed: sem secret real, nao enviar POST autenticado como `unsigned`; registrar erro claro no job | `bash` + `openssl` | F-D2-005 |
| [x] | P | F1.6 — Atualizar testes D2 de idempotência para assinatura atual de `idem_check <key> <args_hash> <job_id>` e retorno `same:<job_id>` | `bats` | F-D2-006 |
| [x] | P | F1.7 — Reexecutar gate D2 em CI ou ambiente provisionado com `bats`, `shellcheck`, `redis-cli` e Docker; anexar evidencia em `docs/FINDINGS.md`/`docs/AUTOPILOT-REPORT.md` | `bash` + CI | F-D2-007, F1.1-F1.6 |

**Notas de execução:**

- A Sprint F1 tem escopo corretivo: nao iniciar D3 enquanto houver `CRITICAL` ou `HIGH` aberto para D2.
- Prioridade obrigatoria: F1.1 e F1.2 primeiro, porque destravam os smokes basicos e a introspecao de jobs usada pelas demais validacoes.
- Ao concluir cada tarefa, atualizar o finding correspondente em `docs/FINDINGS.md` para `FIXED` com evidencia curta do comando executado.
- Se o ambiente local continuar sem `bats`/`shellcheck`/`redis-cli`/Docker, F1.7 deve registrar claramente qual evidencia veio de CI e qual continua indisponivel localmente.

---

## Sprint D3 — Feature O (Lifecycle de users/groups/apps + SCP staging + occ-bridge P1)
> Categoria: D
> Gate: API REST consegue invocar `nextcloud-manage <cliente> {user|group|apps} <verb> ... --async --payload-stdin --staging-id=<uuid>` via SSH; SCP staging para `/opt/nextcloud-customers/inbox/<staging-id>/` funciona em jail SFTP (`internal-sftp` + ChrootDirectory); senha **nunca** aparece em journald nem em `JobStatus.args` (scrub agressivo + payload via stdin); user/group/apps lifecycle multi-step OCC executa via `lib/occ_bridge.sh::occ_run` com allowlist canonica de 33 entries.
> review: senior+qa

| Status | Tamanho | Tarefa | Skill/Command | Depende de |
|--------|---------|--------|---------------|------------|
| [x] | M | 3.1 — `lib/occ_bridge.sh`: implementar `occ_run` real (consome allowlist de 35 entries materializada em D1; `docker exec <c>-app php occ <subcmd> "${args[@]}"` em modo argv; parsed_result quando OCC suporta --output=json; bloqueio sandbox para 8 BLOCKLIST patterns) | `bash` + `bats` | D1.7, D2.3 |
| [x] | M | 3.2 — inbox-staging: ativar SFTP jail (drop-in 51-ncsaas-api-sftp.conf ja instalado em D2.5); criar metadata `nc:inbox:<staging-id>` (size_total, files[], created_at); GC orfaos em 24h (jobs-gc.timer estendido) | `bash` + `sshd` + `bats` | D2.5 |
| [x] | M | 3.3 — user-group-apps user: cmd_user_create / cmd_user_remove (--force) / cmd_user_modify (display-name, email, groups, quota, enable, disable, resend_welcome, add_subadmin, remove_subadmin) — todas async, payload-stdin obrigatorio para senha | `bash` + `bats` | 3.1 |
| [x] | M | 3.4 — user-group-apps group/apps: cmd_group_create / cmd_group_remove (--force) / cmd_group_modify (rename via OCC ≥31, com guard); cmd_apps_enable (lote, parcial-tolerante, --strict) / cmd_apps_disable (lote, --strict, remove_after_disable) | `bash` + `bats` | 3.1 |
| [x] | M | 3.5 — create estendido: --apps=a,b,c / --full-apps / --staging-id=<uuid> / --payload-stdin (logo_data_url + background_data_url ≤256KB; >256KB exige SCP) | `bash` + `bats` | 3.1, 3.2 |
| [x] | M | 3.6 — remove estendido: --force, --backup-first (job composto: backup-then-remove), --confirm=<cliente> obrigatorio em sync | `bash` + `bats` | 3.1 |
| [x] | M | 3.7 — Tests integration Feature O: user/group/apps lifecycle + SCP staging + senha via stdin + sanitization journald | `bats` | 3.1..3.6 |
| [x] | P | 3.8 — Atualizar `docs/CONTRACTS.md` para revisao 0.4 refletindo implementacao concreta + regenerar JSON Schemas se schema_version permanece 1 | `bash` (manual edit) | 3.1..3.7 |

**Notas tecnicas (tarefas M):**

<details>
<summary>3.1 — lib/occ_bridge.sh occ_run [critica: true]</summary>

### Mini Design Doc

- **Escopo**: Ativar a funcao `occ_run` em `scripts/lib/occ_bridge.sh` (skeleton ja materializado por /devops planejar com 35 entries OCC_ALLOWLIST + 8 BLOCKLIST). `occ_run <client> <subcmd> [args...]` valida contra allowlist + blocklist, executa `docker exec <c>-app php occ <subcmd> "${args[@]}"` com timeout 60s, captura stdout/stderr/exit_code, parsea JSON quando subcmd suporta `--output=json`.
- **Componentes**: `lib/occ_bridge.sh` (extensao); `lib/job_queue.sh::client_lock_acquire/release`; `lib/output_json.sh::log_event` para audit; `lib/ssh_audit.sh::audit_occ` para journald.
- **Riscos**:
  - (R-1) Argv injection — mitigar com array nunca string-concat; bloquear metacaracteres em wrap; sanitizar via shim antes (D2.5 ja faz mas double-check)
  - (R-2) Container `<c>-app` parado durante exec → exit 14 com mensagem clara
  - (R-3) OCC timeout (>60s em files:scan grande) → exit 15 (`occ_timeout`); sugerir Feature O.4 apps async para operacoes longas
  - (R-4) Drift entre allowlist no codigo e em CONTRACTS §3.10.1 — mitigar com gate CI `contracts-check.yml` (ja materializado)

### Quality Brief (Sprint D3)

**Quality Constraints (5)**:
1. `occ_run` SEMPRE invoca via array argv: `docker exec <c>-app php occ <subcmd> "${args[@]}"`. Nunca `bash -c`.
2. Validar subcmd esta em OCC_ALLOWLIST (de skeleton); rejeitar se em OCC_BLOCKLIST. Exit 100 senao.
3. `client_lock_acquire` ANTES de exec mutavel (verbs em SET_STATE_OCC_VERBS); release no defer.
4. Senha em args (e.g. user:add) NUNCA via argv — exigir `--payload-stdin` que injeta via env `NEXTCLOUD_USER_PASSWORD` para `--password-from-env`.
5. Audit log NDJSON (audit_occ) para CADA invocacao com exit_code + duration_ms + decision.

**Technical Advisory**:
- Para parsed_result, usar `OCC_JSON_CAPABLE` set (8 entries no skeleton); chamar com `--output=json` somente nesses; tentar jq -e em outros falha graceful.
- Consumer interno em D3 (Sprint S2 P1): apenas chamadas internas de cmd_user_*. Public CLI via `<cliente> occ-exec` fica para D4.

- **Arquivo(s)**:
  - `scripts/lib/occ_bridge.sh` (extensao do skeleton existente)
  - `tests/integration/test_occ_bridge.bats`
- **Decisoes**:
  - SET_STATE_OCC_VERBS = (user:add user:delete user:disable user:enable user:setting user:resetpassword group:add group:delete group:adduser group:removeuser app:enable app:disable app:install app:remove maintenance:mode files:cleanup files:repair-tree config:app:set config:app:delete versions:cleanup theming:config notification:generate db:add-missing-indices db:add-missing-columns)
  - READ_ONLY_OCC_VERBS = (user:info user:list group:info group:list app:list maintenance:repair config:app:get config:app:list config:system:get files:scan-app-data versions:expire)
  - Variavel readonly OCC_RUN_TIMEOUT_SEC default 60 (override via env WORKER_OCC_TIMEOUT_SEC)
  - Para `password-from-env`: ler `NEXTCLOUD_USER_PASSWORD` apenas se passada via env do invocador; nunca preservar em args do hash do job (Feature O ja garante isso ao consumir `--payload-stdin` em manage-cli)
- **Edge cases**:
  - Container parado: `docker inspect -f '{{.State.Running}}' <c>-app` retorna `false` → exit 14
  - Subcmd nao na allowlist mas com prefixo proximo (ex: `user:adddd`) → rejeitado
  - Subcmd em allowlist + arg em blocklist (raro: e.g. `app:install` com fonte nao oficial) → bloquear via outro check no shim para `<c> occ-exec` (D4); em D3 cmd_user_* usa apenas chamadas internas pre-validadas
  - parsed_result: jq -e falha → retornar parsed_result null + stdout cru
  - timeout: SIGTERM apos 60s; SIGKILL apos 90s (timeout --kill-after=30)
- **Anti-patterns**:
  - String-concat de args para `docker exec` — array obrigatoria
  - Esquecer client_lock em verbs mutaveis — corrupcao silenciosa
  - Ler senha de argv → vaza em ps -ef
- **Validacoes**: subcmd em allowlist + nao em blocklist + container running + cliente lockable.
- **Cenarios de teste** (Budget: 14 testes integration):
  - allowlisted subcmd: `user:list` → exit 0 + parsed_result JSON
  - blocklisted subcmd: `encryption:decrypt-all` → exit 100 occ_command_not_allowed
  - subcmd nao em allowlist: `unknown:cmd` → exit 100
  - container parado: docker inspect mock retorna false → exit 14 instance_not_running
  - timeout: subcmd que demora > OCC_RUN_TIMEOUT_SEC=1 → exit 15 occ_timeout
  - exit_code != 0 do OCC: exit 16 occ_command_failed + stdout/stderr preservados
  - parsed_result em OCC_JSON_CAPABLE: parsed_result populado
  - parsed_result em OCC nao json-capable: parsed_result null + stdout cru
  - argv injection: `user:add "; rm -rf /; #"` → bloqueado pelo shim antes; e em occ_run, args sao array entao mesmo metacharacter passa como literal
  - client_lock pegado em verb mutavel; testar bloqueio de 2a invocacao concorrente
  - audit_occ chamado em todo invoke (mock logger captura tag)
  - drift gate: lista local difere de CONTRACTS §3.10.1 → CI contracts-check.yml falha (validar via test)
  - --payload-stdin com senha: senha NAO aparece em journald (audit_occ)
  - duration_ms registrado corretamente (mock OCC com sleep 1)
- **Budget**: 14 testes
- **References**: `docs/CONTRACTS.md §3.10 (OCC allowlist + blocklist)`, `docs/REQUIREMENTS.md §4.2 Feature P`
- **Patterns**:
  - `~/.cursor/skills/capabilities/service-composition/references/orchestration-patterns.md` (security boundary)
- **Seguranca**: vetor #2 do §7.3 (ExApp escala via HaRP) — allowlist e a primeira linha de defesa.
- **Performance**: <5s p95 para subcmds rapidos; <60s p99 para files:scan parcial.
- **Criterio de aceite**:
  - bats verde com 14 testes
  - shellcheck warning-clean
  - drift gate CI verde
  - duration_ms <5s para `user:list` em smoke real
- **executor_prompt**: |
    ### Quality Brief (Sprint D3)

    **Quality Constraints**:
    1. occ_run via array argv (docker exec <c>-app php occ <subcmd> "${args[@]}"). Nunca bash -c.
    2. Validar contra OCC_ALLOWLIST + OCC_BLOCKLIST. Exit 100.
    3. client_lock antes de exec mutavel.
    4. Senha via NEXTCLOUD_USER_PASSWORD env (nao argv) + --password-from-env.
    5. audit_occ NDJSON para cada invoke.

    **Technical Advisory**:
    - parsed_result so para OCC_JSON_CAPABLE (8 entries).
    - D3 = consumer interno (cmd_user_*); D4 = public CLI occ-exec.

    ---

    Estender `scripts/lib/occ_bridge.sh` (skeleton em D1 com OCC_ALLOWLIST/OCC_BLOCKLIST/OCC_JSON_CAPABLE materializados) implementando:

    ```bash
    occ_run() {
      local client="$1" subcmd="$2"
      shift 2
      local args=("$@")

      # 1. Validar allowlist/blocklist
      if ! occ_is_allowed "$subcmd"; then
        audit_occ "$client" "$subcmd" rejected reason "not_in_allowlist"
        emit_error occ_command_not_allowed "subcommand $subcmd not in allowlist"
        return 100
      fi
      if occ_is_blocklisted "$subcmd"; then
        audit_occ "$client" "$subcmd" rejected reason "blocklisted"
        emit_error occ_command_not_allowed "subcommand $subcmd blocklisted"
        return 100
      fi

      # 2. Container check
      local container="${client}-app"
      if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
        audit_occ "$client" "$subcmd" rejected reason "instance_not_running"
        emit_error instance_not_running "container $container not running"
        return 14
      fi

      # 3. Client lock para verbs mutaveis
      local need_lock=false
      if occ_is_state_changing "$subcmd"; then
        client_lock_acquire "$client" 60 || {
          emit_error client_busy_async_job_running
          return 17
        }
        need_lock=true
      fi
      trap "[[ \"$need_lock\" == true ]] && client_lock_release \"$client\"" RETURN

      # 4. Build OCC args (--output=json se capable)
      local occ_args=("$subcmd" "${args[@]}")
      if occ_supports_json "$subcmd"; then
        occ_args+=("--output=json")
      fi
      # Senha via env, nunca argv
      if [[ -n "${NEXTCLOUD_USER_PASSWORD:-}" ]]; then
        occ_args+=("--password-from-env")
      fi

      # 5. Exec com timeout
      local start_ms=$(date +%s%3N)
      local stdout_path stderr_path
      stdout_path=$(mktemp); stderr_path=$(mktemp)
      local exit_code=0
      timeout --signal=TERM --kill-after=30 "${WORKER_OCC_TIMEOUT_SEC:-60}" \
        docker exec ${NEXTCLOUD_USER_PASSWORD:+-e NEXTCLOUD_USER_PASSWORD} \
                    "$container" php occ "${occ_args[@]}" \
        >"$stdout_path" 2>"$stderr_path" || exit_code=$?

      local duration_ms=$(( $(date +%s%3N) - start_ms ))
      local stdout_content stderr_content
      stdout_content=$(<"$stdout_path"); stderr_content=$(<"$stderr_path")
      rm -f "$stdout_path" "$stderr_path"

      if [[ "$exit_code" -eq 124 || "$exit_code" -eq 137 ]]; then
        audit_occ "$client" "$subcmd" timeout duration_ms "$duration_ms" timeout_sec "${WORKER_OCC_TIMEOUT_SEC:-60}"
        emit_error occ_timeout "subcommand timed out"
        return 15
      fi
      if [[ "$exit_code" -ne 0 ]]; then
        audit_occ "$client" "$subcmd" failed exit_code "$exit_code" duration_ms "$duration_ms"
        emit_error occ_command_failed "exit=$exit_code" 0 stdout "$stdout_content" stderr "$stderr_content"
        return 16
      fi

      # 6. parsed_result (best-effort)
      local parsed_json=null
      if occ_supports_json "$subcmd"; then
        if echo "$stdout_content" | jq -e . >/dev/null 2>&1; then
          parsed_json=$(echo "$stdout_content" | jq -c .)
        fi
      fi

      audit_occ "$client" "$subcmd" success exit_code 0 duration_ms "$duration_ms"

      emit_json schema_version "1" \
                occ_command "$subcmd" \
                exit_code "@number:0" \
                stdout "$stdout_content" \
                stderr "$stderr_content" \
                parsed_result "@json:$parsed_json" \
                duration_ms "@number:$duration_ms"
      return 0
    }

    occ_is_state_changing() {
      local s="$1"
      local set=(user:add user:delete user:disable user:enable user:setting user:resetpassword \
                 group:add group:delete group:adduser group:removeuser \
                 app:enable app:disable app:install app:remove \
                 maintenance:mode files:cleanup files:repair-tree \
                 config:app:set config:app:delete versions:cleanup \
                 theming:config notification:generate \
                 db:add-missing-indices db:add-missing-columns)
      [[ " ${set[*]} " == *" $s "* ]]
    }
    ```

    Tests (14) em `tests/integration/test_occ_bridge.bats`:
    - Mock docker via fixture (DOCKER_FAKE_OUTPUT, DOCKER_FAKE_EXIT).
    - Setup redis fixture para client_lock.
    - Cobrir cenarios da nota tecnica.

    NUNCA bash -c. NUNCA passwords em argv. SEMPRE audit_occ.

    `critica: true` — Best-of-N: 2 implementadores; selecao pelo melhor coverage de blocklist edge cases.
</details>

<details>
<summary>3.2 — inbox-staging (SFTP jail + metadata + GC)</summary>

- **Arquivo(s)**:
  - `ssh/51-ncsaas-api-sftp.conf` (ja materializado por /devops planejar; validar e ativar em D2.5 ja instalou)
  - Editar `scripts/deploy-server.sh` (criar /opt/nextcloud-customers/inbox + chown ncsaas-api)
  - Estender `lib/job_queue.sh` com `inbox_metadata_create/get/delete`
  - Estender `systemd/nextcloud-saas-jobs-gc.service` para incluir GC do inbox
  - Tests `tests/integration/test_inbox_staging.bats`
- **Abordagem**:
  - Quando manage-cli recebe `--staging-id=<uuid>` em create/occ-exec, valida que inbox existe em /opt/.../inbox/<id>/ e chama `inbox_metadata_create` (HSET nc:inbox:<id> staging_id <id> created_at <ts> consumed_at "" files <count> size_total <bytes> client <cliente_quando_definido>).
  - Worker, ao processar job com staging_id, faz `mv /opt/.../inbox/<id>/* /opt/.../jobs/<job_id>/staging/` e atualiza metadata `consumed_at`.
  - GC: jobs-gc.service estendido para `find /opt/.../inbox -maxdepth 1 -mindepth 1 -type d -mmin +1440 -exec rm -rf {} +` (24h sem consumo) + `redis-cli SCAN ... DEL nc:inbox:<id> orfaos`.
- **Decisoes**: SFTP jail via internal-sftp + ChrootDirectory `/opt/nextcloud-customers/inbox` (ja em ssh/51); ForceCommand internal-sftp -d /%U; PasswordAuthentication no para o jail; size limit por arquivo 5MB e por staging-id 10MB total (validado pelo manage-cli no consumo).
- **Edge cases**:
  - SCP arquivo > 5MB → manage-cli rejeita no consumo (size > limit) com exit 18 (`staging_size_limit_exceeded`)
  - staging-id desconhecido (nao SCP-pado) → exit 19 (`staging_not_found`)
  - Race: GC roda enquanto job consumindo → metadata existe; GC verifica `consumed_at` antes de deletar
  - SFTP jail nao funciona (config errada) → ssh -t falha em D2.5 setup; user vê erro claro
- **Anti-patterns**: chmod 0777 em /opt/.../inbox (deve ser 0700 ncsaas-api); permitir shell no Match User do jail
- **Cenarios de teste** (Budget: 8 testes):
  - SCP de teste para /opt/.../inbox/<id>/file.png (mock sftp)
  - inbox_metadata_create: HSET nc:inbox:<id> com fields corretos
  - manage-cli consume: mv para jobs/<jid>/staging/ + update consumed_at
  - GC orfao 24h: dir + metadata removidos
  - GC ativo (consumed_at recente): preservado
  - size limit por arquivo: arquivo 6MB rejeitado
  - SFTP jail: ssh ncsaas-api@host (sem internal-sftp) → conexao recusada
  - SFTP put fora de /inbox/ (ex: /etc/passwd via path traversal) → rejeitado
- **Budget**: 8 testes
- **References**: `docs/REQUIREMENTS.md Feature O.5`, `docs/ARCHITECTURE.md §3 (path layout)`, `docs/CONTRACTS.md §3.9 (SCP staging) + InboxMetadata schema`
- **Seguranca**: R-O-2 (SCP abuse) — chroot + size limits + GC.
- **Criterio de aceite**: bats verde + smoke SCP em VM staging
- **executor_prompt**: |
    Implementar Feature O.5 SCP staging em 4 partes:

    1. Em `lib/job_queue.sh` adicionar:
       ```
       inbox_metadata_create() {
         local staging_id="$1" file_count="$2" size_total="$3" client="${4:-}"
         is_valid_uuid_v4 "$staging_id" || return 5
         _redis HSET "nc:inbox:$staging_id" \
           staging_id "$staging_id" \
           created_at "$(now_iso)" \
           consumed_at "" \
           files "$file_count" \
           size_total "$size_total" \
           client "$client"
         _redis EXPIRE "nc:inbox:$staging_id" 86400
       }
       inbox_metadata_consume() { local sid="$1" jid="$2"; _redis HSET "nc:inbox:$sid" consumed_at "$(now_iso)" job_id "$jid"; }
       inbox_metadata_get() { _redis HGETALL "nc:inbox:$1"; }
       ```

    2. Em manage.sh enqueue path (D2.1) extender para validar `--staging-id`:
       - Verificar que /opt/nextcloud-customers/inbox/<id>/ existe e ncsaas-api e dono
       - Verificar size_total (du -sb) <= 10485760 (10MB) e cada arquivo <= 5242880 (5MB)
       - Chamar inbox_metadata_create
       - Setar field staging_id no hash do job (HSET nc:jobs:<jid> staging_id <id>)

    3. Em worker.sh process_job extender para mover staging:
       ```
       staging_id=$(jq -r '.staging_id // empty' <<<"$raw")
       if [[ -n "$staging_id" ]]; then
         mkdir -p "/opt/nextcloud-customers/jobs/$jid/staging"
         mv /opt/nextcloud-customers/inbox/"$staging_id"/* \
            "/opt/nextcloud-customers/jobs/$jid/staging/" 2>/dev/null || true
         rmdir /opt/nextcloud-customers/inbox/"$staging_id" 2>/dev/null || true
         inbox_metadata_consume "$staging_id" "$jid"
       fi
       ```

    4. Estender `systemd/nextcloud-saas-jobs-gc.service`:
       ```
       ExecStart=/bin/bash -c '\
         /usr/bin/find /opt/nextcloud-customers/jobs -maxdepth 1 -type f -name "*.log" -mtime +30 -delete; \
         /usr/bin/find /opt/nextcloud-customers/inbox -maxdepth 1 -mindepth 1 -type d -mmin +1440 -exec rm -rf {} +; \
         /usr/bin/find /opt/nextcloud-customers/jobs -maxdepth 2 -type d -name "staging" -mtime +30 -exec rm -rf {} +'
       ```

    Tests (8) em `tests/integration/test_inbox_staging.bats`:
    - Mock SCP via cp local + chown ncsaas-api.
    - Cobrir cenarios da nota tecnica.

    NUNCA chmod 0777. SEMPRE 0700 owner=ncsaas-api.
</details>

<details>
<summary>3.3 — user-group-apps user verbs [critica: true]</summary>

### Mini Design Doc

- **Escopo**: Implementar 3 handlers de async (`cmd_user_create`, `cmd_user_remove`, `cmd_user_modify`) que sao **enqueue-only** em manage-cli (apenas constroem args_json e chamam `enqueue`); a execucao real fica no worker via `worker_exec_user_create/remove/modify` que invocam `occ_run` multi-step.
- **Componentes**: `manage.sh` (handlers stub que enqueue), `scripts/worker.sh` extension (`worker_exec_<verb>`), `lib/occ_bridge.sh` (occ_run de D3.1), `lib/output_json.sh` (sanitizacao de senha).
- **Riscos**:
  - (R-1) Senha via argv vazaria em ps -ef do worker — mitigar com `--payload-stdin` obrigatorio em manage-cli; envio para worker via campo `payload_redacted_json` (sem senha) + envio real da senha via `nc:jobs:<jid>:secret` STRING separada com TTL=300s
  - (R-2) Falha em passo intermediario do user-create (e.g. user:add ok, group:adduser fail) → estado parcial. Mitigar: registrar `summary.occ_steps[].state` e marcar job state=failed com error_msg detalhado; nao tentar rollback automatico (operador decide).
  - (R-3) Idempotencia em user-create reentrada com mesmos args = no-op (idempotency-key cobre 24h; alem disso, se user ja existe em OCC, idempotente success).

### Quality Brief (Sprint D3)

**Quality Constraints (5)**:
1. Senha NUNCA em argv. `--payload-stdin` obrigatorio. Validar JSON do stdin contra SchemaUserCreatePayload.
2. Senha em hash do job em campo separado `nc:jobs:<jid>:secret` (STRING TTL 300s); referenciado via `payload_secret_ref` no hash; deletada apos consumo pelo worker.
3. Audit log de cada OCC step em `summary.occ_steps[].{started_at, finished_at, exit_code, occ_subcmd}`. Sanitizar via `sanitize_secrets` antes de set_state.
4. user-create idempotente: se user existe em OCC com mesmo email/display_name → no-op success. Atributos diferentes → exit 4 (state_conflict).
5. apps batch: por padrao tolerante; --strict aborta no primeiro fail; sem --strict, processa todos e expoe summary.failed_apps[].

**Technical Advisory**:
- Para user-create multi-step (user:add → user:setting quota → group:adduser N grupos → opcional add_subadmin): N+1 chamadas occ_run sequenciais; cada uma vai para summary.occ_steps[].
- Resend welcome via OCC `notification:generate <user> "welcome"` (subcmd em allowlist).
- enable/disable via `user:enable`/`user:disable` (em allowlist).

- **Arquivo(s)**:
  - `scripts/manage.sh` (handlers cmd_user_*)
  - `scripts/worker.sh` (extension worker_exec_user_*)
  - Tests `tests/integration/test_user_lifecycle.bats`
- **Decisoes**:
  - manage-cli `cmd_user_create <client> <username> --display-name=... --email=... --groups=g1,g2 --quota=5GB --payload-stdin --async` valida via lib/validators (regex username `^[a-z0-9._-]{1,64}$`, email RFC, quota unit), le payload-stdin (JSON com password obrigatorio + subadmin_groups[] opcional), grava senha em `nc:jobs:<jid>:secret` (TTL 300s) e enqueue normalmente.
  - Hash do job tem `payload_redacted_json` com password substituida por `***` (output_json::sanitize), e `payload_secret_ref="nc:jobs:<jid>:secret"`.
  - worker_exec_user_create:
    1. Le `nc:jobs:<jid>:secret` para extrair password; export NEXTCLOUD_USER_PASSWORD
    2. occ_run user:add <username> --display-name="..." --email="..." --password-from-env
    3. Se quota: occ_run user:setting <username> files quota "5 GB"
    4. Para cada group em groups: occ_run group:adduser <group> <username>
    5. Para cada subadmin_group: (OCC sub-admin nao tem subcmd direto; fazer via config:app:set OU occ user:setting; documentar como deferido se Nextcloud nao suportar OCC; em primeira impl, apenas registrar no summary)
    6. unset NEXTCLOUD_USER_PASSWORD; DEL nc:jobs:<jid>:secret
    7. set_state success summary_json (com occ_steps[])
- **Edge cases**:
  - Username invalido → exit 5 invalid_username em manage-cli (antes do enqueue)
  - User ja existe + mesmos atributos → no-op success (idempotente; via occ user:info pre-check)
  - User ja existe + atributos diferentes → exit 4 state_conflict no worker
  - Email malformado → exit 5
  - Senha < 8 chars → exit 5 invalid_password (politica do Nextcloud + nossa validacao)
  - Group nao existe + group:adduser → step falha; nao aborta os outros (politica tolerante por default; --strict altera)
- **Anti-patterns**:
  - Senha em argv: `nextcloud-manage acme user create john --password=foo` → exit 5 (defesa em D2.1 e shim)
  - Senha em log do job: scrub regex
  - Esquecer DEL do secret apos consumo: TTL 300s e seguranca de ultimo recurso
- **Cenarios de teste** (Budget: 12 testes integration):
  - cmd_user_create enqueue: payload-stdin valido → EnqueuedJob; senha em nc:jobs:<jid>:secret (TTL>0)
  - cmd_user_create senha curta no payload → exit 5
  - cmd_user_create username invalido → exit 5
  - worker_exec_user_create executa: user:add + user:setting quota + group:adduser para 2 groups + summary.occ_steps[] com 4 entries
  - User ja existe mesmos atributos → idempotente success (skip user:add)
  - User ja existe atributos diferentes → state_conflict exit 4
  - Senha NAO aparece em journald (validar via grep no jornal mockado)
  - cmd_user_remove --force: occ user:delete; idempotente se nao existe
  - cmd_user_modify enable/disable: occ user:enable/disable
  - cmd_user_modify resend_welcome: occ notification:generate
  - cmd_user_modify add_subadmin: registra em summary (deferido se OCC nao suporta)
  - --strict em user-create com group inexistente: aborta com state=failed
- **Budget**: 12 testes
- **References**: `docs/REQUIREMENTS.md Feature O.2`, `docs/CONTRACTS.md §4.8 UserCreate Payload`, `§3.10.1 OCC allowlist`
- **Seguranca**: LGPD — senha em rota separada com TTL 300s; scrub agressivo; --payload-stdin obrigatorio.
- **Criterio de aceite**:
  - bats verde com 12 testes
  - shellcheck warning-clean
  - Smoke real em ambiente staging: `nextcloud-manage acme user create john --display-name="John" --email=j@a.com --groups=editors --quota=5GB --async --payload-stdin <<<'{"password":"secret123"}'` retorna EnqueuedJob; worker executa; OCC user:add + user:setting + group:adduser executam; callback HMAC entrega summary com occ_steps[]
  - `journalctl -u nextcloud-saas-worker --since "5 min ago" | grep secret123` retorna 0 linhas
- **executor_prompt**: |
    ### Quality Brief (Sprint D3)

    **Quality Constraints**:
    1. Senha NUNCA em argv. --payload-stdin obrigatorio.
    2. Senha em nc:jobs:<jid>:secret (TTL 300s); reference via payload_secret_ref.
    3. Audit por OCC step em summary.occ_steps[].
    4. user-create idempotente; conflict → exit 4.
    5. apps batch tolerante por default; --strict aborta.

    **Technical Advisory**:
    - user-create multi-step: user:add → user:setting → group:adduser → optional add_subadmin.
    - resend_welcome via notification:generate.
    - enable/disable via user:enable/user:disable.

    ---

    Implementar 3 cmd_user_* em manage.sh + 3 worker_exec_user_* em worker.sh.

    cmd_user_create (manage.sh):
    ```
    cmd_user_create() {
      local client="$1" username="$2"; shift 2
      [[ -n "${PARSED_FLAGS[async]:-}" ]] || { emit_error async_required; exit 5; }
      [[ -n "${PARSED_FLAGS[payload_stdin]:-}" ]] || { emit_error payload_stdin_required; exit 5; }
      is_valid_client_name "$client" || { emit_error invalid_client; exit 5; }
      [[ "$username" =~ ^[a-z0-9._-]{1,64}$ ]] || { emit_error invalid_username; exit 5; }

      local payload
      payload=$(cat)  # stdin
      local pwd=$(jq -r '.password // empty' <<<"$payload")
      [[ ${#pwd} -ge 8 ]] || { emit_error invalid_password; exit 5; }

      local job_id=$(uuidgen)
      _redis SET "nc:jobs:$job_id:secret" "$payload" EX 300

      local payload_redacted=$(jq -c '.password = "***"' <<<"$payload")

      enqueue "$job_id" \
        cmd "user-create" \
        client "$client" \
        target "$username" \
        args_json "@json:$(jq -nc --arg c "$client" --arg u "$username" '[$c,"user","create",$u]')" \
        payload_redacted_json "$payload_redacted" \
        payload_secret_ref "nc:jobs:$job_id:secret" \
        ...

      emit_json job_id "$job_id" state queued queued_at "$(now_iso)"
    }
    ```

    worker_exec_user_create:
    ```
    worker_exec_user_create() {
      local jid="$1" client="$2" username="$3"
      local secret_ref=$(_redis HGET "nc:jobs:$jid" payload_secret_ref)
      local payload=$(_redis GET "$secret_ref")
      _redis DEL "$secret_ref"  # consumido

      local pwd=$(jq -r '.password' <<<"$payload")
      local display=$(jq -r '.display_name // empty' <<<"$payload")
      local email=$(jq -r '.email // empty' <<<"$payload")
      local quota=$(jq -r '.quota // empty' <<<"$payload")
      mapfile -t groups < <(jq -r '.groups[]? // empty' <<<"$payload")

      local steps='[]'
      local fail=0

      # Step 1: user:add
      export NEXTCLOUD_USER_PASSWORD="$pwd"
      local s1_start=$(now_iso)
      if occ_run "$client" user:add "$username" \
         ${display:+--display-name="$display"} ${email:+--email="$email"} \
         --password-from-env; then
        steps=$(jq --arg s "user:add" --arg ts "$s1_start" --arg te "$(now_iso)" \
          '. + [{occ_subcmd:$s,started_at:$ts,finished_at:$te,exit_code:0}]' <<<"$steps")
      else
        # Idempotencia: se user ja existe, e atributos batem → success
        if occ_run "$client" user:info "$username" >/dev/null; then
          ## comparar atributos para conflict ou no-op (deferido em primeira impl)
          steps=$(jq '. + [{occ_subcmd:"user:add",exit_code:0,note:"already_exists"}]' <<<"$steps")
        else
          fail=1
        fi
      fi
      unset NEXTCLOUD_USER_PASSWORD

      # Step 2..N: quota, groups, etc
      [[ -n "$quota" && "$fail" -eq 0 ]] && { occ_run "$client" user:setting "$username" files quota "$quota" || fail=1; }
      for g in "${groups[@]}"; do
        [[ "$fail" -eq 0 ]] && occ_run "$client" group:adduser "$g" "$username" || true
      done

      local final_state=success
      [[ "$fail" -ne 0 ]] && final_state=failed

      set_state "$jid" "$final_state" \
        exit_code "$fail" \
        finished_at "$(now_iso)" \
        summary_json "$(jq -n --argjson s "$steps" '{occ_steps:$s}')"
    }
    ```

    cmd_user_remove + worker_exec_user_remove (analogo, com user:delete; --force passa --no-confirm).
    cmd_user_modify + worker_exec_user_modify (analogo, com user:enable/disable, user:setting, group:adduser/removeuser, notification:generate para resend_welcome).

    Tests (12) em `tests/integration/test_user_lifecycle.bats`.

    NUNCA argv com senha. SEMPRE DEL secret apos consumo. SEMPRE summary.occ_steps[].

    `critica: true` — Best-of-N: 2 implementadores; selecao pelo melhor handling de idempotencia + LGPD compliance.
</details>

<details>
<summary>3.4 — user-group-apps group/apps verbs</summary>

- **Arquivo(s)**: `scripts/manage.sh` (cmd_group_* + cmd_apps_*) + worker.sh extension; tests `tests/integration/test_group_apps_lifecycle.bats`
- **Abordagem**:
  - cmd_group_create: enqueue → worker → occ_run group:add (idempotente se ja existe)
  - cmd_group_remove --force: occ group:delete; sem --force exige confirmacao no sync (mas async-only entao --force opcional)
  - cmd_group_modify --rename: requer Nextcloud ≥31; checar OCC version pre-call (occ status); se <31 → exit 20 (`feature_unsupported_by_nextcloud_version`)
  - cmd_apps_enable: para cada app em lote, occ_run app:enable; default tolerante (1 falha nao aborta); --strict aborta no primeiro
  - cmd_apps_disable: simetrico; --remove_after_disable executa app:remove apos disable bem-sucedido
- **Cenarios de teste** (Budget: 10 testes):
  - cmd_group_create new: success
  - cmd_group_create existente: idempotente success
  - cmd_group_remove --force: success
  - cmd_group_modify --rename em NC≥31 mock: success
  - cmd_group_modify --rename em NC<31: exit 20
  - cmd_apps_enable lote 3 apps: 3 success em summary.apps[]
  - cmd_apps_enable com 1 app inexistente (sem --strict): 2 success + 1 fail; exit 1 warning
  - cmd_apps_enable com --strict + 1 app inexistente: aborta no primeiro; state=failed
  - cmd_apps_disable + remove_after_disable: 2 OCC calls por app (disable + remove)
  - cmd_apps_disable simetrico ao enable
- **Budget**: 10 testes
- **References**: `docs/REQUIREMENTS.md Feature O.3, O.4`, `docs/CONTRACTS.md §4.8 GroupCreate/AppsToggle Payload`
- **Criterio de aceite**: bats verde + smoke real em staging
- **executor_prompt**: |
    Implementar cmd_group_create / cmd_group_remove / cmd_group_modify / cmd_apps_enable / cmd_apps_disable em manage.sh + worker_exec_* em worker.sh.

    cmd_group_modify --rename precisa de NC version check via:
    ```
    nc_version=$(occ_run "$client" status 2>/dev/null | jq -r '.parsed_result.versionstring // empty' | cut -d. -f1)
    [[ "$nc_version" -ge 31 ]] || { emit_error feature_unsupported_by_nextcloud_version; exit 20; }
    ```

    cmd_apps_enable lote:
    ```
    worker_exec_apps_enable() {
      local jid="$1" client="$2"; shift 2
      mapfile -t apps < <(jq -r '.apps[]?' <<<"$payload")
      local strict=$(jq -r '.strict // false' <<<"$payload")
      local results='[]'
      local total_failed=0
      for app in "${apps[@]}"; do
        if occ_run "$client" app:enable "$app"; then
          results=$(jq --arg a "$app" '. + [{app:$a, state:"enabled"}]' <<<"$results")
        else
          results=$(jq --arg a "$app" '. + [{app:$a, state:"failed"}]' <<<"$results")
          total_failed=$((total_failed+1))
          if [[ "$strict" == "true" ]]; then
            set_state "$jid" failed exit_code 1 summary_json "$(jq -n --argjson r "$results" '{apps:$r,failed_apps:[($r[]|select(.state=="failed").app)]}')"
            return 0
          fi
        fi
      done
      local final=success
      [[ "$total_failed" -gt 0 ]] && final="success"  # warning, mas success per requisitos
      set_state "$jid" "$final" exit_code 0 summary_json "$(jq -n --argjson r "$results" --argjson f "$total_failed" '{apps:$r,total_failed:$f}')"
    }
    ```

    Tests (10) em `tests/integration/test_group_apps_lifecycle.bats`.
</details>

<details>
<summary>3.5 — create estendido (--apps / --full-apps / --staging-id / --payload-stdin)</summary>

- **Arquivo(s)**: estender `cmd_create` em scripts/manage.sh; tests `tests/integration/test_create_extended.bats`
- **Abordagem**: `cmd_create` legacy continua funcionando; novas flags sao parsed e propagadas para `worker_exec_create` que apos o create base executa apps:enable em lote + theming:config se branding presente.
- **Decisoes**:
  - `--full-apps` expande para lista hardcoded `FULL_APPS_PRESET=(activity bookmarks calendar contacts deck files_pdfviewer mail notes notifications photos polls richdocuments tasks text zip)` (suite produtividade Nextcloud Hub)
  - `--apps=a,b,c` aditivo a `--full-apps`; deduplicar
  - `--staging-id` via inbox-staging (D3.2); arquivos esperados: `logo.png`, `background.{jpg|png}`
  - Branding inline via `--payload-stdin {"branding": {"logo_data_url": "data:image/png;base64,...", "background_data_url": "..."}}` para anexos ≤256KB; >256KB exige SCP staging
  - branding aplica via occ_run theming:config primary "..." + theming:config logoMime ... etc.
- **Cenarios de teste** (Budget: 8 testes):
  - cmd_create basico legacy: continua passando smoke D1
  - cmd_create --apps=a,b,c: apos create base, occ app:enable a; b; c
  - cmd_create --full-apps: 15 apps habilitados
  - cmd_create --apps=x,y --full-apps: dedup + 17 apps habilitados
  - cmd_create --staging-id=<uuid> com logo.png em /opt/.../inbox/<uuid>/: apos create, mv para /opt/.../jobs/<jid>/staging/ + theming:config carrega
  - cmd_create --payload-stdin com logo_data_url (200KB): theming:config aplica inline
  - cmd_create --payload-stdin com logo_data_url >256KB: exit 5 (use --staging-id)
  - cmd_create idempotente: 2a chamada com mesmos args + idempotency-key → no-op
- **Budget**: 8 testes
- **References**: `docs/REQUIREMENTS.md Feature O.1`, `docs/CONTRACTS.md §3.9.0 (decision matrix base64 vs SCP)`, `§4.8 CreateCustomerExtendedPayload`
- **Criterio de aceite**: bats verde + smoke real
- **executor_prompt**: |
    Estender cmd_create em manage.sh para aceitar --apps, --full-apps, --staging-id e --payload-stdin com branding.

    Em manage.sh enqueue path para cmd=create:
    - Parse --apps=a,b,c em variavel APPS_LIST
    - --full-apps expande FULL_APPS_PRESET (hardcoded)
    - Se --payload-stdin: ler stdin como JSON; validar branding.logo_data_url (decode base64; check <= 256KB); branding.url; primary_color (hex); etc.
    - Se --staging-id: validar inbox existe (lib/job_queue::inbox_metadata_get); validar size_total <= 10MB
    - Persist APPS_LIST + branding_json + staging_id em hash do job

    worker_exec_create:
    1. Executar cmd_create_legacy (codigo atual de create) — modulo isolado em manage.sh::run_legacy_create
    2. Se branding_json presente: occ_run "$c" theming:config primary "$primary"; theming:config name "$name"; etc.
    3. Se logo via staging-id: cp /opt/.../jobs/<jid>/staging/logo.png /opt/<c>/themes/logo.png; occ_run theming:config logoMime ...
    4. Se logo via data_url: decode + cp; idem
    5. Se APPS_LIST: para cada app, occ_run app:enable

    Tests (8) em `tests/integration/test_create_extended.bats`.
</details>

<details>
<summary>3.6 — remove estendido (--force, --backup-first, --confirm)</summary>

- **Arquivo(s)**: cmd_remove em manage.sh; worker_exec_remove (composto se --backup-first); tests `tests/integration/test_remove_extended.bats`
- **Abordagem**:
  - `--confirm=<cliente>` obrigatorio quando NAO --async (sync direto na CLI)
  - `--force` em async pula confirmacao
  - `--backup-first`: worker executa backup primeiro; se backup ok → remove; se backup fail → state=failed sem remove (proteção contra perda de dados)
- **Cenarios de teste** (Budget: 6 testes):
  - sync sem --confirm: exit 5 confirm_required
  - sync com --confirm=acme em cliente acme: ok
  - sync com --confirm=acne em cliente acme: exit 5 confirm_mismatch
  - async --force: pula confirm
  - --backup-first ok: 2 occ_run em sequencia + state=success
  - --backup-first com backup falhando: state=failed; remove NAO executa (validar instancia ainda existe)
- **Budget**: 6 testes
- **References**: `docs/REQUIREMENTS.md Feature D + Feature O.2 (--force)`
- **Seguranca**: vetor #3 do §7.3 (job destrutivo cliente errado).
- **Criterio de aceite**: bats verde
- **executor_prompt**: |
    Estender cmd_remove em manage.sh:

    sync path:
    ```
    if [[ "${PARSED_FLAGS[async]:-}" != "1" ]]; then
      [[ "${PARSED_FLAGS[confirm]:-}" == "$client" ]] || { emit_error confirm_required_or_mismatch; exit 5; }
      cmd_remove_legacy "$client" "$dom"
    fi
    ```

    async path: enqueue normal com extra hash field `backup_first=true|false`.

    worker_exec_remove:
    ```
    if [[ "$backup_first" == "true" ]]; then
      run_legacy_backup "$client" || {
        set_state "$jid" failed error_msg "backup_first_failed_aborting_remove"
        return 0
      }
    fi
    run_legacy_remove "$client"
    ```

    Tests (6) em `tests/integration/test_remove_extended.bats`.
</details>

<details>
<summary>3.7 — Tests integration Feature O completa</summary>

- **Arquivo(s)**: `tests/integration/test_feature_o_e2e.bats`
- **Cenarios de teste** (Budget: 8 testes e2e):
  - SCP staging + create extended + apps batch + branding: fluxo completo via SSH/SCP mockado
  - User create + group create + apps enable em sequencia (3 jobs encadeados via callback)
  - User modify add_subadmin + resend_welcome
  - Group rename em NC≥31
  - User remove --force; verificar backup gerado (jobs/<jid>/log mostra backup completed)
  - Apps disable + remove_after_disable
  - Senha NUNCA aparece: grep journald + grep job log + grep summary_json + grep callback body — todos retornam 0 linhas matching senha real
  - Idempotency: 2a chamada user-create mesmo idempotency-key + mesma senha → no-op success com mesmo job_id
- **Budget**: 8 testes e2e
- **Criterio de aceite**: bats verde + smoke real em staging com Nextcloud 30.x
- **executor_prompt**: |
    Suite e2e em `tests/integration/test_feature_o_e2e.bats` cobrindo Feature O completa.

    Setup: redis fixture + worker daemon em background + callback receiver mock + container nextcloud mockado (mock-nextcloud-occ que aceita argv e retorna stdout pre-canned).

    Cobrir cenarios da nota tecnica.

    Critico: validar sanitizacao de senhas em multiplos pontos:
    ```
    @test "senha nunca aparece em journald" {
      run nextcloud-manage acme user create john --async --payload-stdin <<<'{"password":"sup3rs3cr3t!"}'
      [ "$status" -eq 0 ]
      job_id=$(jq -r .job_id <<<"$output")
      sleep 2
      run grep -r "sup3rs3cr3t" /tmp/mock-journald-output.log /opt/nextcloud-customers/jobs/
      [ "$status" -ne 0 ]  # 0 = found = FAIL
    }
    ```
</details>

---

## Sprint D4 — Feature P (occ-exec sync) + Hardening (socket-proxy + secrets + health + client-lock)
> Categoria: D
> Gate: API REST consegue invocar `nextcloud-manage <cliente> occ-exec <subcmd> [args]` via SSH com timeout 60s; client-lock impede `occ-exec` mutavel concorrente com worker async (exit 17); `manage.sh health [--json]` roda 8 checks paralelos em <10s; socket-proxy interposto entre HaRP e dockerd (allowlist EXEC=0 SECRETS=0 ...); secrets em `/opt/shared-services/secrets/*` (0600 root:root); `manage.sh upgrade-harp <cliente>` migra clientes existentes.
> review: senior+qa

| Status | Tamanho | Tarefa | Skill/Command | Depende de |
|--------|---------|--------|---------------|------------|
| [x] | M | 4.1 — `manage.sh <cliente> occ-exec <subcmd> [args]` (publico): consumir `lib/occ_bridge.sh::occ_run` (D3.1); --json/--payload-stdin/--staging-id; client-lock check; sem --async (sync only) | `bash` + `bats` | D3.1, 4.2 |
| [x] | M | 4.2 — client-lock: `lib/job_queue.sh::client_lock_acquire/release/renew` (criados em D1.7); wiring em worker.sh (acquire antes de exec mutavel) e manage-cli (acquire antes de occ-exec mutavel; exit 17 se ocupado) | `bash` + `bats` | D2.3 |
| [x] | M | 4.3 — health-command: `manage.sh health [--json]` com 8 checks paralelos (timeout 5s cada): containers shared, Traefik certs, DNS fixos, recording welcome, harp-via-socket-proxy, disco /opt, redis queue, worker active | `bash` + `bats` | D2.3 |
| [x] | M | 4.4 — socket-proxy migrado: adicionar service no shared-services/docker-compose.yml (artefato ja em shared-services/socket-proxy/.env.example); cmd_create gera template HaRP com tcp://socket-proxy:2375; subcomando `manage.sh upgrade-harp <cliente>` migra clientes existentes; smoke test ExApp install em CI | `bash` + `docker compose` + `bats` | D2.4 |
| [x] | M | 4.5 — secrets-file: `setup-shared.sh` cria `/opt/shared-services/secrets/*` (0600); compose usa `secrets:`/_FILE quando suportado; runtime export para imagens sem _FILE; remover plaintext de .env | `bash` + `docker compose` + `bats` | D2.4 |
| [x] | P | 4.6 — Editar `journald.conf.d/50-nextcloud-saas.conf` (criado em D2.6) para incluir tag occ-exec na retencao | `bash` | D2.6 |
| [x] | M | 4.7 — Tests integration occ-exec + client-lock + health: allowlist + bloqueio + parsed_result + concurrencia worker/cli + 8 checks health | `bats` | 4.1..4.5 |
| [x] | P | 4.8 — Atualizar `docs/TROUBLESHOOTING.md` (secoes Worker, Socket-proxy, SSH ncsaas-api, OCC-exec) + `docs/ADMINISTRATION.md` (operacao occ-exec) | `bash` (manual edit) | 4.1..4.7 |

**Notas tecnicas (tarefas M):**

<details>
<summary>4.1 — manage.sh occ-exec publico [critica: true]</summary>

### Mini Design Doc

- **Escopo**: Expor publicamente o passthrough `<cliente> occ-exec <subcmd> [args]` em manage-cli, consumindo `occ_run` (D3.1). Sync only (sem --async). Timeout 60s. Allowlist + blocklist + client-lock obrigatorio para verbs mutaveis.
- **Componentes**: `manage.sh` (cmd_occ_exec), `lib/occ_bridge.sh` (occ_run), `lib/job_queue.sh` (client_lock_*), `lib/output_json.sh` (sanitization).
- **Riscos**:
  - (R-1) Drift entre allowlist em occ_bridge.sh e CONTRACTS §3.10.1 — mitigar via gate CI (ja existe; D1.3 valida)
  - (R-2) Concurrencia com worker async no mesmo cliente — client-lock + exit 17
  - (R-3) Argv injection ja mitigado em D2.5 (shim) + D3.1 (occ_run array argv)

### Quality Brief (Sprint D4)

**Quality Constraints**:
1. cmd_occ_exec REJEITA --async com exit 5 async_not_supported.
2. cmd_occ_exec NUNCA aceita senha em argv — exigir --payload-stdin para subcmds que precisam (user:add, user:resetpassword).
3. client_lock_acquire ANTES de occ_run mutavel; release no defer.
4. Audit log via audit_occ NDJSON.
5. Branding inline ≤256KB via --payload-stdin; >256KB exige --staging-id.

**Technical Advisory**:
- Para subcmds em OCC_JSON_CAPABLE, parsed_result preenchido.
- emit_json escolhe schema OccExecResult conforme CONTRACTS §4.9.

- **Arquivo(s)**: scripts/manage.sh (cmd_occ_exec); tests/integration/test_occ_exec.bats
- **Decisoes**:
  - cmd_occ_exec assinatura: `nextcloud-manage <cliente> occ-exec <subcmd> [<arg>...] [--json] [--payload-stdin] [--staging-id=<uuid>]`
  - --payload-stdin payload: `{"password": "...", "branding": {...}}` (depende do subcmd)
  - Exit codes especificos: 14 (instance_not_running), 15 (occ_timeout), 16 (occ_command_failed), 17 (client_busy_async_job_running), 100 (occ_command_not_allowed)
- **Edge cases**:
  - --async passado → exit 5
  - subcmd em OCC_BLOCKLIST → exit 100
  - container parado → exit 14
  - timeout 60s → exit 15
  - worker tem job running no mesmo client → exit 17
- **Anti-patterns**: aceitar --async (e mutuamente exclusivo); skip client-lock; logar payload bruto
- **Cenarios de teste** (Budget: 12 testes):
  - occ-exec user:list → parsed_result com array de users
  - occ-exec user:add com --payload-stdin → senha nao aparece em journald
  - occ-exec encryption:decrypt-all → exit 100 (blocklist)
  - occ-exec --async maintenance:mode → exit 5 (sync only)
  - occ-exec maintenance:mode --on com worker rodando job em mesmo client → exit 17
  - occ-exec timeout (mock OCC com sleep 70s, timeout 60s) → exit 15
  - occ-exec OCC retorna exit 1 → exit 16 + stdout/stderr preservados
  - occ-exec parsed_result null para subcmd nao json-capable
  - occ-exec branding inline ≤256KB ok
  - occ-exec branding inline >256KB → exit 5 (use --staging-id)
  - occ-exec branding via --staging-id ok
  - audit_occ chamado em todo invoke
- **Budget**: 12 testes
- **References**: `docs/REQUIREMENTS.md Feature P`, `docs/CONTRACTS.md §3.10 + §4.9 OccExecResult`
- **Seguranca**: ja coberta por D2.5 (shim) + D3.1 (occ_run); aqui apenas garantir wiring correto.
- **Criterio de aceite**:
  - bats verde com 12 testes
  - shellcheck warning-clean
  - smoke real em staging: `ssh ncsaas-api@host nextcloud-manage acme occ-exec user:list --json` retorna parsed_result com lista de users em <5s
- **executor_prompt**: |
    ### Quality Brief (Sprint D4)

    **Quality Constraints**:
    1. cmd_occ_exec rejeita --async (exit 5).
    2. Senha NUNCA argv; --payload-stdin para subcmds que precisam.
    3. client_lock antes de occ_run mutavel; release no defer.
    4. audit_occ em todo invoke.
    5. Branding ≤256KB inline; >256KB exige --staging-id.

    ---

    Implementar cmd_occ_exec em manage.sh.

    ```
    cmd_occ_exec() {
      local client="$1" subcmd="$2"; shift 2

      [[ "${PARSED_FLAGS[async]:-0}" -eq 0 ]] || { emit_error async_not_supported; exit 5; }
      is_valid_client_name "$client" || { emit_error invalid_client; exit 5; }

      local args=("$@")
      local stdin_payload=""
      if [[ "${PARSED_FLAGS[payload_stdin]:-0}" -eq 1 ]]; then
        stdin_payload=$(cat)
        # Validar JSON
        echo "$stdin_payload" | jq -e . >/dev/null || { emit_error invalid_payload; exit 5; }
      fi

      # Branding via staging-id
      if [[ -n "${PARSED_FLAGS[staging_id]:-}" ]]; then
        local sid="${PARSED_FLAGS[staging_id]}"
        is_valid_uuid_v4 "$sid" || { emit_error invalid_staging_id; exit 5; }
        # Validar inbox existe
        [[ -d "/opt/nextcloud-customers/inbox/$sid" ]] || { emit_error staging_not_found; exit 19; }
        # Mover para staging consolidado para o exec
        # (operacao em-memoria; cleanup pelo GC)
      fi

      # Senha do payload via env (consumido por occ_run)
      if jq -e '.password' >/dev/null 2>&1 <<<"$stdin_payload"; then
        export NEXTCLOUD_USER_PASSWORD=$(jq -r .password <<<"$stdin_payload")
      fi

      # client_lock para verbs mutaveis (occ_run ja faz por baixo, mas ja podemos pegar aqui)
      audit_occ "$client" "$subcmd" attempt args "${args[*]}"

      occ_run "$client" "$subcmd" "${args[@]}"
      local rc=$?

      unset NEXTCLOUD_USER_PASSWORD
      return $rc
    }
    ```

    Tests (12) em `tests/integration/test_occ_exec.bats` cobrindo cenarios.

    `critica: true` — Best-of-N: 2 implementadores; selecao pelo melhor coverage de blocklist + concurrency.
</details>

<details>
<summary>4.2 — client-lock wiring</summary>

- **Arquivo(s)**: integrar `client_lock_*` (D1.7) em `worker.sh` (process_job — ja em D2.3) e em `lib/occ_bridge.sh::occ_run` (ja em D3.1); tests `tests/integration/test_client_lock.bats`
- **Abordagem**: garantir que worker pega client_lock antes de exec mutavel; manage-cli (cmd_occ_exec) tambem pega antes de occ_run mutavel. Ambos usam `client_lock_acquire <client> 5; trap "client_lock_release $client" RETURN`.
- **Cenarios de teste** (Budget: 6 testes):
  - worker pega lock; outro processo tenta `client_lock_acquire <c> 5` → falha
  - worker libera lock no fim do job
  - manage-cli cmd_occ_exec maintenance:mode com worker rodando job em mesmo client → exit 17
  - lock TTL renovado durante job longo (mock 30s+ com heartbeat)
  - 2 clientes diferentes: locks independentes (acme + foo paralelos ok)
  - SIGTERM no worker libera lock antes de morrer
- **Budget**: 6 testes
- **Criterio de aceite**: bats verde
- **executor_prompt**: |
    Wiring de client_lock em 2 pontos:

    1. `scripts/worker.sh::process_job` (ja chamado em D2.3 — validar):
       ```
       client_lock_acquire "$client" 5
       trap "client_lock_release '$client'" RETURN
       ```

    2. `scripts/lib/occ_bridge.sh::occ_run` (ja em D3.1 — validar):
       ```
       if occ_is_state_changing "$subcmd"; then
         client_lock_acquire "$client" 60 || { emit_error client_busy_async_job_running; return 17; }
         trap "client_lock_release '$client'" RETURN
       fi
       ```

    Heartbeat para locks de longa duracao (worker job >5s):
    ```
    start_client_lock_heartbeat() {
      local client="$1"
      while :; do
        client_lock_renew "$client" 2>/dev/null || break
        sleep 2
      done &
      echo $!
    }
    ```

    Tests (6) em `tests/integration/test_client_lock.bats`.
</details>

<details>
<summary>4.3 — health-command (8 checks paralelos)</summary>

- **Arquivo(s)**: `scripts/manage.sh` (cmd_health), `scripts/lib/health_checks.sh` (NOVO — 8 funcoes); tests `tests/integration/test_health.bats`
- **Abordagem**: cmd_health roda 8 funcoes em background (`&`) com `timeout 5s` cada; espera `wait`; agrega resultados. Total <10s mesmo no worst case.
- **Funcoes em lib/health_checks.sh**:
  - `check_shared_containers` — `docker compose -f shared-services/docker-compose.yml ps --format json | jq` valida 8 services up
  - `check_traefik_certs` — para cada cliente em /opt/.../* / domain do compose, verificar cert validade >7 dias via openssl s_client
  - `check_dns_fixed_domains` — `dig +short` em $COLLABORA_DOMAIN, $SIGNALING_DOMAIN, $TURN_DOMAIN
  - `check_recording_welcome` — `curl -fsS --max-time 4 http://127.0.0.1:1234/api/v1/welcome` retorna 200
  - `check_harp_socket_proxy` — verificar `<c>-harp` consegue chegar em `tcp://socket-proxy:2375` (apos 4.4)
  - `check_disk` — `df /opt | awk 'NR==2 {print $5}'` <85% = ok, <95% = warn, ≥95% = fail
  - `check_redis_queue` — `redis-cli ping` retorna PONG; LLEN nc:jobs:queue <1000 = ok, <5000 = warn, ≥5000 = fail
  - `check_worker_active` — `systemctl is-active nextcloud-saas-worker` retorna `active`; current_job presente em `nc:worker:current` por <2h
- **Decisoes**: cada check retorna JSON `{name, status: ok|warn|fail, message, duration_ms}`. cmd_health agrega em payload final com `summary: {ok, warn, fail}`. Exit code: 0 (todos ok), 1 (warning), 2 (fail).
- **Cenarios de teste** (Budget: 10 testes):
  - cmd_health JSON valido
  - Todos checks ok → summary {ok:8, warn:0, fail:0}
  - check_disk warn (mock df 90%) → summary {ok:7, warn:1, fail:0}; exit 1
  - check_redis_queue fail (redis down) → summary {fail:1}; exit 2
  - cmd_health <10s wallclock mesmo com 1 check timeout
  - cmd_health --json output valida em jq
  - duration_ms presente em cada check
  - Container shared down (mock) → check_shared_containers fail
  - Cert expirando em <7d → check_traefik_certs warn
  - Worker stuck (current_job preenchido por >2h) → check_worker_active warn
- **Budget**: 10 testes
- **References**: `docs/REQUIREMENTS.md Feature C`
- **Performance**: <10s wallclock garantido por timeout duro de 5s em cada check + execucao paralela.
- **Criterio de aceite**: bats verde + smoke real em staging
- **executor_prompt**: |
    Criar `scripts/lib/health_checks.sh` com 8 funcoes + cmd_health em manage.sh.

    Cada check:
    ```
    check_<name>() {
      local start_ms=$(date +%s%3N)
      local status="ok" message=""
      # ... logica ...
      local duration_ms=$(( $(date +%s%3N) - start_ms ))
      jq -nc --arg n "<name>" --arg s "$status" --arg m "$message" --argjson d "$duration_ms" \
        '{name:$n, status:$s, message:$m, duration_ms:$d}'
    }
    ```

    cmd_health:
    ```
    cmd_health() {
      local results=()
      for fn in check_shared_containers check_traefik_certs check_dns_fixed_domains \
                check_recording_welcome check_harp_socket_proxy check_disk \
                check_redis_queue check_worker_active; do
        timeout 5s bash -c "source $LIB_DIR/health_checks.sh; $fn" &
      done
      wait
      # Coletar resultados via temp files (mais simples que array)
      ...
      # Agregar
      local ok=0 warn=0 fail=0
      for r in "${results[@]}"; do
        case "$(jq -r .status <<<"$r")" in
          ok) ok=$((ok+1)) ;;
          warn) warn=$((warn+1)) ;;
          fail) fail=$((fail+1)) ;;
        esac
      done
      local exit_code=0
      [[ "$warn" -gt 0 ]] && exit_code=1
      [[ "$fail" -gt 0 ]] && exit_code=2
      emit_json schema_version "1" \
        checks "@json:[$(IFS=,; echo "${results[*]}")]" \
        summary "@json:{\"ok\":$ok,\"warn\":$warn,\"fail\":$fail}"
      exit "$exit_code"
    }
    ```

    Tests (10) em `tests/integration/test_health.bats`. Mock docker/dig/openssl/redis-cli/systemctl/curl via wrappers.
</details>

<details>
<summary>4.4 — socket-proxy migrado</summary>

- **Arquivo(s)**: `shared-services/docker-compose.yml` (adicionar service); `scripts/manage.sh::cmd_create` (template HaRP); `scripts/manage.sh::cmd_upgrade_harp` (NOVO); tests `tests/integration/test_socket_proxy.bats`
- **Abordagem**:
  - service socket-proxy ja em ARCHITECTURE Apêndice A.8; adicionar no docker-compose.yml com env vars do shared-services/socket-proxy/.env.example
  - cmd_create: template do compose por cliente passa a usar `tcp://socket-proxy:2375` no lugar de `/var/run/docker.sock` para o `<c>-harp`
  - cmd_upgrade_harp <cliente>: regenera compose do cliente (preservando .env e secrets) + docker compose down/up para HaRP somente; smoke test ExApp install
- **Cenarios de teste** (Budget: 8 testes):
  - shared-services compose com socket-proxy: docker compose up sem erro
  - socket-proxy responde a /ping na rede shared (mock)
  - Allowlist: POST /containers/create OK; POST /containers/<id>/exec → 403 (EXEC=0)
  - cmd_create gera compose com socket-proxy:2375 em harp
  - cmd_create NAO monta /var/run/docker.sock em harp
  - cmd_upgrade_harp: regenera compose; restart so HaRP; mantem volumes
  - cmd_upgrade_harp idempotente (rodar 2x ok)
  - Smoke ExApp install via socket-proxy (mock dispatcher) ok
- **Budget**: 8 testes
- **References**: `docs/ARCHITECTURE.md ADR-007 + Apêndice A.8`
- **Seguranca**: vetor #2 do §7.3.
- **Criterio de aceite**: bats verde + smoke ExApp install em staging
- **executor_prompt**: |
    1. Adicionar service socket-proxy em `shared-services/docker-compose.yml`:
    ```
    socket-proxy:
      image: tecnativa/docker-socket-proxy:0.3.0
      restart: always
      privileged: true
      env_file: shared-services/socket-proxy/.env
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock:ro
      networks:
        - shared
    ```

    2. setup-shared.sh: copy `.env.example` para `.env` se nao existir.

    3. cmd_create: alterar template HaRP do cliente:
       Antes:
       ```
       <c>-harp:
         volumes:
           - /var/run/docker.sock:/var/run/docker.sock
       ```
       Depois:
       ```
       <c>-harp:
         environment:
           DOCKER_HOST: tcp://socket-proxy:2375
         networks:
           - shared
           - <c>-net
       ```

    4. cmd_upgrade_harp:
    ```
    cmd_upgrade_harp() {
      local client="$1"
      local compose_file="/opt/nextcloud-customers/$client/docker-compose.yml"
      [[ -f "$compose_file" ]] || { emit_error client_not_found; exit 14; }

      regenerate_harp_block "$compose_file"
      docker compose -f "$compose_file" up -d --no-deps "$client-harp"

      # smoke: HaRP consegue alcancar socket-proxy?
      sleep 3
      if docker exec "$client-harp" curl -fsS http://socket-proxy:2375/_ping >/dev/null 2>&1; then
        emit_json schema_version "1" client "$client" upgraded "@bool:true"
      else
        emit_error harp_upgrade_failed
        exit 1
      fi
    }
    ```

    Tests (8) em `tests/integration/test_socket_proxy.bats`.
</details>

<details>
<summary>4.5 — secrets-file</summary>

- **Arquivo(s)**: `shared-services/setup-shared.sh` (extensao para criar /opt/.../secrets/*); `shared-services/docker-compose.yml` (refatorar para usar secrets:); tests `tests/integration/test_secrets_file.bats`
- **Abordagem**:
  - setup-shared.sh: cria `/opt/shared-services/secrets/` (0700 root); por secret: gerar via `openssl rand -base64 32` se nao existir; chmod 0600.
  - 7 secrets: `db_root_password`, `redis_password`, `collabora_admin_password`, `signaling_secret`, `signaling_hash_key`, `signaling_block_key`, `signaling_internal_secret`, `recording_secret`, `turn_secret`, `worker_callback_secret`
  - docker-compose.yml: para imagens com `_FILE` (raras — MariaDB sim) usar `secrets:` nativo; para demais, runtime export em setup-shared.sh:
    ```
    export REDIS_PASSWORD=$(< /opt/shared-services/secrets/redis_password)
    export COLLABORA_ADMIN_PASSWORD=$(< /opt/shared-services/secrets/collabora_admin_password)
    ...
    docker compose up -d
    ```
- **Decisoes**: secrets sao geradas uma vez e persistidas; restore exige preservar /opt/shared-services/secrets/.
- **Cenarios de teste** (Budget: 6 testes):
  - setup novo: secrets/ criado com 0700; arquivos com 0600
  - setup re-rodado: secrets preservados (nao regenerados)
  - MariaDB usa _FILE: secret montado em /run/secrets/db_root_password
  - Collabora env literal: senha exportada em runtime; nao persistida em .env
  - .env final nao contem senha em plaintext (validar via grep)
  - worker_callback_secret presente; lido pelo systemd LoadCredential
- **Budget**: 6 testes
- **References**: `docs/ARCHITECTURE.md ADR-008`
- **Criterio de aceite**: bats verde + smoke staging com containers up
- **executor_prompt**: |
    Estender `shared-services/setup-shared.sh`:

    ```
    setup_secrets() {
      install -d -m 0700 -o root -g root /opt/shared-services/secrets

      local secrets=(db_root_password redis_password collabora_admin_password \
                     signaling_secret signaling_hash_key signaling_block_key \
                     signaling_internal_secret recording_secret turn_secret \
                     worker_callback_secret)

      for s in "${secrets[@]}"; do
        local path="/opt/shared-services/secrets/$s"
        if [[ ! -f "$path" ]]; then
          openssl rand -base64 32 | tr -d '\n=' | head -c 48 > "$path"
          chmod 0600 "$path"
          chown root:root "$path"
          log "Generated secret: $s"
        fi
      done
    }

    export_secrets_runtime() {
      export DB_ROOT_PASSWORD=$(< /opt/shared-services/secrets/db_root_password)
      export REDIS_PASSWORD=$(< /opt/shared-services/secrets/redis_password)
      export COLLABORA_ADMIN_PASSWORD=$(< /opt/shared-services/secrets/collabora_admin_password)
      export SIGNALING_SECRET=$(< /opt/shared-services/secrets/signaling_secret)
      ...
    }

    main() {
      setup_secrets
      export_secrets_runtime
      docker compose -f shared-services/docker-compose.yml up -d
    }
    ```

    Editar `shared-services/docker-compose.yml`:
    - Adicionar `secrets:` block para servicos que suportam `_FILE` (apenas MariaDB usa).
    - Outros servicos continuam com `environment: REDIS_PASSWORD: ${REDIS_PASSWORD}` (env var injetada no runtime).
    - Remover qualquer senha em plaintext do .env (deixar como `${VAR}`).

    Tests (6) em `tests/integration/test_secrets_file.bats`.
</details>

<details>
<summary>4.7 — Tests integration occ-exec + client-lock + health</summary>

- **Arquivo(s)**: `tests/integration/test_d4_e2e.bats`
- **Cenarios de teste** (Budget: 8 testes e2e):
  - occ-exec user:list via SSH → parsed_result OK
  - occ-exec maintenance:mode --on com worker rodando job no mesmo client → exit 17
  - occ-exec encryption:decrypt-all → exit 100
  - health 8 checks paralelos retorna em <10s; summary correto
  - socket-proxy interposto: HaRP em cliente novo usa tcp://socket-proxy:2375; smoke ExApp install
  - upgrade-harp em cliente legado: HaRP migra; ExApp install ok
  - secrets-file: container up sem senha em .env plaintext (grep .env retorna 0)
  - audit_occ: cada invoke em journald NDJSON valido
- **Budget**: 8 testes
- **Criterio de aceite**: bats verde
- **executor_prompt**: |
    Suite e2e `tests/integration/test_d4_e2e.bats` cobrindo Feature P + hardening completo.

    Setup elaborado: redis fixture + worker em background + container nextcloud mockado + container socket-proxy mockado.

    Cobrir cenarios da nota tecnica.
</details>

---

## Sprint D5 — Estabilizacao + Polish + Deploy v12.0
> Categoria: D
> Gate: E2E `tests/e2e/test_create_backup_remove.bats` em docker-in-docker passa em CI; auditorias verde (senior code review + QA full + DBA + performance + seguranca); ADRs ARCH-001..ARCH-008 + ADR-009..ADR-013 registradas em DECISION-BRIEF.md; deploy em staging Tier 1 conforme INFRASTRUCTURE.md validado; CHANGELOG v12.0 publicado; tag git `v12.0` criada.
> review: comprehensive

| Status | Tamanho | Tarefa | Skill/Command | Depende de |
|--------|---------|--------|---------------|------------|
| [x] | P | 5.1 — Registrar ADRs ARCH-001..ARCH-008 + ADR-009..ADR-013 em `docs/DECISION-BRIEF.md` via capability `decision-brief` | `~/.cursor/skills/capabilities/decision-brief.md` | D1..D4 |
| [x] | M | 5.2 — Atualizar `README.md` v12.0 (modo assincrono, Feature O/P, hardening, contratos, indice de docs) | `bash` (manual edit) | D1..D4 |
| [x] | M | 5.3 — E2E `tests/e2e/test_create_backup_remove.bats` (docker-in-docker; create + backup + remove com Bats; CI bats.yml job e2e) | `bats` + `docker-in-docker` | D1..D4 |
| [x] | P | 5.4 — Auditoria QA full: cenarios idempotency, callback HMAC, LGPD scrub, allowlist OCC, SCP staging jail, client-lock concurrency | `~/.cursor/skills/auditoria-qa/` | 5.3 |
| [x] | P | 5.5 — Auditoria de seguranca: R-O-1..R-O-7 mitigated; vetores top-3 §7.3; SSH key rotation procedure documentado | `~/.cursor/skills/auditoria-seguranca/` | 5.3 |
| [x] | P | 5.6 — Auditoria DBA: Redis schema canônico em CONTRACTS §6 implementado; AOF habilitado; retencao 7d/30d/24h corretas; SCAN sem KEYS | `~/.cursor/skills/auditoria-dba/` | 5.3 |
| [x] | P | 5.7 — Auditoria performance: latencia <2s async; health <10s; status sync <3s; throughput ~10 jobs longos/h verificado | `~/.cursor/skills/auditoria-performance/` | 5.3 |
| [x] | P | 5.8 — Auditoria senior: code review final do diff v11.3.4 → v12.0; identificar techincal debt residual para v12.1 | `~/.cursor/skills/auditoria-senior/` | 5.3 |
| [x] | P | 5.9 — Deploy staging Tier 1 (Proxmox single-node conforme INFRASTRUCTURE.md): provisionar VM Ubuntu 24.04, rodar deploy-server.sh, smoke F01-F10 + Feature N/O/P, validar 1 cliente piloto | `bash` + `proxmox` | 5.3..5.8 |
| [x] | P | 5.10 — Tag git `v12.0` + publicar `CHANGELOG.md` v12.0 (resumo de Features + breaking changes + migrations) | `bash` + `git tag` | 5.9 |

**Notas tecnicas (tarefas M):**

<details>
<summary>5.2 — Atualizar README.md v12.0</summary>

- **Arquivo(s)**: `README.md` (reescrita parcial)
- **Abordagem**: manter estrutura atual (~620 linhas em v11.3.4); adicionar 4 novas secoes:
  1. "Modo assincrono e API REST consumidora" — exemplo SSH + JSON + idempotency-key + callback
  2. "Lifecycle de users/groups/apps (Feature O)" — exemplos com SCP staging
  3. "OCC sync passthrough (Feature P)" — exemplos
  4. "Hardening v12.0" — socket-proxy + secrets + health
- **Decisoes**: indice de docs no topo (link para REQUIREMENTS, ARCHITECTURE, CONTRACTS, INFRASTRUCTURE, ADMINISTRATION, TROUBLESHOOTING).
- **Cenarios de teste** (Budget: 0 — texto): nao aplicavel; revisao manual via auditoria.
- **Criterio de aceite**: revisao senior em 5.8 marca approve
- **executor_prompt**: |
    Atualizar `README.md` para v12.0.

    Manter sections existentes; adicionar 4 sections antes de "Troubleshooting":
    1. "## Modo assincrono e API REST consumidora" — exemplos com nextcloud-manage --async --json --idempotency-key=<uuid> --callback=https://...
    2. "## Lifecycle de users/groups/apps (Feature O)" — exemplos
    3. "## OCC sync passthrough (Feature P)" — exemplos
    4. "## Hardening v12.0" — socket-proxy + secrets

    Topo: indice de docs (links para REQUIREMENTS, ARCHITECTURE, CONTRACTS, INFRASTRUCTURE, ADMINISTRATION, TROUBLESHOOTING, ROADMAP).
</details>

<details>
<summary>5.3 — E2E docker-in-docker</summary>

- **Arquivo(s)**: `tests/e2e/test_create_backup_remove.bats`; `.github/workflows/bats.yml` (job e2e novo)
- **Abordagem**: usa Bats em GitHub Actions com `services: { docker: docker:24.0-dind }`; sobe um Nextcloud minimo via setup-shared.sh; cria 1 cliente; faz backup; remove. Total <8 min.
- **Cenarios de teste** (Budget: 4 testes e2e):
  - deploy-server.sh smoke: roda em VM clean, cria estrutura
  - cmd_create acme nextcloud.acme.local: instancia sobe; status retorna ok
  - cmd_backup acme: tar.gz gerado em /opt/nextcloud-customers/backups/
  - cmd_remove acme: instancia removida; database dropped
- **Budget**: 4 testes
- **References**: `docs/REQUIREMENTS.md Feature A NFR (cobertura E2E)`
- **Criterio de aceite**: bats e2e job verde no CI; <8 min duracao
- **executor_prompt**: |
    Criar `tests/e2e/test_create_backup_remove.bats`:

    Setup elaborado em docker-in-docker:
    ```
    setup_file() {
      # Sobe stack shared-services
      cd /opt/nextcloud-customers
      bash scripts/deploy-server.sh --email test@example.com --collabora-domain collabora.local --signaling-domain signaling.local --turn-domain turn.local
      # Aguarda containers up
      sleep 30
      docker compose -f shared-services/docker-compose.yml ps | grep -c "Up" | grep -q 8
    }

    @test "create acme" {
      run sudo nextcloud-manage acme nextcloud.acme.local create
      [ "$status" -eq 0 ]
    }

    @test "status acme" {
      run sudo nextcloud-manage acme _ status
      [ "$status" -eq 0 ]
      [[ "$output" == *"running"* ]]
    }

    @test "backup acme" {
      run sudo nextcloud-manage acme _ backup
      [ "$status" -eq 0 ]
      [[ -f /opt/nextcloud-customers/backups/acme-*.tar.gz ]]
    }

    @test "remove acme" {
      run sudo nextcloud-manage acme _ remove --confirm=acme
      [ "$status" -eq 0 ]
      [[ ! -d /opt/nextcloud-customers/acme ]]
    }
    ```

    Em `.github/workflows/bats.yml` adicionar job:
    ```
    e2e:
      runs-on: ubuntu-24.04
      timeout-minutes: 10
      services:
        docker:
          image: docker:24.0-dind
          options: --privileged
      steps:
        - uses: actions/checkout@v4
        - run: sudo apt-get install -y bats
        - run: sudo bats tests/e2e/
    ```
</details>

---

## Caminho Critico

A sequencia mais longa de dependencias que define o menor caminho em numero de tasks (e ordem obrigatoria):

```
D1.5 (validators.sh) → D1.7 (job_queue.sh) → D1.8 (job_runner.sh) → D1.10 (manage.sh refactor)
→ D2.1 (manage-cli flags + dispatch) → D2.3 (worker.sh) → D3.1 (occ_bridge occ_run)
→ D3.3 (user-create) → D4.1 (occ-exec public) → D4.4 (socket-proxy) → D5.3 (E2E) → D5.9 (deploy staging)

Total: 12 tarefas sequenciais
```

**Atencao**: atrasos no caminho critico atrasam o projeto inteiro.

**Tarefas paralelizaveis** em qualquer ordem dentro da mesma sprint:
- D1.6 (output_json), D1.9 (ssh_audit), D1.11 (deploy-server deps) — paralelas a D1.7/D1.8
- D2.5 (ssh-gateway), D2.4 (systemd install), D2.6 (observability wiring) — paralelas a D2.3
- D2.7 (worker status), D2.8 (job <id>), D2.9 (worker stats) — paralelas apos D2.1
- D3.2 (inbox-staging), D3.5 (create estendido), D3.6 (remove estendido), D3.4 (group/apps) — paralelas a D3.3
- D4.2 (client-lock wiring), D4.3 (health), D4.5 (secrets-file), D4.6 (journald) — paralelas a D4.1/D4.4
- D5.1 (ADRs), D5.2 (README), D5.4..D5.8 (auditorias) — paralelas

---

## Tech Debt Budget

> Verificacao do orcamento de divida tecnica (ver `~/.cursor/skills/pmo/references/tech-debt-budget.md`).

Roadmap atual: 5 sprints D + 0 sprint dedicada exclusivamente a debt.

**Avaliacao**: a regra ideal e "1 em 4 sprints dedicada a debt"; com 5 sprints D-puras isso seria 1.25 ja em v12.0. **Mitigacao adotada**:

- Sprint D5 inclui auditorias completas (5.4..5.8) que **identificam** technical debt residual para v12.1.
- Sprint D1 ja é foundation com `manage-cli` refactor (extracao de `lib/*`) — divida estrutural sendo paga upfront.
- Findings de tipo manutencao serao consolidados em **Sprint N1** (post-v12.0) via `/pmo new`.
- R-O-1..R-O-7 (catalogados em REQUIREMENTS §12) ficam mitigados em D2-D4; sem debt residual significativo.

**Recomendacao**: apos v12.0 publicada, rodar `/pmo new` para Sprint N1 com tema "Tech debt residual + observability avanced" (Loki/Prometheus, Feature F).

---

## Proximos Passos

Apos aprovacao deste roadmap:

1. Comecar pela **Sprint D1** (tarefas raiz: 1.1, 1.2, 1.3, 1.4, 1.11 podem comecar imediatamente em paralelo).
2. Em **autopilot mode**: rodar `/jarvis pipeline` ou `/sprint-all` para executar D1 → D5 sequencialmente.
3. Auditorias entre sprints sao automaticas (review levels definidos).
4. Apos D5 (v12.0 deployed): rodar `/pmo new` para Sprint N1 (tech debt residual + Feature E backup off-site se priorizada).
5. Rodar `/pmo sprint D1` para iniciar.

---

## Riscos e Mitigation por Sprint

| Sprint | Risco principal | Mitigation no roadmap |
|--------|-----------------|------------------------|
| D1 | Regressao de comportamento legado (F01-F10) durante refactor | Smoke test integration em D1.10 baseline antes da refactor + diff funcional |
| D2 | Worker daemon instavel (crash, deadlock, OOM) | systemd Restart=on-failure + WatchdogSec=120 + cleanup_orphan_jobs no startup + lock duplo + tests integration |
| D3 | Senha vaza em journald/log/callback (LGPD breach) | --payload-stdin obrigatorio + scrub regex em output_json::log_event + secret separado em nc:jobs:<jid>:secret TTL 300s + audit em test (grep retorna 0 linhas) |
| D4 | OCC allowlist drift entre codigo e contrato | contracts-check.yml CI gate (D1.3) bloqueia PR; smoke ExApp install em socket-proxy via CI |
| D5 | Deploy staging quebra com config dependente | INFRASTRUCTURE.md ja tem checklist Proxmox 4 fases; smoke F01-F10 + N + O + P em ordem antes de tag |

---

## Mapping para .cursorsession.modulos

| Modulo (.cursorsession) | Sprint(s) | Status apos roadmap |
|-------------------------|-----------|----------------------|
| tests-bats | D1 | concluido apos D1 |
| ci-shellcheck | D1 | concluido apos D1 (validacao) |
| manage-cli | D1+D2 | concluido apos D2 |
| idempotency | D2 | concluido apos D2 |
| worker | D2 | concluido apos D2 |
| ssh-gateway | D2 | concluido apos D2 |
| observability | D2 | concluido apos D2 |
| inbox-staging | D3 | concluido apos D3 |
| user-group-apps | D3 | concluido apos D3 |
| occ-bridge | D3 (Parte 1) + D4 (Parte 2) | concluido apos D4 |
| queue-introspection | D2 | concluido apos D2 |
| client-lock | D4 | concluido apos D4 |
| health-command | D4 | concluido apos D4 |
| socket-proxy | D4 | concluido apos D4 |
| secrets-file | D4 | concluido apos D4 |

---

## Historico

| Data | Versao | Alteracao | Autor |
|------|--------|-----------|-------|
| 2026-05-07 | 0.1 | Versao inicial — 5 sprints D risk-first; 48 tarefas; 4 critical (Best-of-N); autopilot mode com auditoria entre sprints; gate executavel por sprint; caminho critico de 12 tarefas; ADRs ARCH-001..ARCH-008 + ADR-009..ADR-013 a registrar em D5 | Planejador de Tarefas (IA) via `/pmo plan` |
