# Sprint Diary

> Aprendizados acumulados por sprint. Agentes: leiam o indice + ultimas 3-5 sprints no Passo 1.

## Indice

| Sprint | Modulos | Temas | Linhas |
|--------|---------|-------|--------|
| D4 | occ-bridge, client-lock, health-command, socket-proxy, secrets-file | occ-exec, redis-lock, health-parallel, docker-socket-proxy, secrets-file | 10-23 |

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
