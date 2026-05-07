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
