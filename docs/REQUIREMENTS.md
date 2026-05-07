# Requisitos — Nextcloud SaaS Manager

> Gerado em: 2026-05-06
> Status: Rascunho
> Versão alvo desta evolução: **v12.0** (sobre baseline v11.3.4)
> Branch de trabalho: `development`

---

## 1. Visão Geral

**Descrição**: Conjunto de scripts Bash para implantar e gerenciar uma plataforma Nextcloud SaaS multi-tenant em servidor Ubuntu 24.04 (KVM), com Docker Compose, Traefik, Let's Encrypt e arquitetura híbrida de **8 serviços compartilhados + 3 containers por cliente**.

**Problema que resolve**: Operar dezenas de instâncias Nextcloud isoladas no mesmo servidor sem precisar replicar serviços pesados (MariaDB, Redis, Collabora, Talk HPB, Recording, coturn) por cliente — economiza CPU/RAM e centraliza manutenção.

**Para quem**: Time DevOps interno da Defensys que opera o servidor de produção e provisiona instâncias para clientes finais.

**Objetivo de negócio (próxima evolução)**: Permitir que **uma API REST externa** consuma este sistema via SSH para automatizar onboarding/offboarding de clientes (criar, suspender, remover, fazer backup) **sem que a API fique bloqueada** durante operações longas — habilitando que o produto comercial cresça sem trabalho manual proporcional.

**Cenário**: ANÁLISE (sistema existente em v11.3.4 sendo formalizado e evoluído).

---

## 2. Stakeholders

| Nome / Papel | Tipo | Prioridade | O que importa para ele |
|---|---|---|---|
| Time DevOps interno | Decisor + Usuário final | Alta | Operação previsível, comandos curtos, troubleshooting rápido, "não apagar o cliente errado" |
| Engenheiro de plataforma (autor dos scripts) | Decisor técnico | Alta | Não quebrar o que já funciona em produção; dívida técnica controlada; testes antes de refatorar |
| API REST consumidora *(em outro repositório)* | Influenciador | Alta | Contratos estáveis (CLI flags, JSON de saída), latência de invocação baixa, observabilidade dos jobs |
| Cliente final / Admin Nextcloud | Usuário indireto | Média | Disponibilidade da instância, dados preservados em updates, downtime curto e previsível |
| Patrocinador / Negócio | Patrocinador | Alta | Aumentar volume de instâncias atendidas sem aumentar custo operacional proporcional |

> **Tipos**: Decisor (aprova escopo/mudanças) / Influenciador (opina, não decide) / Usuário final (opera o sistema) / Patrocinador (financia)

---

## 3. Usuários e Personas

| Persona | Contexto | Principal frustração (hoje) | Objetivo | Nível técnico |
|---|---|---|---|---|
| **DevOps Operador (Marcos)** | Time pequeno; mesma pessoa também faz SRE | "Tenho que ssh no servidor toda vez que entra cliente novo. E quando o cliente quer ser removido, tenho que confirmar 3 vezes mentalmente pra não apagar o errado." | Comandos rápidos, idempotentes, com `--dry-run`; trilha de auditoria | Técnico |
| **DevOps SRE / On-call (mesmo Marcos no plantão)** | Atende incidente Talk/HaRP/Collabora/SSL | "O `TROUBLESHOOTING.md` é bom, mas eu queria um `health` único que me dissesse o que está quebrado em 1 segundo." | Diagnóstico unificado; logs estruturados; sem precisar `docker logs` em 11 containers | Técnico |
| **Engenheiro de plataforma (Marcos PR-author)** | Evolui scripts, faz bump de versão, abre PR | "Sem teste automatizado eu fico com medo de mexer no `manage.sh`. QA é manual em produção (literalmente)." | Suite de testes; CI verde; ShellCheck passando | Técnico |
| **API REST consumidora (sistema)** *(persona não-humana)* | Outro projeto/repositório, em produção ou em desenvolvimento | "Quando chamo `create` por SSH, fico travada minutos esperando containers subirem." | Resposta em <2s com `job_id`; consultar status depois; receber webhook ao concluir | Sistema |
| **Cliente final / Admin Nextcloud** | Usa a instância dele, não os scripts | "Não sei quando vai cair pra atualização." | Janela de manutenção previsível; backup recente antes de update; dados preservados | Semi-técnico |

---

## 4. Features

### 4.1 Funcionalidades existentes (v11.3.4 — baseline)

> Documentadas aqui para virar contrato operacional do time DevOps. Implementação atual em `scripts/deploy-server.sh` (914 linhas) e `scripts/manage.sh` (1.051 linhas).

| # | Feature | Comando | Estado |
|---|---|---|---|
| F01 | Provisionar servidor zero (Docker, Traefik, shared-services, manage.sh) | `sudo bash scripts/deploy-server.sh --email ... --collabora-domain ... --signaling-domain ... --turn-domain ...` | Estável |
| F02 | Criar instância de cliente | `sudo nextcloud-manage <cliente> <dominio> create` | Estável |
| F03 | Status de instância | `sudo nextcloud-manage <cliente> _ status` | Estável |
| F04 | Listar credenciais | `sudo nextcloud-manage <cliente> _ credentials` | Estável |
| F05 | Listar todas instâncias | `sudo nextcloud-manage list` | Estável |
| F06 | Backup (tar.gz + dump MariaDB) | `sudo nextcloud-manage <cliente> _ backup` | Estável |
| F07 | Restore (a partir de tar.gz) | `sudo nextcloud-manage <cliente> <tar.gz> restore` | Estável |
| F08 | Stop / Start instância | `sudo nextcloud-manage <cliente> _ stop\|start` | Estável |
| F09 | Update (puxa imagens + upgrade Nextcloud) | `sudo nextcloud-manage <cliente> _ update` | Estável |
| F10 | Remove (irreversível) | `sudo nextcloud-manage <cliente> _ remove` | Estável (sem `--dry-run`, sem confirmação dupla) |

### 4.2 Próxima evolução (v12.0) — features novas com critérios de aceite

Priorização final (após confirmação do usuário):

- **P0 — Bloqueia consumo via API REST**: N, A, D
- **P1 — Alta dor operacional**: B, C, M
- **P2 — Próximo sprint após v12.0**: E, F, H
- **P3 — Horizonte 6m+**: G, I, J, K, L

---

#### Feature N: Modo assíncrono + Worker para consumo via API REST

- **Persona**: API REST consumidora + DevOps Operador
- **Prioridade**: Must-have (P0)

**Contexto**: A API REST acessa o servidor via SSH e invoca `manage.sh`. Operações como `create` levam 5–15 minutos, o que estoura timeouts HTTP. O comando precisa **enfileirar o job e devolver imediatamente** um `job_id`.

**Fluxo principal (caminho feliz):**
1. API faz SSH e executa `manage.sh acme nextcloud.acme.com.br create --async --idempotency-key=<uuid> --callback=https://api.exemplo/jobs/hook --json`
2. Script valida argumentos, gera `job_id` (UUID v4) e grava na fila Redis (`LPUSH nc:jobs:queue <job_id>`)
3. Script grava o estado inicial em `HSET nc:jobs:<job_id> state queued cmd create args ... idempotency_key ... callback_url ... queued_at <ISO8601>`
4. Script imprime `{"job_id":"...","state":"queued","queued_at":"..."}` em stdout e encerra com exit 0 em **menos de 2 segundos**
5. Worker daemon (`nextcloud-saas-worker.service`) consome da fila (`BRPOP nc:jobs:queue 0`), executa o `create` real, atualiza `state` para `running` → `success`/`failed` no hash do Redis e em arquivo de log
6. Ao concluir, worker faz `POST` na `callback_url` (se fornecida) com payload `{job_id, state, exit_code, finished_at, log_url}` e header `X-Signature: HMAC-SHA256(secret, body)`

**Fluxo alternativo:**
- API consulta status manualmente: `manage.sh job <id> status` retorna JSON com `{state, started_at, finished_at, exit_code, log_path}`
- API consulta logs: `manage.sh job <id> logs` faz cat do arquivo `/opt/nextcloud-customers/jobs/<id>.log`
- API cancela job em fila: `manage.sh job <id> cancel` (só funciona se ainda `queued`)

**Fluxo de exceção:**
- Redis indisponível → script retorna exit 2 com `{"error":"queue_unavailable","retry_after":30}` e escreve no journald
- `idempotency-key` já usada nas últimas 24h com **mesmo cmd e args** → retorna o `job_id` antigo com exit 0 (sem enfileirar de novo)
- `idempotency-key` já usada nas últimas 24h com **cmd ou args diferentes** → exit 3 com `{"error":"idempotency_conflict","existing_job_id":"..."}`
- Worker crasha durante execução → systemd restart; job marcado como `failed` com `error_msg="worker_killed"`; callback é disparado com state=failed
- Callback HTTP falha → worker retenta 3x com backoff exponencial (5s, 30s, 5min); após 3 falhas grava `callback_failed=true` no hash mas job permanece `success`/`failed` (estado real do cliente é o que importa)

**Regras de negócio:**
- **Concorrência**: 1 job por vez (sequencial). Operações que mexem em recursos compartilhados (`signaling.conf`, allowlist do Collabora, DDL no MariaDB compartilhado) **não podem rodar em paralelo**. Configurável via `WORKER_CONCURRENCY` na unit do systemd (default `1`)
- **Operações async-only**: `create`, `remove`, `backup`, `restore`, `update`, `stop`, `start`
- **Operações síncronas (não usam fila)**: `status`, `list`, `credentials`, `job <id> status/logs/cancel`, `worker status`, `health`
- **Retenção**: hash `nc:jobs:<id>` expira em 7 dias após `finished_at` (TTL no Redis); arquivo de log mantém 30 dias e depois é removido por GC semanal do worker
- **Idempotência**: `idempotency-key` é opcional mas recomendada; sem ela, retries da API criam jobs duplicados
- **Auditoria**: cada invocação registra em `journald` (tag `nextcloud-saas-worker`) com `job_id`, `cmd`, `args`, `caller_uid`, `started_at`

**Critérios de aceite:**
- [ ] `manage.sh acme nextcloud.acme.com.br create --async --json` retorna stdout JSON válido em menos de 2s e termina com exit 0
- [ ] O hash Redis `nc:jobs:<job_id>` é criado com state inicial `queued`
- [ ] Worker daemon (systemd unit) consome da fila e executa o create real, atualizando state para `running` e depois `success` ou `failed`
- [ ] `manage.sh job <id> status` retorna o estado correto durante e após a execução
- [ ] Reenviar a mesma operação com a mesma `idempotency-key` em até 24h retorna o mesmo `job_id` (não cria duplicata)
- [ ] Reenviar com mesma `idempotency-key` mas args diferentes retorna exit 3 com `idempotency_conflict`
- [ ] Callback HTTP é disparado com payload e assinatura HMAC válidos
- [ ] Worker se recupera de crash (systemd Restart=on-failure) e job em `running` é marcado como `failed`
- [ ] Comando `manage.sh worker status` retorna `{"active":true,"queue_depth":N,"current_job":"..."}`
- [ ] Modo síncrono (sem `--async`) continua funcionando para uso interativo no terminal (não quebra workflow atual do operador)
- [ ] Logs do worker aparecem em `journalctl -u nextcloud-saas-worker -f`

---

#### Feature A: Suite de testes automatizados

- **Persona**: Engenheiro de plataforma
- **Prioridade**: Must-have (P0 — pré-requisito de N, refatorar `manage.sh` sem testes é arriscado)

**Fluxo principal:**
1. Desenvolvedor abre PR no GitHub
2. Workflow `.github/workflows/test.yml` executa suite Bats em container Ubuntu 24.04
3. Testes cobrem helpers de `manage.sh` (parsers, validações, geração de senhas) e o fluxo `create → status → backup → restore → remove` em ambiente Docker-in-Docker
4. Cobertura mínima: 60% das funções de `manage.sh` no primeiro release; meta 80% em 3 sprints

**Critérios de aceite:**
- [ ] `tests/` contém suite Bats com pelo menos 30 cenários
- [ ] Workflow CI executa em <8 min e bloqueia merge se falhar
- [ ] README.md tem seção "Como rodar testes localmente" com `bats tests/`
- [ ] Funções críticas (`generate_password`, `validate_dns`, `update_collabora_allowlist`, `update_signaling_backends`) têm teste unitário
- [ ] Fluxo end-to-end (create → backup → remove) roda em CI com Docker-in-Docker

---

#### Feature B: Restaurar `shellcheck.yml` no CI

- **Persona**: Engenheiro de plataforma
- **Prioridade**: Should-have (P1)

**Contexto**: README v11.3 anuncia esse workflow, mas ele **não está mais no repositório**. Os 5 workflows atuais (`.github/workflows/beesy-*.yml`) são robôs Beesy, nenhum executa ShellCheck.

**Critérios de aceite:**
- [ ] `.github/workflows/shellcheck.yml` recriado, executa em todo PR e push para `development`/`main`
- [ ] Falha o CI se houver warning de severidade `error` ou `warning` (não `info`/`style`)
- [ ] Cobre `scripts/*.sh` e `shared-services/*.sh`
- [ ] README e changelog atualizados refletindo o estado real

---

#### Feature C: Comando consolidado `manage.sh health`

- **Persona**: DevOps SRE / On-call
- **Prioridade**: Should-have (P1)

**Fluxo principal:**
1. Operador roda `sudo nextcloud-manage health` (sem cliente nem domínio)
2. Comando valida em paralelo (com timeouts curtos): containers shared-services rodando, certificados Traefik válidos com >7 dias de vida, DNS dos domínios fixos resolvendo, healthcheck do `shared-recording` (`curl 127.0.0.1:1234/api/v1/welcome`), socket Docker montado em todos os `*-harp`, espaço em disco em `/opt/`, fila Redis acessível, worker systemd ativo
3. Saída humana com seções `OK / WARN / FAIL` e exit code: `0` (tudo ok), `1` (warning), `2` (fail crítico)
4. Flag `--json` para consumo pela API/monitoring

**Critérios de aceite:**
- [ ] Comando executa em <10s mesmo com 20 instâncias
- [ ] `--json` retorna estrutura `{checks: [{name, status, message, duration_ms}], summary: {ok, warn, fail}}`
- [ ] Cobre os 8 problemas mais comuns do `TROUBLESHOOTING.md` (HaRP socket, Collabora allowlist, signaling backends, certs, DNS, Redis, worker, disco)
- [ ] Documentado no `ADMINISTRATION.md`

---

#### Feature D: Idempotência + `--dry-run` em `create`/`update`/`remove`

- **Persona**: DevOps Operador + API REST
- **Prioridade**: Must-have (P0 — pré-requisito de N)

**Fluxo principal:**
1. Operador (ou API) roda comando com `--dry-run`
2. Script imprime tudo o que **faria** (criar database `nextcloud_acme`, alocar dbindex Redis 5, escrever 4 arquivos em `/opt/nextcloud-customers/acme/`, etc.) sem aplicar mudanças
3. Comando `create` em instância já existente é detectado e retorna estado atual (idempotente: 0 mudanças, exit 0) ao invés de erro

**Regras de negócio:**
- `create` em instância existente com **mesmos args** → no-op idempotente, exit 0
- `create` em instância existente com **args diferentes** → exit 4 com mensagem clara
- `remove` exige `--confirm=<nome-cliente>` quando NÃO for `--async` (proteção contra fat-finger)
- `remove --async --idempotency-key=...` aceita reentrada (idempotente)
- Todos os `--dry-run` são read-only e não tocam nem em Redis nem em filesystem

**Critérios de aceite:**
- [ ] `create`/`update`/`remove` aceitam `--dry-run`
- [ ] `--dry-run` produz lista das mudanças planejadas em texto e em JSON (`--json --dry-run`)
- [ ] `create` é idempotente quando args batem; conflito retorna exit 4 com diff
- [ ] `remove` interativo (sem `--async`) exige `--confirm=<cliente>` para confirmar
- [ ] Documentado no `ADMINISTRATION.md`

---

#### Feature M: Hardening (próximo passo, não bloqueia v12.0)

- **Persona**: Engenheiro de plataforma + Compliance
- **Prioridade**: Should-have (P1)

**Contexto**: O container `<cliente>-harp` monta `/var/run/docker.sock` em modo RW por exigência do AppAPI. Isso concede privilégios equivalentes a root no host. A v12.0 endereça os itens mais baratos:

**Itens cobertos em v12.0:**
- Substituir mount direto do socket por **socket-proxy** (`tecnativa/docker-socket-proxy`) com allowlist de endpoints (`POST /containers/create`, `POST /containers/<id>/start`, etc.) — reduz superfície sem quebrar HaRP
- Mover secrets de `.env` para arquivos `*.secret` lidos como `_FILE` quando suportado pela imagem
- Audit log do worker em journald com tag dedicada e retenção mínima de 30 dias

**Itens deferidos para v12.1+** (registrados em §13):
- Rotação automática de senhas Nextcloud admin
- 2FA para SSH do `ncsaas-api`
- AppArmor/SELinux profiles para os containers

**Critérios de aceite:**
- [ ] Socket-proxy interposto entre HaRP e Docker daemon; ExApps continuam instalando
- [ ] Nenhum container além do socket-proxy tem acesso direto a `/var/run/docker.sock`
- [ ] `.env` não contém senhas em texto puro (apenas referências `*_FILE=/run/secrets/...`)
- [ ] `journalctl -u nextcloud-saas-worker --since "30 days ago"` retorna histórico completo

---

#### Feature O: Lifecycle de usuários, grupos e apps por cliente (assíncrono)

- **Persona**: API REST consumidora + DevOps Operador
- **Prioridade**: Must-have (P0 — descoberta tardia, mas é a base de várias rotas REST públicas da API consumidora)

**Contexto**: A API REST expõe endpoints REST para gerenciar usuários, grupos e apps **dentro** de uma instância Nextcloud já criada. Diferente das chamadas OCC diretas (Feature P, sync), estas operações podem ser **multi-step** (criar usuário + atribuir grupos + setar quota + configurar template inicial; instalar app + rodar migrations + habilitar; etc.) e portanto cabem na fila assíncrona com callback.

**Endpoints REST que motivam esta feature**:

| Endpoint da API consumidora | Operação `manage.sh` correspondente |
|---|---|
| `POST /customers` (com `apps[]` ou `full_apps`, `logo_png_base64`, `background_png_base64`) | `create` (estendido — anexos via SCP staging — Feature O.1) |
| `POST /customers/{customer}/users` | `user create` (Feature O.2) |
| `DELETE /customers/{customer}/users/{username}` | `user remove` (Feature O.2) |
| `PATCH /customers/{customer}/users/{username}` | `user modify` (Feature O.2) |
| `POST /customers/{customer}/groups` | `group create` (Feature O.3) |
| `DELETE /customers/{customer}/groups/{group}` | `group remove` (Feature O.3) |
| `PATCH /customers/{customer}/groups/{group}` | `group modify` (Feature O.3) |
| `POST /customers/{customer}/apps/enable` | `apps enable` (Feature O.4) |
| `POST /customers/{customer}/apps/disable` | `apps disable` (Feature O.4) |

**Sub-features:**

- **O.1 — `create` estendido com anexos**: aceita lista de apps a habilitar pós-criação, flag `--full-apps` (instala suite completa de produtividade), e dois anexos PNG/JPEG (logo + background) para theming na mesma transação. Anexos chegam ao servidor **antes** do SSH via **SCP staging** (ver Feature O.5).
- **O.2 — User lifecycle**: `user create <username>`, `user remove <username>`, `user modify <username>` no namespace de cada cliente. Atributos suportados: `display_name`, `email`, `password` (no create/modify), `groups` (set/add/remove), `quota`. Implementação interna usa `nextcloud-occ user:add/delete/setting` + lógica de template inicial.
- **O.3 — Group lifecycle**: `group create <groupname>`, `group remove <groupname>`, `group modify <groupname>`. Atributos: `display_name`. Implementação usa `occ group:add/delete`.
- **O.4 — Apps batch**: `apps enable <appid1>,<appid2>,...` e `apps disable <appid1>,<appid2>,...` em lote (uma operação async = N apps). Falha de 1 app não aborta os outros; resultado por app é consolidado no `summary` do job.
- **O.5 — SCP staging**: ANTES de invocar `manage.sh ... create --async --staging-id=<uuid>`, a API REST faz `scp` dos anexos para `/opt/nextcloud-customers/inbox/<staging-id>/{logo.png,background.png,...}`. O usuário SSH `ncsaas-api` tem permissão **somente** para escrever em `/opt/nextcloud-customers/inbox/` (jail por `Match User` + `ChrootDirectory` ou via `internal-sftp` com path restrito). Após consumo, a pasta é movida para `/opt/nextcloud-customers/jobs/<job_id>/staging/` e GC após retenção do log do job (30d).

**Fluxo principal (caminho feliz — exemplo `user create`):**

1. API faz `ssh ncsaas-api@host nextcloud-manage acme user create john --display-name="John Doe" --email=john@acme.com --groups=editors --quota=5GB --idempotency-key=<uuid> --async --json`.
2. Validators rejeitam username inválido, email malformado, quota fora de unidade aceita.
3. Job enfileirado; API recebe `EnqueuedJob` em <2s (mesmo NFR de Feature N).
4. Worker pega o job; faz `docker exec acme-app php occ user:add john --display-name="John Doe" --email=john@acme.com --password-from-env`; depois `occ user:setting john files quota "5 GB"`; depois `occ group:adduser editors john`.
5. Worker registra cada subpasso no log do job; estado final é `success` se todos os passos `occ` retornarem 0.
6. Callback HMAC com `cmd=user-create`, `state=success`, `summary={username, display_name, groups, quota_set, occ_steps_completed}`.

**Fluxo de exceção:**
- Cliente (instância) não existe → exit 11 com `instance_not_found` (verificação síncrona no enqueue).
- Cliente em modo manutenção → enfileirar normalmente; worker aguarda janela ou falha com `instance_in_maintenance` (configurável).
- Senha vazia ou inválida → exit 10 (`invalid_password`); senha **nunca** trafega via argv (é lida de `--payload-stdin` ou de variável `NEXTCLOUD_USER_PASSWORD` injetada pelo shim).
- App inexistente em `apps enable foo,bar,baz` → o app inválido falha individualmente; outros são processados; `summary.failed_apps=["bar"]`; exit 1 (warning) se algum falhou.

**Regras de negócio:**
- **Senha nunca em argv**: passada exclusivamente por `--payload-stdin` (Feature O.5 também aceita stdin) ou por variável de ambiente do shim. Scrub agressivo no log (regex defensiva).
- **Idempotência reforçada**: `user create` para username já existente com mesmos atributos = no-op exit 0; com atributos diferentes = exit 4 (`state_conflict`).
- **`apps enable` é parcial-tolerante**: 1 app falho não aborta os outros (diferente de `create` cliente, que é atômico). Política configurável via `--strict` (exit 2 se qualquer falha).
- **OCC steps em transação log**: cada `occ` interno tem seu `started_at`/`finished_at`/`exit_code` registrado em `summary.occ_steps[]` para diagnóstico.
- **Compatibilidade com Feature N**: tudo que vale para create/remove cliente (idempotency-key, callback, dry-run, schema_version) vale aqui.

**Critérios de aceite:**
- [ ] `nextcloud-manage <cliente> user create <user> --async --json` enfileira em <2s e retorna `EnqueuedJob` válido
- [ ] `user remove`, `user modify`, `group create`, `group remove`, `group modify` seguem mesmo contrato e geram callback ao concluir
- [ ] `apps enable a,b,c --async` processa N apps em sequência; `summary.apps[]` lista resultado de cada um
- [ ] `apps disable` é simétrico ao enable
- [ ] `create` estendido aceita `--apps=a,b,c`, `--full-apps`, e referência por `--staging-id=<uuid>` para anexos pré-staged via SCP
- [ ] SCP para `/opt/nextcloud-customers/inbox/<staging-id>/` funciona via SFTP restrito (sem shell interativo)
- [ ] Senha em `user create`/`user modify` **nunca** aparece em journald nem em `JobStatus.args` (scrub defensivo + payload via stdin)
- [ ] Dúvida #1 (URL da API consumidora) **não** bloqueia esta feature — é independente de callback

---

#### Feature P: OCC sync passthrough com allowlist

- **Persona**: API REST consumidora (operações idempotentes leves) + DevOps Operador (diagnóstico)
- **Prioridade**: Must-have (P0 — descoberta junto com Feature O)

**Contexto**: 15 endpoints REST na API consumidora prefixados por `/customers/{customer}/occ/...` mapeiam diretamente para chamadas `nextcloud-occ` (binário oficial do Nextcloud, executado dentro do container do cliente via `docker exec <cliente>-app php occ`). Estas operações são **rápidas** (<5s típico), **idempotentes** por natureza, **leem ou escrevem configuração via OCC** sem multi-step provisioning. Não cabem em fila — overhead de enfileirar + worker pickup é maior que o tempo de execução.

**Endpoints REST que motivam esta feature**:

| Endpoint da API | Operação OCC subjacente | Notas |
|---|---|---|
| `POST /occ/branding` | `theming:config` (multi-call) | Anexos logo/background via SCP staging |
| `POST /occ/users` | `user:add` | Senha via `--payload-stdin` |
| `PATCH /occ/users/{u}` (quota) | `user:setting <u> files quota "..."` | Aceita unidades `5 GB`, `1 TB`, `unlimited` |
| `DELETE /occ/users/{u}` | `user:delete` | Idempotente |
| `POST /occ/groups` | `group:add` | Idempotente |
| `POST /occ/apps/{appId}/enable` | `app:enable <appId>` | Single-app (vs Feature O.4 que é batch) |
| `POST /occ/files/rescan` | `files:scan --all` ou `files:scan <user>` | Pode ser longo (ressalva: sync com timeout 60s; >60s exige Feature O via `apps enable nextcloud_files_scan`) |
| `POST /occ/maintenance` | `maintenance:mode --on/--off` | Toggle |
| `POST /occ/quota/all` | iteração `user:list` + `user:setting` | Batch sync |
| `GET/POST /occ/quota/default` | `config:app:get/set files default_quota` | — |
| `GET/POST /occ/quota/options` | `config:app:get/set files quota_preset` | JSON array |
| `GET /occ/users/{u}/quota` | `user:info <u>` (filter) | Read-only |
| `POST /occ/groups/{g}/quota` | iteração membros + `user:setting` | Batch sync |
| `GET /occ/quota/audit` | aggregate `user:info` + `files:scan --no-cache` | Custo médio (até 30s) |

**Decisão de design — `occ-exec` com allowlist**:

Em vez de criar 15 verbos amigáveis (1 por endpoint), expomos **um único verb passthrough** restrito por allowlist de subcomandos OCC:

```text
nextcloud-manage <cliente> occ-exec <occ-subcommand> [<occ-args>...] [--json] [--payload-stdin] [--staging-id=<uuid>]
```

A allowlist de `<occ-subcommand>` é **fechada** e versionada (parte do contrato — `docs/CONTRACTS.md §3.10`). Novos OCC commands exigem PR + bump de `schema_version`.

**Allowlist proposta (versão `1` do contrato)**:
- `theming:config`
- `user:add`, `user:delete`, `user:disable`, `user:enable`, `user:info`, `user:list`, `user:setting`, `user:resetpassword`
- `group:add`, `group:delete`, `group:adduser`, `group:removeuser`, `group:list`, `group:info`
- `app:enable`, `app:disable`, `app:list`, `app:install`, `app:remove`
- `files:scan`, `files:cleanup`, `files:repair-tree`
- `maintenance:mode`, `maintenance:repair`
- `config:app:get`, `config:app:set`, `config:app:delete`, `config:app:list`
- `config:system:get` (read-only — `config:system:set` **bloqueado**, exige operador local)
- `db:add-missing-indices`, `db:add-missing-columns` (idempotentes)
- `notification:generate`
- `versions:expire`, `versions:cleanup`

**Bloqueado explicitamente** (nunca atravessa o shim, mesmo em `occ-exec`):
- `encryption:*` (risco de perda de dados)
- `db:execute`, `db:convert-type` (risco operacional)
- `app:install` de fontes não-oficiais (apenas store oficial)
- `config:system:set` (mudança em config global do Nextcloud — operador local apenas)
- `update:check`, `upgrade` (são parte do `cmd update` async com backup)
- `security:certificates*` (operador local)

**Fluxo principal (exemplo `occ-exec maintenance:mode --on`):**

1. API faz `ssh ncsaas-api@host nextcloud-manage acme occ-exec maintenance:mode --on --json`.
2. Shim valida `argv[1]=acme` (cliente válido), `argv[2]=occ-exec`, `argv[3]=maintenance:mode` (na allowlist), demais argv não contém metacaracteres.
3. `manage-cli` executa `docker exec acme-app php occ maintenance:mode --on --output=json` (quando OCC suporta `--output=json`; do contrário captura stdout/stderr como string).
4. Resposta: `OccExecResult` com `{schema_version, occ_command, exit_code, stdout, stderr, parsed_result}` (parsed_result preenchido quando OCC retorna JSON estruturado).
5. Tempo total: <5s (timeout configurável via `WORKER_OCC_TIMEOUT_SEC=60`).

**Fluxo de exceção:**
- OCC subcommand fora da allowlist → shim rejeita com exit 100 (`occ_command_not_allowed`).
- Container `<cliente>-app` parado → exit 14 (`instance_not_running`); orientar operador a `manage.sh <cliente> _ start`.
- OCC timeout (>60s) → exit 15 (`occ_timeout`); sugerir Feature O.4 (apps batch async) para operações longas.
- OCC retorna não-zero → exit 16 (`occ_command_failed`); stdout/stderr preservados em `OccExecResult`.

**Regras de negócio:**
- **Sem fila, sem callback**: `occ-exec` é **sempre** sync; `--async` rejeitado com `async_not_supported`.
- **Sem idempotency-key**: idempotência é responsabilidade do OCC subjacente (todos os comandos da allowlist são idempotentes por design).
- **Concorrência respeita worker lock**: `occ-exec` que altera estado (set quota, maintenance:mode) não roda enquanto worker está executando job no mesmo cliente — retorna exit 17 (`client_busy_async_job_running`).
- **OCC subcommand é argv-mode**: nunca string-concat; `docker exec <c>-app php occ <subcmd> "${args[@]}"`.
- **Output**: quando OCC suporta `--output=json` (modern Nextcloud), parsea e expõe em `parsed_result`. Quando não, expõe stdout cru em `stdout` e deixa parse para a API.
- **Auditoria**: cada `occ-exec` gera evento NDJSON em journald com `caller_key_id`, `client`, `occ_subcommand`, `occ_args`, `exit_code`, `duration_ms`.

**Critérios de aceite:**
- [ ] `nextcloud-manage <cliente> occ-exec <subcmd> [args]` executa via `docker exec` e retorna `OccExecResult` em <5s para 90% das operações
- [ ] Allowlist de subcommands é fechada; tentativa fora da lista retorna exit 100 com `occ_command_not_allowed`
- [ ] Subcommands bloqueados explicitamente (encryption, db:execute, config:system:set, etc.) **nunca** executam, mesmo se entrarem em allowlist genérica futura
- [ ] `occ-exec` rejeita `--async` com `async_not_supported`
- [ ] Concorrência: `occ-exec` em cliente com job async em `running` retorna exit 17 (`client_busy_async_job_running`) sem efeitos colaterais
- [ ] Senhas em `occ-exec user:add` ou `user:resetpassword` chegam via `--payload-stdin`, nunca via argv
- [ ] OCC commands que suportam `--output=json` têm `parsed_result` preenchido; demais expõem `stdout` cru
- [ ] Audit log: 1 entrada NDJSON por invocação no journald (tag `nextcloud-saas-occ-exec`)
- [ ] Documentação: `docs/CONTRACTS.md §3.10` lista a allowlist completa com mapeamento OCC → endpoint REST

---

### 4.3 Features adiadas (P2/P3 — fora desta evolução, mantidas no roadmap)

| # | Feature | Prioridade | Razão de adiar |
|---|---|---|---|
| E | Backup automático agendado + off-site (S3/B2) | P2 | Crítico mas não bloqueia API REST; entra logo após v12.0 |
| F | Observabilidade (Loki + Prometheus + Grafana) | P2 | Logs estruturados básicos do worker já saem no journald em v12.0 |
| G | Multi-servidor com inventário declarativo (Ansible-style) | P3 | Épico; servidor único atende a demanda atual |
| H | Upgrade Nextcloud canary/rollback | P2 | Importante para não quebrar clientes em update |
| I | Painel web read-only para o time DevOps | P3 | A API REST consumidora pode prover esse painel |
| J | Migração de instância entre servidores | P3 | Depende de G (multi-servidor) |
| K | Atualização automática de imagens (Renovate) | P3 | Rotina manual ainda funciona; risco baixo de adiar |
| L | Cota por cliente (disco/CPU/RAM) | P3 | Sem demanda comercial imediata |

---

## 5. Integrações

| Sistema | Tipo | Direção | Autenticação | Fallback |
|---|---|---|---|---|
| **API REST consumidora** *(repo separado)* | CLI via SSH + opcionalmente Webhook | Bidirecional (SSH entrada, webhook saída) | SSH key par + sudoers restrito; HMAC-SHA256 nos webhooks | Polling em `manage.sh job <id> status` quando webhook falha |
| **Let's Encrypt** | HTTP/ACME | Saída | — | Já existente; sem mudança |
| **DNS público (do cliente)** | DNS A record | Entrada (validação ACME) | — | Já existente; pré-condição manual |
| **Docker Hub / Quay / GHCR** | Image registry | Saída | Anônimo (público) | Já existente |

**Autenticação SSH (novo na v12.0)**:
- Usuário não-privilegiado `ncsaas-api` no servidor
- Chave SSH dedicada, rotacionável (`/etc/ssh/keys/ncsaas-api/authorized_keys`)
- `sudoers` permite **apenas** `/opt/nextcloud-customers/manage.sh` com `NOPASSWD`
- Logs de invocação em `journald` (tag `ncsaas-api-ssh`)

**Contrato JSON da API com o servidor (CLI):**

```text
INPUT  (stdin/args): manage.sh <cliente> <dom|_> <cmd> [--async] [--idempotency-key=K] [--callback=URL] [--dry-run] [--json]
OUTPUT (stdout):     {"job_id":"...","state":"queued","queued_at":"<ISO8601>"}             # async
                     {"state":"success","exit_code":0,"summary":{...}}                      # sync
                     {"checks":[...],"summary":{"ok":N,"warn":N,"fail":N}}                  # health
                     {"error":"<code>","message":"...","retry_after":N}                     # erros
EXIT CODES:          0 = sucesso (sync) ou enfileirado (async)
                     1 = warning (health)
                     2 = fail crítico ou queue_unavailable
                     3 = idempotency_conflict
                     4 = state_conflict (create em instância existente com args diferentes)
                     >=10 = erro técnico (validação, permissão, etc.)
```

---

## 6. Requisitos Não-Funcionais

| Categoria | Requisito | Meta |
|---|---|---|
| **Performance** | Latência de invocação de `manage.sh ... --async` (do SSH ao retorno do JSON) | < 2 segundos |
| Performance | Comando `health --json` | < 10 segundos com 20 instâncias |
| Performance | Comando `status` síncrono | < 3 segundos |
| **Escalabilidade** | Instâncias suportadas no servidor único | Até 50 instâncias ativas (limite atual de RAM/disco; medir e revisar) |
| Escalabilidade | Throughput do worker | 1 job por vez × ~10 jobs longos por hora (create) ou ~60 jobs curtos por hora (stop/start) |
| **Disponibilidade** | Uptime worker (systemd) | ≥ 99.9% (Restart=on-failure, watchdog) |
| Disponibilidade | Janela aceitável para o servidor inteiro estar fora (manutenção) | ≤ 4h/mês, comunicada com ≥ 48h |
| **Segurança** | Compliance | LGPD (dados de clientes hospedados) — encriptação em repouso e em trânsito; logs auditáveis |
| Segurança | SSH da API | Chave dedicada, sudoers restrito a 1 binário, sem shell interativo |
| Segurança | Secrets | Sem texto puro em `.env` (a partir de v12.0 hardening) |
| **Observabilidade** | Logs do worker | journald, JSON estruturado, retenção 30 dias |
| Observabilidade | Métricas básicas | `worker status` JSON expõe queue_depth, jobs_today, last_failure |
| **Manutenibilidade** | Cobertura de testes Bats | ≥ 60% das funções na v12.0; ≥ 80% em 3 sprints |
| Manutenibilidade | Lint | ShellCheck `error`/`warning` zerados em todo PR |
| **Acessibilidade** | N/A (CLI / API server-side) | — |

---

## 7. Fora de Escopo (v12.0)

- **Construir a API REST consumidora** — vive em outro repositório; este projeto entrega apenas os contratos CLI/SSH consumidos por ela.
- **Painel web administrativo** — pode ser função da API REST consumidora.
- **Multi-servidor / orquestração de cluster** — fica para v13+ (deferida do roadmap).
- **Migração entre servidores** — depende de multi-servidor.
- **Trocar Bash por outra stack** (Go, Python, Ansible, Terraform) — explicitamente decidido manter Bash + Docker Compose.
- **Migração para Kubernetes** — fora de escopo permanente nesta linha do produto.
- **Billing / cobrança / portal do cliente** — domínio comercial, vive na API consumidora.
- **Cotas por cliente** (disco/CPU/RAM) — adiado para P3.
- **Backup off-site automático** — adiado para P2 (sprint imediatamente após v12.0).
- **Upgrade canary** — adiado para P2.
- **Rotação automática de senhas Nextcloud admin** — adiado para v12.1+.
- **AppArmor/SELinux profiles** — adiado para v12.1+.
- **2FA no SSH do `ncsaas-api`** — adiado para v12.1+.

> Esta seção foi consolidada após a definição do que entra na v12.0 (Features 4.2).

---

## 8. Premissas

- **Time DevOps é pequeno** (essencialmente uma pessoa com vários chapéus); soluções não-elaboradas são preferidas a soluções elegantes.
- **Stack se mantém Bash + Docker Compose**; rebuild não está sobre a mesa.
- **Servidor único Ubuntu 24.04 KVM** continua atendendo a demanda; multi-host é horizonte longo.
- **Sem orçamento extra**; tudo open source, self-hosted e sem dependências SaaS.
- **API REST consumidora é trusted**: autenticada por chave SSH; não há multi-tenancy de operadores na API (é o time interno chamando, e clientes finais via abstração da API, não direto).
- **Compliance LGPD aplica** porque hospeda dados pessoais de clientes finais; encriptação Let's Encrypt + MariaDB local atendem mínimo, mas backup off-site criptografado vira P2 imediato.
- **`shared-redis` tem persistência AOF** (ou será habilitada na v12.0) — a fila não pode evaporar em reinício do servidor.
- **HaRP precisa de `docker.sock`** — a única melhoria viável de curto prazo é interpor socket-proxy.
- **Nome do produto interno permanece "Nextcloud SaaS Manager"**; mudança comercial fica para o repo da API.

---

## 9. Dúvidas em Aberto

| # | Dúvida | Impacto | Status |
|---|---|---|---|
| 1 | A API REST consumidora **já existe** em outro repo, **vai ser construída agora** em outro repo, ou ainda **não foi decidido** onde vai morar? | Alto (afeta cronograma de teste integrado) | Aberta |
| 2 | Stack escolhida pela API REST (Laravel / NestJS / FastAPI / outra)? Influencia o cliente SSH (biblioteca) e o formato de webhook esperado | Médio | Aberta |
| 3 | Volume esperado de operações por hora (create/remove/backup) na primeira fase de produção? Afeta decisão de manter sequencial vs. paralelizar por tipo de op | Médio | Aberta |
| 4 | Ao longo do tempo deve-se considerar **rotação automática de chave SSH** do `ncsaas-api` (gerenciada por qual processo)? | Baixo | Aberta |
| 5 | O backup off-site (P2) deve ir para qual provedor? S3 da AWS? Backblaze B2? MinIO próprio? | Médio (P2, fora desta evolução) | Aberta — tratar quando E entrar em sprint |
| 6 | Há SLA contratual com clientes finais? Se sim, qual? Influencia metas de NFR | Médio | Aberta |
| 7 | Existe alguma janela de manutenção pré-acordada com clientes para deploy do v12.0? | Baixo | Aberta |
| 8 | Política de versionamento dos contratos CLI (semver dos flags)? Mudar `--async` no futuro pode quebrar a API | Médio | Aberta — recomendado SemVer formal a partir da v12.0 |

---

## 10. Mapa do Sistema Existente (cenário ANÁLISE)

### Stack identificada

- **Linguagem**: Bash (~2.451 linhas)
- **Orquestração**: Docker Engine 29.x + Docker Compose plugin v2
- **Reverse proxy**: Traefik v3.x (latest) com Let's Encrypt
- **Banco de dados**: MariaDB 10.11 compartilhado (1 database por cliente)
- **Cache / fila futura**: Redis (alpine) compartilhado (1 dbindex por cliente; queue do worker irá em outro dbindex)
- **WebRTC**: coturn (`network_mode: host`), Janus, NATS, Spreed Signaling
- **Office colaborativo**: Collabora Online (multi-tenant via aliasgroup)
- **Recording**: Talk Recording Server (oficial Nextcloud)
- **AppAPI**: HaRP daemon por cliente, monta `docker.sock` RW
- **CI/CD atual**: 5 workflows Beesy (security review, fix CI, coverage, daily digest, PR auto-assign); sem ShellCheck (regressão a corrigir)
- **Tests**: Inexistentes
- **Sistema operacional**: Ubuntu 24.04 LTS (KVM, NÃO LXC)

### Comandos mapeados (contratos CLI atuais)

| Comando | Sintaxe | Síncrono ou Async (proposto v12.0) |
|---|---|---|
| `deploy-server.sh` | `sudo bash scripts/deploy-server.sh --email ... --collabora-domain ... --signaling-domain ... --turn-domain ...` | Sync (one-shot) |
| `create` | `sudo nextcloud-manage <cliente> <dominio> create` | **Async (P0)** |
| `status` | `sudo nextcloud-manage <cliente> _ status` | Sync (read-only) |
| `credentials` | `sudo nextcloud-manage <cliente> _ credentials` | Sync (read-only) |
| `backup` | `sudo nextcloud-manage <cliente> _ backup` | **Async (P0)** |
| `restore` | `sudo nextcloud-manage <cliente> <tar.gz> restore` | **Async (P0)** |
| `update` | `sudo nextcloud-manage <cliente> _ update` | **Async (P0)** |
| `stop` / `start` | `sudo nextcloud-manage <cliente> _ stop\|start` | **Async (P0)** |
| `remove` | `sudo nextcloud-manage <cliente> _ remove` | **Async (P0) + `--confirm`** |
| `list` | `sudo nextcloud-manage list` | Sync (read-only) |
| `health` *(novo)* | `sudo nextcloud-manage health [--json]` | Sync (read-only) |
| `job <id> status` *(novo)* | `sudo nextcloud-manage job <id> status [--json]` | Sync |
| `job <id> logs` *(novo)* | `sudo nextcloud-manage job <id> logs` | Sync (stream) |
| `job <id> cancel` *(novo)* | `sudo nextcloud-manage job <id> cancel` | Sync (só se `queued`) |
| `job list` *(novo)* | `sudo nextcloud-manage job list [--state=...]` | Sync |
| `worker status` *(novo)* | `sudo nextcloud-manage worker status [--json]` | Sync |
| `worker stats` *(novo, Q-3 pós-revisão de layout)* | `sudo nextcloud-manage worker stats [--by-cmd] [--by-client] [--json]` | Sync |
| `job list` *(estendido, Q-1/Q-2/Q-4)* | `sudo nextcloud-manage job list [--state=...] [--cmd=...] [--client=...] [--limit=N] [--offset=N \| --after=<job_id>]` | Sync |
| `user create` *(novo, Feature O.2)* | `sudo nextcloud-manage <cliente> user create <username> [--display-name=...] [--email=...] [--groups=g1,g2] [--quota=5GB] [--payload-stdin]` (body: senha + `subadmin_groups[]`) | **Async (P0)** |
| `user remove` *(novo, Feature O.2)* | `sudo nextcloud-manage <cliente> user remove <username> [--force]` | **Async (P0)** |
| `user modify` *(novo, Feature O.2 estendido)* | `sudo nextcloud-manage <cliente> user modify <username> [--display-name=...] [--email=...] [--add-groups=...] [--remove-groups=...] [--quota=...] [--payload-stdin]` (body: `password`, `add_subadmin[]`/`remove_subadmin[]`, `enable`/`disable`, `resend_welcome`) | **Async (P0)** |
| `group create` *(novo, Feature O.3)* | `sudo nextcloud-manage <cliente> group create <groupname> [--display-name=...]` | **Async (P0)** |
| `group remove` *(novo, Feature O.3)* | `sudo nextcloud-manage <cliente> group remove <groupname> [--force]` | **Async (P0)** |
| `group modify` *(novo, Feature O.3 estendido)* | `sudo nextcloud-manage <cliente> group modify <groupname> [--display-name=...] [--payload-stdin]` (body: `rename` opcional) | **Async (P0)** |
| `apps enable` *(novo, Feature O.4)* | `sudo nextcloud-manage <cliente> apps enable <appid1>,<appid2>,... [--strict]` | **Async (P0)** |
| `apps disable` *(novo, Feature O.4 estendido)* | `sudo nextcloud-manage <cliente> apps disable <appid1>,<appid2>,... [--strict] [--payload-stdin]` (body: `options.remove_after_disable`) | **Async (P0)** |
| `create` *(estendido, Feature O.1)* | `... create [--apps=a,b,c] [--full-apps] [--staging-id=<uuid>] [--payload-stdin]` (anexos via SCP **ou** via body `logo_data_url`/`background_data_url` para ≤256KB) | **Async (P0)** |
| `remove` *(estendido)* | `... _ remove [--force] [--backup-first] [--confirm=<cliente>]` (`--backup-first` encadeia backup antes — composto) | **Async** ou Sync |
| `occ-exec` *(novo, Feature P)* | `sudo nextcloud-manage <cliente> occ-exec <occ-subcmd> [<args>...] [--json] [--payload-stdin] [--staging-id=<uuid>]` (body: `password` ou `branding{...}` com data URLs) | Sync (timeout 60s) |
| **SCP staging** *(novo, Feature O.5)* | `scp -i <api_key> <local_file> ncsaas-api@host:/opt/nextcloud-customers/inbox/<staging-id>/<filename>` | Sync (pré-condição de async com anexos > 256KB) |

### Modelo de dados operacional (inferido)

| Entidade | Onde vive | Campos principais |
|---|---|---|
| **Instância de cliente** | `/opt/nextcloud-customers/<cliente>/` | nome, dominio, db_name, db_user, db_password, redis_dbindex, harp_secret, criada_em |
| **Database do cliente** | MariaDB compartilhado | `nextcloud_<cliente>` |
| **Redis dbindex do cliente** | Redis compartilhado | índice numérico (gerenciado pelo `manage.sh`) |
| **Backend HPB do cliente** | `/opt/shared-services/hpb/signaling.conf` | seção `[backend<N>]` |
| **Allowlist Collabora** | `/opt/shared-services/.env` (`COLLABORA_ALLOWLIST`) | string concatenada de domínios |
| **Job (novo na v12.0)** | Redis: `nc:jobs:<id>` (hash) + `nc:jobs:queue` (list) + arquivo `/opt/nextcloud-customers/jobs/<id>.log` | job_id, cmd, args, state, queued_at, started_at, finished_at, exit_code, idempotency_key, callback_url, log_path, error_msg |
| **Idempotência (novo)** | Redis: `nc:idem:<key>` (string com TTL 24h apontando para `job_id`) | mapping idempotency-key → job_id |

---

## 11. Pontos de Integração (API REST consumidora)

| # | Ponto | Direção | Abordagem | Risco |
|---|---|---|---|---|
| 1 | API → Servidor (invocar `manage.sh`) | Saída da API | SSH + sudoers restrito + chave dedicada | Médio — chave comprometida = controle total dos clientes |
| 2 | Servidor → API (notificar conclusão de job) | Entrada na API | Webhook HTTPS POST com HMAC-SHA256 | Baixo — fallback de polling existe |
| 3 | API → Servidor (consultar status sem webhook) | Saída da API | Polling de `manage.sh job <id> status --json` via SSH | Baixo — operação read-only barata |
| 4 | API → Servidor (cancelar job em fila) | Saída da API | `manage.sh job <id> cancel` | Baixo |
| 5 | API → Servidor (health check) | Saída da API | `manage.sh health --json` (idealmente cron leve a cada 1 min) | Baixo |
| 6 | API → Servidor (passthrough OCC sync) | Saída da API | `manage.sh <cliente> occ-exec <subcmd> ...` via SSH (Feature P) | Médio — drift na allowlist de OCC = bloqueio em produção |
| 7 | API → Servidor (upload de anexos para `create`/branding) | Saída da API | **SCP** para `/opt/nextcloud-customers/inbox/<staging-id>/` (mesma chave SSH; SFTP restrito por path) — Feature O.5. Anexos ≤256KB podem ir inline via `--payload-stdin` (`logo_data_url`/`background_data_url`) — fallback documentado em CONTRACTS.md §3.9.0 | Médio — abuso da inbox para escrita arbitrária; mitigação por chroot/internal-sftp + size limit + GC |
| 8 | API → Servidor (lifecycle de users/groups/apps) | Saída da API | `manage.sh <cliente> user\|group\|apps <verb> ...` via SSH (Feature O) | Médio — mesma superfície da Feature N; senhas via stdin |
| 9 | **Tradução de vocabulários** (`_→-` slug, state, cmd, server routing) | API REST faz tradução em ambos sentidos (CONTRACTS.md §10) | A API REST mantém tabela `customers (api_slug, scripts_slug)` e `clusters (server_ip, ssh_host)` para roteamento. Scripts permanecem agnósticos de HTTP/multi-tenancy/multi-server | Baixo — bem-isolado se documentação seguida |
| 10 | API → Servidor (paginação e filtros de queue) | Saída da API | `manage.sh job list --client=<c> --cmd=<c> --offset=N`; `manage.sh worker stats [--by-cmd]` para counts agregados (Q-1..Q-3) | Baixo — operações read-only |

---

## 12. Riscos e Dívida Técnica catalogada

| # | Risco / dívida | Categoria | Probabilidade | Impacto | Mitigação proposta |
|---|---|---|---|---|---|
| R01 | Sem testes automatizados — refatorar `manage.sh` (1.051 linhas) para suportar `--async` pode quebrar produção | Técnico | Alta | Alto | Feature A entra junto com N (não depois) |
| R02 | `shellcheck.yml` saiu do repo sem registro no changelog | Processo | Confirmada | Médio | Feature B; processo de PR review com checklist |
| R03 | `docker.sock` RW no HaRP — privilégio root no host | Segurança | Confirmada | Alto | Socket-proxy em Feature M |
| R04 | Defaults hardcoded (`SERVER_IP="200.50.151.21"`, `defensys.seg.br`) reescritos via `sed` em deploy | Técnico | Confirmada | Médio | Mover para arquivo de config; validar em testes |
| R05 | `remove` é irreversível e sem confirmação dupla — fat-finger apaga cliente errado | Operacional | Média | Crítico | Feature D: `--confirm=<cliente>` obrigatório no modo síncrono |
| R06 | Sem persistência AOF no Redis — fila some se Redis reiniciar | Técnico | Baixa | Alto (jobs em fila perdidos) | Habilitar AOF no `shared-redis` na v12.0 |
| R07 | Talk/HaRP/Collabora são pontos de falha frequentes (100% do `TROUBLESHOOTING.md`) | Operacional | Confirmada | Médio | Feature C (`health` consolidado); F (observabilidade, P2) |
| R08 | Sem rate limit no SSH do `ncsaas-api` — se a API surtar pode encher a fila | Operacional | Baixa | Médio | `MaxStartups` no `sshd_config` + worker drop quando `queue_depth > 1000` |
| R09 | Dependência de imagens `:latest` em vários shared-services (Collabora, coturn, Janus, signaling, recording) | Técnico | Confirmada | Médio | Pinar por digest na v12.1 (Renovate em P3) |
| R10 | Backup atual depende de espaço local (`/opt/nextcloud-customers/backups/`) — disco cheio = backup falha sem alarme | Operacional | Média | Alto | Feature C inclui check de disco; E (off-site) na P2 |
| R11 | `.env` com senhas em texto puro (DB, Collabora admin, Recording, Signaling) | Segurança | Confirmada | Médio | Feature M migra para `*_FILE` |
| R12 | Logs do worker e dos jobs ficam em journald sem retenção configurada | Operacional | Baixa | Médio | Configurar `SystemMaxUse` em `journald.conf` na v12.0 |
| R-O-1 | OCC allowlist drift — Nextcloud ganha novos OCC subcommands a cada release; lista versionada em `CONTRACTS.md §3.10` pode ficar defasada | Manutenção | Média | Médio (operações legítimas falham) | PR obrigatório com bump de `schema_version` para adicionar; CI lê o contrato e gera o filtro do shim a partir dele (single source of truth) |
| R-O-2 | SCP inbox abusada para escrita arbitrária no servidor (e.g. `scp ... :/etc/passwd`) | Segurança | Baixa | Crítico | `internal-sftp` com `ChrootDirectory /opt/nextcloud-customers/inbox` para o user `ncsaas-api`; `Match User` libera SFTP só nesse path; size limit por arquivo (5MB) e por staging-id (10MB total); GC após 24h sem consumo |
| R-O-3 | Argumentos de `occ-exec` injetam comandos via metacaracteres na hora do `docker exec` | Segurança | Média | Alto | `docker exec <c>-app php occ <subcmd> "${args[@]}"` SEMPRE em modo argv array (nunca string-concat); shim já bloqueia metacaracteres no SSH antes do parse |
| R-O-4 | `occ-exec` falha quando container `<cliente>-app` está parado | Operacional | Média | Baixo | Verificar `docker inspect` antes de `docker exec`; exit 14 com mensagem clara orientando `manage.sh <c> _ start` |
| R-O-5 | `occ-exec` que altera estado roda concorrente com job async no mesmo cliente (e.g. `maintenance:mode --on` durante `update`) | Técnico | Baixa | Médio (corrupção de estado do cliente) | Lock de cliente: antes de `occ-exec`, checar `nc:worker:current` para ver se job no mesmo `client`; bloquear com exit 17 (`client_busy_async_job_running`) |
| R-O-6 | Senha de `user create`/`user modify`/`user:resetpassword` aparece em journald via `ps -ef` ou via argv do shim | Segurança | Alta se via argv | Alto (LGPD breach) | Senha **sempre** via `--payload-stdin` (lê JSON do stdin) ou variável de ambiente injetada pelo shim; scrub agressivo em `lib/output_json.sh::log_event` |
| R-O-7 | Anexos de branding (logo PNG até 5MB cada) + base de clientes crescendo enchem `/opt/nextcloud-customers/jobs/<id>/staging/` ao longo de meses | Operacional | Média | Médio (disco) | Mover staged files para o volume persistente do cliente após consumo (`<cliente>/themes/`); GC do `staging/` em 30d junto com `*.log` (já existe `nextcloud-saas-jobs-gc.timer`) |

---

## 13. Próximos Passos Recomendados

| # | Comando | Por quê |
|---|---|---|
| 1 | ✅ `/arquiteto planejar` *(concluído 2026-05-07)* | `docs/ARCHITECTURE.md` gerado com Redis schema, ADRs, Apêndice A (artefatos canônicos) e Apêndice B (premissas) |
| 2 | ✅ `/arquiteto contratos` *(em andamento 2026-05-07 — expandido com Features O e P)* | `docs/CONTRACTS.md` formaliza contratos CLI/JSON/Callback/OCC/SCP-staging |
| 3 | `/pmo plan` | Quebrar v12.0 em sprints com a expansão de escopo: **S1**=A+B+`manage-cli` refactor base; **S2**=N+D+O (async path completo: queue+worker+ssh+idempotency+lifecycle de user/group/apps)+observability; **S3**=C+M+P (health+socket-proxy+secrets+OCC sync passthrough+SCP staging); **S4**=ajustes pós-piloto |
| 4 | `/pmo sprint` (após plan) | Iniciar Sprint 1 |

---

## Histórico de Revisões

| Data | Versão | Alteração | Autor |
|---|---|---|---|
| 2026-05-06 | 0.1 | Versão inicial — baseline v11.3.4 documentada + Features N/A/B/C/D/M priorizadas para v12.0; arquitetura assíncrona (Redis + worker systemd + SSH dedicado) aprovada pelo usuário | Analista de Requisitos (IA) |
| 2026-05-07 | 0.2 | **Expansão de escopo descoberta durante `/arquiteto contratos`**: API REST consumidora exige 8 endpoints async adicionais (user/group/apps lifecycle) → **Feature O (P0)** + 15 endpoints sync OCC → **Feature P (P0)**. SCP staging para anexos binários adicionado em §10 e §11. Riscos R-O-1..R-O-7 catalogados. Sequência de sprints recomendada para `/pmo plan` revisada em §13 (Feature O entra junto com Feature N no Sprint S2; Feature P entra no Sprint S3). | Analista de Sistemas (IA) via `/arquiteto contratos` |
| 2026-05-07 | 0.3 | **Análise cruzada do layout** (`mework360-api/layout/openapi.yaml` + Stitch design system) revelou ajustes: (a) **C-1**: pattern `<cliente>` de 32 → 64 chars; API REST passa a normalizar `_→-` antes do SSH (§10 ganhou ponto de integração #9). (b) **C-2**: dual base64+SCP — anexos ≤256KB podem ir inline via `--payload-stdin`. (c) **C-3**: `server` field é meta-informação interna da API REST; scripts permanecem single-host (Feature G P3 inalterada). (d) **F-1..F-8**: 8 campos novos descobertos no OpenAPI (subadmin, enable/disable, resend_welcome, rename de grupo, url no branding, --force, --backup-first, remove_after_disable). (e) **Q-1..Q-4**: filtros e paginação para `job list` + `worker stats` para casar com `GET /queue/stats` da API. (f) **Tradução de vocabulários** documentada em CONTRACTS.md §10 (job_id UUID↔int, state↔status com cancelled vs canceled, cmd↔job_type, server routing, slug normalization, apps curation). | Analista de Sistemas (IA) via `/arquiteto contratos` |
