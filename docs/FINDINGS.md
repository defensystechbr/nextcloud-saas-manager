# FINDINGS.md — Achados de Auditoria e Dívida Técnica

> Gerado automaticamente pelo pipeline de sprints. Achados HIGH disparam pausa automática.
> Status: OPEN | FIXED | DEFERRED | ACCEPTED

---

## Sprint D1 — Fundação (Tests + CI + Refactor Base)

Auditado em: 2026-05-07 | Auditor: sprint-init pipeline

---

### [F-D1-001] LOW — D1.11: deploy-server.sh não editável por hook de credenciais

- **Arquivo**: `scripts/deploy-server.sh`
- **Descrição**: A tarefa D1.11 (adicionar `redis-tools bats` ao apt install) foi bloqueada pelo hook de segurança `rtk-rewrite.sh` que detecta variáveis de segredo sem aspas no arquivo. O hook está correto — o arquivo contém credenciais inline (e.g., variáveis `DB_ROOT_PASSWORD`, `HARP_SHARED_KEY`) sem proteção adequada.
- **Impacto**: `redis-tools` e `bats` não foram adicionados ao `deploy-server.sh`. Em CI, esses pacotes são instalados via `bats.yml`. Em deploys de servidor, o operador precisará instalá-los manualmente até D2.
- **Plano de correção**: D2 — migrar deploy-server.sh para usar `/opt/shared-services/secrets/*` (task D2 de `secrets-file`), eliminando credenciais inline e permitindo edição normal.
- **Status**: DEFERRED → D2

---

### [F-D1-002] LOW — get_state usa parser awk frágil para HGETALL

- **Arquivo**: `scripts/lib/job_queue.sh::get_state`
- **Descrição**: O parser awk que converte `HGETALL` output para JSON não escapa aspas nos valores. Se um campo do hash contiver `"`, o JSON resultante seria inválido.
- **Impacto**: Baixo em D1 (valores armazenados são IDs, timestamps, nomes de comando — sem aspas). Potencial em D2+ quando `args_json` é armazenado no hash.
- **Plano de correção**: D2 — usar `redis-cli --json` (Redis 7+) ou serializar via `jq` antes de armazenar; ou usar `HGET` por campo individual em vez de `HGETALL`.
- **Status**: DEFERRED → D2

---

### [F-D1-003] INFO — worker_status emite current_job como string "null" em vez de JSON null

- **Arquivo**: `scripts/lib/job_queue.sh::worker_status`
- **Descrição**: Quando `current_job` é vazio, `emit_json` recebe o valor literal `"null"` como string, produzindo `{"current_job":"null"}` em vez de `{"current_job":null}`.
- **Impacto**: Cosmético para D1. Consumidores que diferenciam string "null" de JSON null podem ter comportamento incorreto.
- **Plano de correção**: D2 — usar prefixo `@json:null` quando o campo for vazio: `emit_json current_job "@json:null"`.
- **Status**: DEFERRED → D2

---

### [F-D1-004] INFO — manage.sh > 500 LOC (refactor parcial)

- **Arquivo**: `scripts/manage.sh`
- **Descrição**: Após o refactor D1.10, `manage.sh` ainda está acima do target de ≤500 LOC porque os `cmd_*` foram mantidos intactos conforme spec. O critério "sem contar comentários" reduz substancialmente a contagem real de código executável.
- **Impacto**: Nenhum — comportamento preservado; ≤500 LOC de código executável é aproximado. cmd_create sozinho tem ~80 LOC de código.
- **Status**: ACCEPTED (spec autoriza manter cmd_* em manage.sh para D2 refactor)

---

### [F-D1-005] INFO — validators.sh: set -euo pipefail afeta caller ao ser sourcado

- **Arquivo**: `scripts/lib/validators.sh`
- **Descrição**: `set -euo pipefail` no topo do arquivo afeta o shell caller quando sourcado. O spec indica esse comportamento como intencional ("para chamadas diretas em testes"), mas pode ter efeitos colaterais em callers que não esperem strict mode.
- **Impacto**: manage.sh já usa `set -euo pipefail`, então para o fluxo principal não há impacto. Outros callers devem estar cientes.
- **Status**: ACCEPTED (spec deliberado; monitrar em D2 quando mais callers forem adicionados)

---

## Resumo D1

| Severidade | Count | Status |
|-----------|-------|--------|
| CRITICAL  | 0     | —      |
| HIGH      | 0     | —      |
| MEDIUM    | 0     | —      |
| LOW       | 2     | DEFERRED D2 |
| INFO      | 3     | ACCEPTED/DEFERRED |

**Conclusão**: Sprint D1 APROVADA para merge. Sem bloqueadores. 2 Low + 3 Info deferidos para D2.

---

## Sprint D2 — Async Core (Queue + Worker + SSH + Observabilidade)

Validado em: 2026-05-08 | Validador: `/qa validar`

---

### [F-D2-001] CRITICAL — `manage.sh` e `worker.sh` falham no startup por sobrescrita de `SCRIPT_DIR`

- **Arquivo**: `scripts/manage.sh`, `scripts/worker.sh`, `scripts/lib/job_queue.sh`
- **Descrição**: `manage.sh` e `worker.sh` calculam `SCRIPT_DIR` apontando para `scripts/`, mas ao fazer `source scripts/lib/job_queue.sh`, esse arquivo redefine a variável global `SCRIPT_DIR` para `scripts/lib`. O próximo `source "${SCRIPT_DIR}/lib/job_runner.sh"` passa a resolver `scripts/lib/lib/job_runner.sh`, que não existe.
- **Evidência**: `MANAGE_SKIP_ROOT_CHECK=1 bash scripts/manage.sh help` e `WORKER_TEST_MODE=1 bash scripts/worker.sh` retornam exit 1 com `scripts/lib/lib/job_runner.sh: Arquivo ou diretório inexistente`.
- **Impacto**: Quebra o gate D2 inteiro: CLI não inicia, worker daemon não inicia, SSH shim não consegue invocar `nextcloud-manage`, `worker status`/`job status` não funcionam.
- **Status**: FIXED — 2026-05-08 (`MANAGE_SCRIPT_DIR`/`WORKER_SCRIPT_DIR` + variáveis de lib isoladas; `manage.sh help` e `WORKER_TEST_MODE=1 worker.sh` retornam exit 0)

---

### [F-D2-002] CRITICAL — `get_state` gera JSON inválido para jobs async reais com `args_json`

- **Arquivo**: `scripts/lib/job_queue.sh::get_state`
- **Descrição**: `get_state` converte `HGETALL` para JSON via `awk` concatenando `"key":"value"` sem escapar aspas, barras ou quebras de linha. D2 grava `args_json` como array JSON stringificado no hash Redis, por exemplo `["nextcloud-manage","acme",...]`; esse valor quebra o JSON produzido por `get_state` antes do `jq -c .`.
- **Impacto**: `job status`, `job list` e o worker podem falhar ao ler jobs reais enfileirados, violando o gate D2 de job introspection e worker pickup.
- **Status**: FIXED — 2026-05-08 (`get_state` usa `redis-cli --raw` + `jq -Rnc`; simulação com `args_json` e aspas validada via `jq -e`)

---

### [F-D2-003] HIGH — `--password=*` é removido antes da validação de segurança

- **Arquivo**: `scripts/manage.sh`, `scripts/lib/dispatch.sh`
- **Descrição**: `manage.sh` remove argumentos `--*` ao montar `POSITIONAL`; depois chama `dispatch_namespace_cmd`/`dispatch_legacy_cmd` apenas com os posicionais. As checagens `has_password_in_argv` em `dispatch.sh` não recebem `--password=secret`.
- **Impacto**: Viola o Quality Constraint D2: `--password=*` em argv deve retornar exit 5 e orientar `--payload-stdin`. Risco LGPD/secret leakage quando a CLI voltar a iniciar.
- **Status**: FIXED — 2026-05-08 (`parse_global_flags` valida `has_password_in_argv "$@"` antes da extração de posicionais; validação local retorna exit 5)

---

### [F-D2-004] HIGH — `--async --json` mistura evento de audit e `EnqueuedJob` em stdout

- **Arquivo**: `scripts/lib/dispatch.sh::dispatch_enqueue`, `scripts/lib/output_json.sh::log_event`
- **Descrição**: `dispatch_enqueue` chama `log_event notice enqueue ...` antes de `_build_enqueued_job`. `log_event` imprime NDJSON em stdout; `_build_enqueued_job` também imprime o JSON contratual. O consumidor pode receber duas raízes JSON no stdout.
- **Impacto**: Quebra o contrato do gate D2: API REST deve receber um único `EnqueuedJob` JSON em menos de 2s.
- **Status**: FIXED — 2026-05-08 (`dispatch_enqueue` envia `log_event` para stderr; stdout fica reservado ao `EnqueuedJob`)

---

### [F-D2-005] HIGH — Callback pode ser enviado sem HMAC real quando secret está ausente

- **Arquivo**: `scripts/worker.sh::_fire_callback`
- **Descrição**: Se `_read_callback_secret` retorna vazio, `_fire_callback` usa `X-Signature: sha256=unsigned` e envia o POST mesmo assim.
- **Impacto**: Degrada silenciosamente callback autenticado para callback não autenticado, violando o contrato HMAC-SHA256 da Sprint D2.
- **Status**: FIXED — 2026-05-08 (`_fire_callback` falha rápido com `missing_callback_secret`; fallback `sha256=unsigned` removido)

---

### [F-D2-006] HIGH — Testes D2 de idempotência estão incompatíveis com a assinatura atual

- **Arquivo**: `tests/integration/test_job_queue.bats`, `scripts/lib/job_queue.sh::idem_check`
- **Descrição**: `idem_check` agora exige 3 argumentos (`key`, `args_hash`, `job_id`) e retorna `same:<job_id>`, mas `test_job_queue.bats` ainda chama com 2 argumentos e espera `same`.
- **Impacto**: A suíte Bats de integração deve falhar quando executada, bloqueando confiança nos cenários D2.2.
- **Status**: FIXED — 2026-05-08 (`test_job_queue.bats` atualizado para `idem_check <key> <hash> <job_id>` e `same:<job_id>`; adicionada cobertura para `args_json` em `get_state`)

---

### [F-D2-007] HIGH — Ambiente local não consegue executar o gate dinâmico da Sprint D2

- **Arquivo**: ambiente de validação
- **Descrição**: `bats`, `shellcheck` e `redis-cli` não estão no PATH; Docker também não está disponível (`/var/run/docker.sock` ausente). Só foi possível executar `bash -n` e validações estáticas.
- **Impacto**: Não há evidência local de `bats integration verde`, `shellcheck warning-clean`, Redis fixture ou worker/callback end-to-end. A validação dinâmica deve rodar em CI/ambiente provisionado antes de qualquer merge/release.
- **Status**: FIXED — 2026-05-08 (revalidado com Docker daemon disponível fora do sandbox: `timeout 240 npm exec --yes --package bats -- bats --tap --recursive tests/integration` = 96/96 PASS; `make shellcheck` = PASS; `tests/sanity.bats` = 1/1 PASS; `tests/unit` = 50/50 PASS)

---

### [F-D2-008] MEDIUM — `make shellcheck` mascarava ausência do ShellCheck

- **Arquivo**: `Makefile`
- **Descrição**: O alvo `shellcheck` terminava com `|| true`, então retornava sucesso mesmo quando `shellcheck` não existia ou quando houvesse warnings.
- **Impacto**: O gate local de ShellCheck podia dar falso positivo, contrariando o gate D1/D2 de warning-clean.
- **Status**: FIXED — 2026-05-08 (`|| true` removido; `make shellcheck` agora falha com exit 2 quando `shellcheck` está ausente)

---

### [F-D2-009] HIGH — `job list` e `worker stats` travam quando Redis/`redis-cli` está indisponível

- **Arquivo**: `scripts/lib/job_queue.sh::job_list`, `scripts/lib/job_queue.sh::worker_stats`
- **Descrição**: Os loops baseados em `SCAN` não tratam falha ou saída vazia de `_redis_cli SCAN`. Quando Redis/`redis-cli` não responde, o cursor fica vazio e o loop não atinge `0`, deixando comandos de introspecção pendurados até timeout.
- **Evidência**: `timeout 5 bash scripts/manage.sh job list --json` retornou exit 124 sem output; `timeout 5 env MANAGE_SKIP_ROOT_CHECK=1 bash scripts/manage.sh worker stats --json` retornou exit 124 sem output.
- **Impacto**: Bloqueia o gate D2/F1 de introspecção (`job list`, `worker stats`) e pode travar consumidores SSH/API em vez de retornar erro JSON claro quando a fila Redis está indisponível.
- **Status**: FIXED — 2026-05-08 (`job_list` e `worker_stats` validam retorno de `SCAN`; comandos retornam `redis_unavailable` em <5s; `npx --yes bats --tap --recursive tests/unit` = 50/50 PASS).

---

## Resumo D2

| Severidade | Count | Status |
|-----------|-------|--------|
| CRITICAL  | 2     | FIXED |
| HIGH      | 4     | FIXED |
| HIGH      | 1     | FIXED (`F-D2-007`) |
| MEDIUM    | 1     | FIXED |
| LOW       | 0     | — |

**Conclusão inicial**: Sprint D2 REPROVADA. Bloqueadores impediam aprovação: CLI/worker não iniciavam, JSON de job state era inválido para jobs reais, contrato de segurança de senha/callback era violado e a suíte dinâmica não pôde ser executada no ambiente atual.

**Revalidação final 2026-05-08**: F-D2-001..F-D2-009 corrigidos ou revalidados. Evidência do gate: `make shellcheck` PASS; `npm exec --yes --package bats -- bats --tap tests/sanity.bats` = 1/1 PASS; `npm exec --yes --package bats -- bats --tap --recursive tests/unit` = 50/50 PASS; `timeout 240 npm exec --yes --package bats -- bats --tap --recursive tests/integration` com Docker daemon disponível = 96/96 PASS. F-D2-007 fechado com validação dinâmica local usando Redis fixture via Docker.

---

## Sprint D3 — Feature O (Lifecycle de users/groups/apps + SCP staging + occ-bridge P1)

Validado em: 2026-05-08 | Validador: `/qa validar`

---

### [F-D3-001] HIGH — Jobs Feature O pegam client-lock duas vezes antes do OCC

- **Arquivo**: `scripts/worker.sh`, `scripts/lib/occ_bridge.sh`
- **Descrição**: `process_job` adquire `client_lock` para o cliente antes de despachar jobs, mas os handlers Feature O chamam `occ_run`, que tenta adquirir o mesmo lock novamente para verbs OCC mutáveis (`user:add`, `group:add`, `app:enable`, etc.). Como `client_lock_acquire` usa `SET NX`, o segundo acquire falha e `occ_run` retorna `client_busy_async_job_running`/exit 17.
- **Evidência**: `process_job` chama `client_lock_acquire` antes de `worker_exec_feature_o`; `occ_run` chama `client_lock_acquire` novamente quando `occ_is_state_changing "$subcmd"` é verdadeiro.
- **Impacto**: Bloqueia a execução real do lifecycle async entregue pela D3: jobs `user-*`, `group-*` e `apps-*` podem enfileirar corretamente, mas falham no worker antes de executar OCC.
- **Status**: FIXED — 2026-05-08 (`occ_run` reaproveita o `client_lock` mantido pelo worker via `OCC_CLIENT_LOCK_HELD`; cobertura adicionada em `test_occ_bridge.bats`)

---

### [F-D3-002] HIGH — Batch apps tolerante marca sucesso mesmo quando todos os OCC falham

- **Arquivo**: `scripts/worker.sh::worker_exec_apps_enable`, `scripts/worker.sh::worker_exec_apps_disable`
- **Descrição**: Em modo sem `--strict`, os handlers incrementam `failed`, registram warning e sempre retornam `0`. Se todos os apps falharem, `process_job` grava o job como `finished`.
- **Evidência**: Os loops de apps acumulam `failed=$((failed + 1))`, mas o fim das funções executa `return 0` independentemente de `failed == total`.
- **Impacto**: Consumidores recebem job finalizado com sucesso mesmo quando nenhuma aplicação foi habilitada/desabilitada, quebrando a semântica de batch tolerante.
- **Status**: FIXED — 2026-05-08 (`worker_exec_apps_enable/disable` retornam falha quando `failed == total`; cobertura adicionada em `test_feature_o.bats`)

---

### [F-D3-003] HIGH — `user create` aceita job sem payload/senha apesar do contrato

- **Arquivo**: `scripts/lib/feature_o.sh::cmd_user_create`, `tests/integration/test_feature_o.bats`
- **Descrição**: `cmd_user_create` lê payload apenas se `--payload-stdin` estiver setado, mas não exige payload nem senha. A suíte atual valida como sucesso `user create <username> --async --json` sem stdin.
- **Evidência**: `docs/CONTRACTS.md` exige exit 5 `payload_stdin_required` quando `user create` não recebe `--payload-stdin`; o teste `user create: com --async enfileira job user-create` cobre o comportamento oposto.
- **Impacto**: A CLI aceita operação inválida, enfileira job sem senha efêmera e empurra a falha para runtime/OCC, contrariando o gate D3 de senha via stdin.
- **Status**: FIXED — 2026-05-08 (`cmd_user_create` exige `--payload-stdin` e password no payload; testes atualizados para contrato D3)

---

## Resumo D3

| Severidade | Count | Status |
|-----------|-------|--------|
| CRITICAL  | 0     | — |
| HIGH      | 3     | FIXED |
| MEDIUM    | 0     | — |
| LOW       | 0     | — |

**Conclusão inicial**: Sprint D3 REPROVADA na revalidação. Gates estáticos e Bats passaram (`make shellcheck`, `bash -n`, unit 50/50, integration 138/138), mas a revisão senior confirmou 3 HIGH funcionais/contratuais que bloqueavam a aprovação e a continuação segura para D4.

**Correção 2026-05-08**: F-D3-001..F-D3-003 corrigidos em sprint aberta. Evidência local: `make shellcheck` PASS; `bash -n` em scripts principais PASS; `tests/unit` = 50/50 PASS; `tests/integration` = 141/141 PASS. Aguardando `/qa validar d3` para revalidar formalmente a sprint.

**Revalidação final 2026-05-08**: F-D3-001..F-D3-003 revalidados e aprovados. Evidência: `make shellcheck` PASS; `bash -n` PASS; `tests/unit` = 50/50 PASS; `tests/integration` = 141/141 PASS; revisão senior final = PASS, sem HIGH/CRITICAL remanescentes.
