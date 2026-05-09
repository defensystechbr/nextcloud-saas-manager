# Sprint Diary

> Aprendizados acumulados por sprint. Agentes: leiam o indice + ultimas 3-5 sprints no Passo 1.

## Indice

| Sprint | Modulos | Temas | Linhas |
|--------|---------|-------|--------|
| D5 | decision-brief, README, e2e, release | adr, release-docs, e2e-gate, hook-credentials, hard-stop | 11-27 |
| D4 | occ-bridge, client-lock, health-command, socket-proxy, secrets-file | occ-exec, redis-lock, health-parallel, docker-socket-proxy, secrets-file | 10-23 |

## Sprint D5
**Temas**: adr, release-docs, e2e-gate, hook-credentials, hard-stop

### Decisoes de implementacao
- ADRs `ARCH-001..ARCH-013` foram materializadas em `docs/DECISION-BRIEF.md` para fechar o registro arquitetural antes da release.
- README passou a tratar v12.0 como release, com indice de docs e secoes Feature O/P/hardening.

### O que nao funcionou
- A correcao necessaria para o E2E create+backup+remove exigia alterar `scripts/manage.sh`, mas o hook de credenciais bloqueou a edicao do arquivo.

### Descobertas tecnicas
- A suite integration completa precisa rodar fora do sandbox para o Redis fixture subir; com Docker liberado, `tests/integration` passou 146/146.
- Causa raiz do HARD_STOP D5.3: `create` calculava `MYSQL_DATABASE`/`MYSQL_USER`, mas `.env` legado do cliente nao persistia esses metadados; `backup/remove` quebravam em novo processo. Fix aplicado em `load_shared_config` derivando metadados nao secretos por `CLIENT_NAME`.

### Workarounds
- Nenhum workaround aplicado no codigo funcional; D5 foi parada em HARD_STOP para nao mascarar o gate E2E.
- D5.3 retomada via `/pmo fix`: `tests/e2e/test_create_backup_remove.bats` cobre create -> backup -> remove e passou 3/3.

## Sprint D4
**Temas**: occ-exec, redis-lock, health-parallel, docker-socket-proxy, secrets-file

### Decisoes de implementacao
- `occ-exec` ficou como caminho especial no dispatcher, porque subcomandos OCC usam `:` e nao mapeiam para nomes de funcao Bash convencionais.
- `health` agrega os 8 checks em JSON unico e retorna exit 1/2 para warn/fail sem perder o payload consumivel pela API.

### O que nao funcionou
- Leitura/patch direto de `setup-shared.sh` acionou o hook de credenciais; a edicao foi mantida minima e sem imprimir segredos.

### Descobertas tecnicas
- O lock D3 em `occ_run` ja cobria a regra de concorrencia D4; a superficie publica precisava apenas expor o exit 17 corretamente.

### Workarounds
- `setup-shared.sh` passa a escrever `.env` apenas com referencias `*_FILE` e exporta valores em runtime para imagens que ainda exigem env literal.
