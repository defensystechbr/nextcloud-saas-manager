# Arquitetura — Nextcloud SaaS Manager v12.0

> Gerado em: 2026-05-07
> Fase: 3 — Arquitetura de Solução
> Status: **Aprovada** (em 2026-05-07)
> Cenário: ANÁLISE (evolução brownfield sobre baseline v11.3.4)
> Baseado em: `docs/REQUIREMENTS.md` (v0.1, 2026-05-06)
> Branch de trabalho: `development`
> Versão alvo: **v12.0**

---

## 1. Visão Geral

**Tipo**: **Monolito modular operacional** — coleção coordenada de scripts Bash + Docker Compose + units systemd que compartilham estado via Redis e arquivos `.env` no host. Não há binário único; a "modularidade" é por responsabilidade de processo (CLI, daemon worker, provisionamento, gateway SSH).

**Justificativa**:
- O sistema atual (v11.3.4) já é Bash + Docker Compose, e §7 do REQUIREMENTS proíbe explicitamente troca de stack ("Trocar Bash por outra stack — explicitamente decidido manter").
- O time DevOps é praticamente uma pessoa (Persona "Marcos"); microsserviços ou orquestrador externo (Ansible/Terraform/K8s) são fora de escopo permanente.
- A nova capacidade (consumo por API REST sem bloquear) é puramente um **plano de execução assíncrono** sobre o mesmo binário CLI — não exige novo runtime.
- Padrão "monolito modular" aqui significa: cada módulo tem uma responsabilidade clara, contrato definido (CLI flags + JSON ou chave Redis) e pode ser refatorado independentemente.

**Forças motrizes da v12.0** (de §1 e §4.2 do REQUIREMENTS):
1. Habilitar API REST consumidora a invocar `manage.sh` via SSH **sem timeout HTTP** → modo assíncrono + worker.
2. Eliminar risco de regressão ao refatorar `manage.sh` (1.051 linhas) → suite Bats antes do refactor.
3. Reduzir superfície de ataque do mount RW de `docker.sock` → socket-proxy.
4. Tornar comandos destrutivos seguros e idempotentes → `--dry-run` + `--confirm` + idempotency-key.

---

## 2. Stack Tecnológica

| Camada | Tecnologia | Versão | Justificativa |
|--------|-----------|--------|---------------|
| Linguagem principal | Bash | 5.x (Ubuntu 24.04) | Já em uso, 2.451 LOC; trocar = rebuild fora de escopo |
| Orquestração de containers | Docker Engine + Docker Compose plugin v2 | Engine 29.x / Compose v2.x | Já em uso; Compose v1 standalone aceito como fallback (lógica de auto-detect já existe em `manage.sh:49-57`) |
| Reverse proxy + TLS | Traefik | v3.x | Já em produção, Let's Encrypt automático, sem mudança em v12.0 |
| Banco de dados Nextcloud | MariaDB compartilhado | 10.11 | Já em uso; 1 database por cliente; sem mudança em v12.0 |
| **Fila de jobs** | **Redis (compartilhado)** | **7.x (alpine)** | Já existe como cache do Nextcloud; reaproveitar evita novo container; AOF habilitado em v12.0 para durabilidade da fila |
| **Daemon worker** | **systemd unit** | **systemd 255+ (Ubuntu 24.04)** | Init nativo do host; restart policy, journald, watchdog, controle de recursos sem dependências extras |
| **Hardening Docker socket** | **tecnativa/docker-socket-proxy** | **0.x** (pinado por digest) | Container leve com allowlist de endpoints; reduz privilégio de RW direto no `docker.sock` exposto pelo HaRP |
| **Auth API↔servidor** | **OpenSSH + sudoers restrito** | **OpenSSH 9.x** | Já presente; chave dedicada + `command="…"` + `ForceCommand` + `NOPASSWD` em 1 binário; sem novo serviço HTTP |
| **Notificação assíncrona** | **HTTPS POST + HMAC-SHA256** | — | Padrão webhook simples; `curl` já disponível; sem nova dependência |
| WebRTC | coturn / Janus / NATS / Spreed Signaling | latest pinned por digest a partir de v12.1 | Já em produção, sem mudança funcional |
| Office | Collabora Online | latest | Já em produção |
| Recording | Talk Recording Server | ghcr.io/nextcloud-releases/aio-talk-recording | Já em produção |
| AppAPI | HaRP daemon | release | Já em produção; **interposto por socket-proxy em v12.0** |
| Testes | **Bats-core + bats-assert + bats-support** | 1.10+ | Padrão de facto para Bash; suporta TAP; integra com GitHub Actions |
| Lint | ShellCheck | 0.10+ | Já anunciado no README (regressão); recriar workflow CI |
| CI/CD | GitHub Actions | — | Já em uso (5 workflows Beesy); adicionar `shellcheck.yml` + `bats.yml` |
| Observabilidade | journald + JSON logs | — | Sem novo stack (Loki/Prometheus = P2); `journalctl -u nextcloud-saas-worker -o json` já é estruturado |
| Serialização de saída | `jq` (encoder) | 1.7+ | Geração segura de JSON em Bash sem string-concat manual |
| Geração de UUIDs / segredos | `uuidgen` + `openssl rand` | util-linux + openssl 3.x | Disponíveis no host; sem nova dependência |

**Dependências novas instaladas pelo `deploy-server.sh` em v12.0**: `jq`, `uuidgen` (já vem com `util-linux`), `bats` (apenas em `tests/`, não em produção).

> **Nota sobre `Perfil 1/2` (NestJS/Laravel)**: a skill `arquiteto` documenta perfis de aplicação web. Este projeto usa **perfil "shell"** (declarado em `.cursorsession.perfil`) — provisionamento de servidor + CLI operacional. Skills de implementação aplicáveis neste perfil: `shellcheck` (workflow CI), `bats` (testes), `systemd` (unit files). As skills `nestjs-module`, `laravel-api`, `prisma-workflow`, etc., **não se aplicam**. A API REST consumidora vive em outro repositório com seu próprio perfil.

---

## 3. Estrutura de Pastas

### Repositório (após v12.0)

```
nextcloud-saas-manager/
├── scripts/
│   ├── deploy-server.sh        # provisiona host, instala worker.service, cria ncsaas-api
│   ├── manage.sh               # CLI principal (refatorado: dispatch sync/async + --json + --dry-run)
│   ├── worker.sh               # NOVO — daemon consumidor da fila Redis
│   └── lib/                    # NOVO — funções extraídas (testáveis em isolamento)
│       ├── job_queue.sh        #   helpers de Redis (enqueue, set_state, get_state, idem_lookup)
│       ├── job_runner.sh       #   exec wrappers que rodam comandos sync e devolvem exit code + log
│       ├── ssh_audit.sh        #   logger journald estruturado para invocações SSH
│       ├── output_json.sh      #   helpers jq-based para stdout JSON consistente
│       └── validators.sh       #   parse de --async/--idempotency-key/--callback/--dry-run
├── shared-services/
│   ├── docker-compose.yml      # +1 service: socket-proxy (HaRP passa por ele)
│   ├── setup-shared.sh         # +AOF no Redis, +geração de secrets em /run/secrets
│   ├── recording/
│   ├── socket-proxy/           # NOVO — config docker-socket-proxy (allowlist)
│   │   └── .env.example
│   └── secrets/                # NOVO (gitignored) — *_FILE referenciados no compose
│       └── .gitkeep
├── systemd/                    # NOVO — unit files versionados no repo
│   ├── nextcloud-saas-worker.service
│   ├── nextcloud-saas-worker.env.example
│   └── nextcloud-saas-jobs-gc.timer
├── ssh/                        # NOVO — templates de configuração SSH
│   ├── ncsaas-api.sshd.conf    # snippet de /etc/ssh/sshd_config.d/
│   ├── ncsaas-api.sudoers      # snippet de /etc/sudoers.d/
│   └── authorized_keys.example
├── tests/                      # NOVO — Bats
│   ├── unit/
│   │   ├── test_validators.bats
│   │   ├── test_job_queue.bats
│   │   ├── test_output_json.bats
│   │   └── test_password_gen.bats
│   ├── integration/
│   │   ├── test_create_idempotent.bats
│   │   ├── test_async_dispatch.bats
│   │   └── test_health_command.bats
│   ├── e2e/
│   │   └── test_create_backup_remove.bats   # docker-in-docker
│   └── helpers/
│       ├── setup.bash
│       └── redis_fixture.bash
├── .github/workflows/
│   ├── shellcheck.yml          # NOVO (recriar) — falha em error|warning
│   ├── bats.yml                # NOVO — roda tests/unit + tests/integration em <8 min
│   ├── beesy-*.yml             # já existentes
├── docs/
│   ├── REQUIREMENTS.md         # já existe
│   ├── ARCHITECTURE.md         # este documento
│   ├── ADMINISTRATION.md       # +seção "Operação assíncrona" em v12.0
│   ├── TROUBLESHOOTING.md      # +seção "Worker", "Socket-proxy", "SSH ncsaas-api"
│   ├── CONTRACTS.md            # NOVO — gerado por /arquiteto contratos (CLI + JSON Schema)
│   └── sistema/                # NOVO — hub gerado pela capability docs-hub
│       ├── manifest.json
│       ├── build.js
│       └── index.html
├── .cursor/
│   ├── mcp.json                # NOVO — Playwright MCP (para qa validar)
│   ├── context-brief.yaml      # já existe
│   └── ...
├── .cursorsession              # já existe
└── README.md                   # +seção "Modo assíncrono e API REST consumidora"
```

### No host (runtime — após `deploy-server.sh` v12.0)

```
/opt/
├── nextcloud-customers/
│   ├── manage.sh                                # symlink para /usr/local/bin/nextcloud-manage (já existe)
│   ├── <cliente>/                               # 1 por cliente (já existe)
│   │   ├── docker-compose.yml
│   │   ├── .env                                 # 0600 root:root
│   │   ├── .credentials
│   │   ├── app/                                 # volume Nextcloud
│   │   └── harp-certs/
│   ├── jobs/                                    # NOVO
│   │   ├── <job-uuid>.log                       # stdout/stderr da execução do worker
│   │   └── archive/                             # rotacionado em 30 dias pelo gc.timer
│   └── backups/                                 # já existe
├── shared-services/                             # já existe
│   ├── docker-compose.yml
│   ├── .env                                     # sem secrets em texto puro a partir de v12.0
│   └── secrets/                                 # NOVO — 0600 root:root, montado como /run/secrets
│       ├── db_root_password
│       ├── redis_password
│       ├── collabora_admin_password
│       └── ...
└── nextcloud-saas-worker/                       # NOVO — diretório de trabalho do daemon
    ├── lockfile                                 # flock para garantir 1 instância
    └── .env                                     # config do worker (concorrência, callback secret)

/etc/
├── systemd/system/
│   ├── nextcloud-saas-worker.service            # instalado por deploy-server.sh
│   └── nextcloud-saas-jobs-gc.timer
├── ssh/sshd_config.d/
│   └── 50-ncsaas-api.conf                       # restrição do usuário ncsaas-api
└── sudoers.d/
    └── ncsaas-api                               # NOPASSWD em 1 binário

/var/log/journal/                                # logs do worker e SSH (tags dedicadas)

/usr/local/bin/
└── nextcloud-manage                             # symlink (já existe)
```

> Toda pasta vazia versionada (`shared-services/secrets/`, `scripts/lib/`) leva `.gitkeep`.

---

## 4. Diagrama de Módulos

```
                         ┌──────────────────────────────────┐
                         │  API REST consumidora (outro     │
                         │  repo) — Persona "sistema"       │
                         └────────────────┬─────────────────┘
                                          │ SSH key (ncsaas-api)
                                          │ comando: /usr/local/bin/nextcloud-manage ...
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Servidor Ubuntu 24.04 (KVM)                                                │
│                                                                             │
│   ┌──────────────────────┐    sudo (NOPASSWD, 1 binário só)                 │
│   │  ssh-gateway         │ ─────────────────────────────┐                   │
│   │  (sshd + sudoers)    │                              │                   │
│   └──────────────────────┘                              ▼                   │
│                                          ┌─────────────────────────────┐    │
│                                          │  manage-cli                 │    │
│                                          │  (scripts/manage.sh +       │    │
│                                          │   scripts/lib/*.sh)         │    │
│                                          │                             │    │
│                                          │  - parse_args/validate      │    │
│                                          │  - sync path → cmd_*        │    │
│                                          │  - async path → enqueue     │    │
│                                          │  - --json output via jq     │    │
│                                          │  - --dry-run (read-only)    │    │
│                                          └──────┬───────────┬──────────┘    │
│                                                 │           │               │
│                                  sync           │           │ async         │
│                                  (status,       │           │ (create,      │
│                                   list,         │           │  remove,      │
│                                   credentials,  │           │  backup, ...) │
│                                   health,       │           │               │
│                                   job <id> *)   │           ▼               │
│                                                 │   ┌──────────────────┐    │
│                                                 │   │  shared-redis    │    │
│                                                 │   │  (queue + state) │    │
│                                                 │   │  AOF habilitado  │    │
│                                                 │   └──────┬───────────┘    │
│                                                 │          │ BRPOP          │
│                                                 │          ▼                │
│                                                 │   ┌──────────────────┐    │
│                                                 │   │  worker          │    │
│                                                 │   │  (scripts/       │    │
│                                                 │   │   worker.sh →    │    │
│                                                 │   │   systemd unit)  │    │
│                                                 │   │                  │    │
│                                                 │   │  - dequeue       │    │
│                                                 │   │  - exec cmd_*    │    │
│                                                 │   │  - update Redis  │    │
│                                                 │   │  - HMAC callback │    │
│                                                 │   └──────┬───────────┘    │
│                                                 │          │ docker compose │
│                                                 ▼          ▼                │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │  Plataforma (já existente)                                         │    │
│   │   - shared-services: db, redis, collabora, turn, nats, janus,      │    │
│   │     signaling, recording, +socket-proxy (NOVO)                     │    │
│   │   - <cliente>-app, <cliente>-cron, <cliente>-harp (3 por cliente)  │    │
│   │   - HaRP → socket-proxy → /var/run/docker.sock (NOVO)              │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                                                            │                │
│                                                            │ HTTPS POST     │
│                                                            │ (HMAC-SHA256)  │
│                                                            ▼                │
│                                          callback URL da API consumidora    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Assessment de Módulos

| Módulo | Complexidade | Risco | Flag | Depende de | Desbloqueia | Ordem sugerida |
|--------|-------------|-------|------|------------|-------------|----------------|
| `tests-bats` | 1 — fixtures + casos diretos | 1 — sem efeito em produção | foundation | — | refactor seguro de manage-cli, worker | **Sprint 1** |
| `manage-cli` (refactor) | 3 — 1.051 LOC, 9 comandos, parse de flags novas, --dry-run, --json, lib/* | 3 — coração da operação; quebrar = quebrar produção | complexo + foundation | tests-bats | worker, ssh-gateway, observabilidade | **Sprint 1–2** |
| `idempotency` (subset de manage-cli + worker) | 2 — chave 24h, semântica de conflito | 2 — bug = job duplicado destrutivo | — | manage-cli, worker | API consumidora | **Sprint 2** |
| `worker` (`scripts/worker.sh` + unit) | 3 — daemon, BRPOP, lock, callback HMAC, retry, journald estruturado | 3 — execução privilegiada (sudo) e sequencial; crash = fila parada | complexo | manage-cli, idempotency | API consumidora | **Sprint 2** |
| `ssh-gateway` (sshd_config + sudoers + ncsaas-api user) | 1 — config declarativa | 3 — chave comprometida = controle total | — | manage-cli, worker | API consumidora | **Sprint 2** |
| `observability` (audit log, queue depth, worker status) | 1 — wrappers em journald + JSON | 2 — má observabilidade = incidente cego | foundation | worker | health, qa | **Sprint 2** |
| `health-command` (`manage.sh health`) | 2 — 8 checks paralelos com timeout | 1 — read-only | — | manage-cli, worker, observability | API consumidora (heartbeat) | **Sprint 3** |
| `socket-proxy` (HaRP hardening) | 2 — Compose service + allowlist + smoke test | 2 — quebrar HaRP = ExApps deixam de instalar | — | shared-services existente | Compliance v12.1+ | **Sprint 3** |
| `secrets-file` (migração `.env` → `*_FILE`) | 1 — 7 valores, mecânico | 2 — config errada = container down | — | shared-services | Compliance v12.1+ | **Sprint 3** |
| `ci-shellcheck` (workflow restaurado) | 1 — 1 arquivo YAML | 1 — gate de qualidade | — | — | tests-bats verde | **Sprint 1** |

**Legenda flags**:
- `complexo` = Complexidade 3 OU Risco 3 → mini design doc obrigatório no início do sprint
- `foundation` = Dependido por 3+ módulos → priorizar nos primeiros sprints

**Sequência recomendada (Risk-first)**:
- **Sprint 1 (foundation)**: `tests-bats` + `ci-shellcheck` + `manage-cli` (parte do refactor: extrair `lib/*` sem mudar comportamento; cobertura ≥60%)
- **Sprint 2 (núcleo da v12.0)**: `manage-cli` (parte 2: `--async`/`--dry-run`/`--json`) + `idempotency` + `worker` + `ssh-gateway` + `observability`
- **Sprint 3 (operação + compliance)**: `health-command` + `socket-proxy` + `secrets-file`
- **Sprint 4 (estabilização)**: ajustes pós-piloto da API consumidora, hardening de bordas

> A escolha **Risk-first** se justifica porque (a) a API consumidora é a *raison d'être* da v12.0 — adiar `worker`+`ssh-gateway` adia o valor; (b) `tests-bats` precede o refactor de `manage-cli` para reduzir o risco de regressão; (c) compliance (`socket-proxy`+`secrets`) tem janela de tolerância maior do que onboarding bloqueado.

---

## 5. Decisões Técnicas (ADRs)

> Cada ADR documenta a decisão, ≥2 alternativas (incluindo "manter status quo"), trade-offs aceitos e condição de reversão. ADRs serão registradas em `docs/DECISION-BRIEF.md` (a criar) após aprovação, com IDs `ARCH-001..ARCH-008`.

### ADR-001 — Fila de jobs em Redis (lista + hash) reaproveitando `shared-redis`

- **Status**: Proposta
- **Contexto**: A API REST consumidora não pode bloquear minutos esperando `create`/`update` — precisa de um buffer entre invocação SSH e execução real. O servidor já roda `shared-redis` (alpine) usado pelo Nextcloud (1 dbindex por cliente).
- **Decisão**: Usar **Redis** como fila e armazenamento de estado de jobs. Estruturas:
  - `LPUSH nc:jobs:queue <job_id>` para enfileirar; worker consome com `BRPOP nc:jobs:queue 0`.
  - `HSET nc:jobs:<id> ...` para estado completo.
  - dbindex dedicado (`16` — fora do range alocado a clientes pelo `get_next_redis_db`) **e** prefixo `nc:jobs:*` para coexistir com cache do Nextcloud sem colisão.
  - Habilitar **AOF (`appendonly yes`, `appendfsync everysec`)** para sobreviver a reinício do servidor.
- **Alternativas consideradas**:
  1. **RabbitMQ / NATS dedicado** — descartada: novo container, novo runtime, novo ponto de falha; NATS já existe mas é dedicado a signaling (acoplar = arriscar Talk).
  2. **Fila baseada em arquivo** (diretório `jobs/queue/<id>`) — descartada: race conditions difíceis, sem `BLPOP` equivalente, GC manual, sem TTL nativo.
  3. **Tabela em MariaDB compartilhado** — descartada: schema migration adiciona acoplamento a um banco usado por clientes; latência maior; sem `BRPOP`.
  4. **Status quo (sem fila, SSH bloqueado)** — descartada: viola requisito P0 (latência <2s).
- **Trade-offs aceitos**:
  - **AOF** aumenta I/O em ~10–15% no Redis (aceitável: throughput do worker é baixo, ~10 jobs longos/h).
  - Compartilhar Redis com clientes Nextcloud cria **risco de contenção em incidentes** (memória cheia → cache do Nextcloud também sofre). Mitigado por monitoração de `INFO memory` no `health` e `maxmemory-policy noeviction` no Redis (já é o default).
  - Sem fanout para múltiplos workers — aceitável (concorrência =1 por design, justificado em ADR-002).
- **Condição de reversão**: se o volume crescer >100 jobs/h *ou* a contenção com cache do Nextcloud se manifestar em produção, migrar para RabbitMQ dedicado.
- **Consequências**:
  - (+) Zero novo container, zero novo runtime, AOF resolve durabilidade.
  - (+) Redis 7.x suporta `EXPIRE` nativo no hash → retenção 7 dias após `finished_at` é trivial.
  - (−) Operador precisa entender Redis para troubleshooting da fila (mitigação: `manage.sh worker status` expõe as métricas críticas em JSON).

### ADR-002 — Worker como systemd service único, concorrência sequencial (1 job)

- **Status**: Proposta
- **Contexto**: Operações em `manage.sh` mexem em recursos compartilhados não-transacionais: `signaling.conf`, `COLLABORA_ALLOWLIST`, DDL no MariaDB, allocation de `REDIS_DB` dbindex. Rodar duas em paralelo causa corrupção (ex.: dois `create` ganhando o mesmo dbindex).
- **Decisão**: 1 unit `nextcloud-saas-worker.service`, 1 instância via `flock`, consumo sequencial (`BRPOP`). `WORKER_CONCURRENCY=1` é hardcoded no v12.0 (variável existe na unit para futuro, mas qualquer valor >1 falha a inicialização com erro explícito).
- **Alternativas consideradas**:
  1. **Pool de workers (vários processos lendo a mesma fila)** — descartada: exige reescrever `update_collabora_allowlist`/`update_signaling_backends`/`get_next_redis_db` com locking distribuído (DEL + WATCH/MULTI), o que é fora de escopo da v12.0 e aumenta MTTR.
  2. **Workers especializados por tipo de operação** (1 para `backup/restore`, 1 para `create/update/remove`) — descartada: complexidade extra sem ganho; throughput estimado (10 jobs longos/h) cabe em 1 worker.
  3. **Cron + lock file (sem daemon)** — descartada: latência de pickup = intervalo do cron; sem `BRPOP` (busy wait); sem watchdog do systemd.
  4. **Status quo (sem worker)** — não atende v12.0.
- **Trade-offs aceitos**:
  - Throughput cap de ~10 jobs longos/h. Se o time crescer 10×, exige redesenhar (ADR-001 já antecipa migração).
  - Janela de espera observável quando há fila — exposta em `worker status.queue_depth`.
- **Condição de reversão**: throughput >100 jobs/h em produção sustentado por 30 dias.
- **Consequências**:
  - (+) Sem coordenação distribuída.
  - (+) `Restart=on-failure` + `WatchdogSec=` cobre crashes.
  - (−) Single point of failure no worker; mitigado por systemd e pelo fato de operações sync (`status`, `list`, `health`, `credentials`, `job <id> *`) seguirem disponíveis mesmo com worker down.

### ADR-003 — Autenticação API↔servidor via SSH key + sudoers restrito (sem novo serviço HTTP)

- **Status**: Proposta
- **Contexto**: A API consumidora precisa invocar `manage.sh` no servidor sem (a) abrir uma porta HTTP nova com TLS/auth próprios e (b) sem dar shell completo ao processo automatizado.
- **Decisão**:
  - Criar usuário **`ncsaas-api`** (UID alto, sem shell interativo: `/usr/sbin/nologin`).
  - `~ncsaas-api/.ssh/authorized_keys` aceita uma chave dedicada por API consumidora, com diretivas:
    - `command="/usr/local/bin/ncsaas-api-shim"` (shim valida que o comando solicitado é exatamente `nextcloud-manage <args>`)
    - `no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty`
  - `/etc/sudoers.d/ncsaas-api`: `ncsaas-api ALL=(root) NOPASSWD: /usr/local/bin/nextcloud-manage`
  - `/etc/ssh/sshd_config.d/50-ncsaas-api.conf` aplica `Match User ncsaas-api` com `AllowTcpForwarding no`, `PermitTTY no`, `MaxSessions 4`, `MaxStartups 4:30:8` (rate limit defensivo).
  - Auditoria: o shim escreve em `journald` (tag `ncsaas-api-ssh`) com `caller_key_id`, `command`, `argv`, `client_ip`.
- **Alternativas consideradas**:
  1. **Servidor HTTP REST embarcado (nginx + endpoint Bash)** — descartada: precisa TLS próprio, JWT/HMAC, validação de input em Bash exposta à internet; superfície gigante.
  2. **Mensageria push (cliente push para Redis direto da API)** — descartada: vazaria credenciais de Redis para a API; sem auditoria centralizada.
  3. **Nenhum shim (sudoers + chave SSH livre)** — descartada: sem o shim, qualquer comando pode ser executado; perde validação de argv.
  4. **Mutual TLS (mTLS)** — adiada para v12.1+: exige PKI própria; SSH key resolve com infra existente.
- **Trade-offs aceitos**:
  - Chave SSH é o único fator. Mitigação: rotação manual documentada em `ADMINISTRATION.md`; 2FA fica para v12.1+ (P3 já no roadmap).
  - Shim em Bash é mais 1 binário a manter; mitigação: ≤80 linhas, coberto por Bats.
- **Condição de reversão**: incidente de credencial comprometida ou pedido de compliance para mTLS.
- **Consequências**:
  - (+) Reaproveita SSH; sem nova porta exposta.
  - (+) Auditoria automática via journald.
  - (−) Operador precisa lembrar que mudanças no contrato CLI exigem atualizar a allowlist do shim.

### ADR-004 — Notificação assíncrona via webhook HTTPS HMAC-SHA256 com fallback de polling

- **Status**: Proposta
- **Contexto**: Worker precisa notificar API consumidora ao concluir job. API pode estar offline durante reinícios.
- **Decisão**:
  - Worker faz `POST <callback_url>` com payload JSON; header `X-Signature: sha256=<hex>` calculado sobre o body com `WORKER_CALLBACK_SECRET` (em `/run/secrets/worker_callback_secret`).
  - Retry: 3 tentativas com backoff exponencial (5s, 30s, 5min). Após 3 falhas: marca `callback_failed=true` no hash mas **não** muda o estado real do job (a verdade é o estado do cliente).
  - **Fallback obrigatório**: API pode polar `manage.sh job <id> status --json` a qualquer momento (operação sync, leve).
- **Alternativas consideradas**:
  1. **WebSocket / SSE long-poll** — descartada: complexidade desproporcional; manter Bash → curl; persistência de conexão exigiria daemon HTTP.
  2. **Apenas polling, sem webhook** — descartada: latência média (cliente espera) sobe; gasto de SSH por API; mas mantida como fallback.
  3. **Fila reversa (worker LPUSH em fila lida pela API)** — descartada: API teria que ter acesso direto ao Redis do servidor; vazaria fronteira.
  4. **Sem notificação** — descartada: API teria que polar agressivamente; ruim para UX.
- **Trade-offs aceitos**:
  - Webhook melhor-esforço; em rede ruim, polling vira a regra (aceitável).
- **Condição de reversão**: se polling se mostrar insuficiente em produção, considerar WebSocket em v12.2+.
- **Consequências**: (+) Simples e auditável; (−) API consumidora precisa expor um endpoint público acessível pelo servidor (já é assumido).

### ADR-005 — Idempotência via chave em Redis com TTL de 24h

- **Status**: Proposta
- **Contexto**: API consumidora pode reinvocar `create` por causa de timeout/retry; sem idempotência, cliente vira duplicado.
- **Decisão**:
  - Cliente SSH passa `--idempotency-key=<uuid>` opcional.
  - manage-cli computa `args_hash = sha256(<cmd> + <sorted_args>)` e tenta `SET nc:idem:<key> <job_id>:<args_hash> NX EX 86400`.
  - Se chave existe e `args_hash` bate → retorna o `job_id` antigo, exit 0.
  - Se chave existe e `args_hash` difere → exit 3, `{"error":"idempotency_conflict","existing_job_id":"<id>","existing_args_hash":"…"}`.
  - Sem chave → cria job novo (operador é responsável).
- **Alternativas consideradas**:
  1. **Hash determinístico do comando como chave (sem `--idempotency-key`)** — descartada: dois `backup acme` legitimamente sequenciais teriam o mesmo hash; impede reentrada por design.
  2. **Idempotência por linha de tempo (mesmo cmd em <30s = no-op)** — descartada: heurística frágil.
  3. **Sem idempotência** — descartada: viola critério de aceite Feature N e D.
- **Trade-offs aceitos**: API consumidora **deve** sempre passar a chave em `create`/`update`/`remove`; sem ela, retries são "deduplicados na fé".
- **Condição de reversão**: nenhuma esperada.
- **Consequências**: (+) Simples e testável; chave aparece em `job <id> status`.

### ADR-006 — Saída JSON em todos os comandos via `--json`, schema versionado

- **Status**: Proposta
- **Contexto**: API consumidora precisa parsear estruturas; saída humana atual (cores ANSI, multilinhas) é inconsumível por máquina.
- **Decisão**:
  - Todo comando ganha `--json` (mutuamente exclusivo com cores).
  - `output_json.sh` centraliza geração via `jq -nc` com argumentos seguros (nunca string-concat).
  - Cada payload inclui `"schema_version":"1"` no topo. Mudanças incompatíveis bumpa para `2`.
  - Documentação formal em `docs/CONTRACTS.md` (entregue por `/arquiteto contratos`).
- **Alternativas consideradas**:
  1. **Manter parser texto na API** — descartada: frágil a tradução, cores, mudanças cosméticas.
  2. **Não suportar humano + máquina simultaneamente** — descartada: operador precisa do humano.
- **Trade-offs aceitos**: dobra a superfície de testes (humano + JSON); mitigado por testar JSON via Bats e humano por inspeção.
- **Consequências**: (+) Contrato estável; (−) `jq` vira dependência obrigatória do host.

### ADR-007 — Hardening do `docker.sock` via `tecnativa/docker-socket-proxy` (HaRP)

- **Status**: Proposta
- **Contexto**: HaRP (AppAPI) hoje monta `/var/run/docker.sock:rw` direto no container `<cliente>-harp` (visto em `manage.sh:454`). Isso concede privilégios root no host. AppAPI precisa de subset de endpoints (`/containers/create`, `/containers/<id>/start`, `/images/pull`, `/_ping`).
- **Decisão**:
  - Adicionar 1 service em `shared-services/docker-compose.yml`: `socket-proxy` (`tecnativa/docker-socket-proxy:0.x`), expondo `2375` apenas na rede Docker `shared`.
  - Allowlist via env vars: `CONTAINERS=1, POST=1, IMAGES=1, INFO=1, PING=1` (e `EVENTS=1` se HaRP precisar). Demais endpoints permanecem off por default da imagem.
  - HaRP de cada cliente passa a montar `tcp://socket-proxy:2375` no lugar do socket.
  - Manter um smoke test de instalação de ExApp no Bats e2e.
- **Alternativas consideradas**:
  1. **Status quo** — descartada: vulnerabilidade documentada (R03) e aceita só temporariamente.
  2. **Reescrever HaRP para não precisar do socket** — fora do controle (upstream).
  3. **AppArmor/SELinux profile no socket** — adiado para v12.1+; complementar, não substitui.
- **Trade-offs aceitos**: 1 hop de rede a mais; risco de quebrar instalação de ExApp em uma versão nova do HaRP (mitigado por smoke test em CI).
- **Condição de reversão**: incompatibilidade com HaRP que não possa ser corrigida via allowlist.
- **Consequências**: (+) Reduz superfície drasticamente; (−) Bug futuro em HaRP pode obrigar a relaxar allowlist.

### ADR-008 — Secrets em arquivos `*_FILE` em vez de `.env` puro

- **Status**: Proposta
- **Contexto**: `shared-services/.env` hoje contém `DB_ROOT_PASSWORD`, `REDIS_PASSWORD`, `COLLABORA_ADMIN_PASSWORD`, `SIGNALING_SECRET`, `SIGNALING_HASH_KEY`, `SIGNALING_BLOCK_KEY`, `SIGNALING_INTERNAL_SECRET`, `RECORDING_SECRET`, `TURN_SECRET` em texto puro (R11).
- **Decisão**:
  - Migrar valores sensíveis para `/opt/shared-services/secrets/*` (0600 root:root).
  - Compose usa `secrets:` ou bind-mount em `/run/secrets/<nome>` e a env var deixa de ser `XYZ=valor` para `XYZ_FILE=/run/secrets/<nome>` quando suportado pela imagem.
  - Imagens **não** suportadas (Collabora, Janus, signaling, recording — todas leem env var literal): manter via env var, **mas** ler de arquivo no `setup-shared.sh` antes de `docker compose up` (não persiste no `.env` em texto puro). Este caso fica em `.env` apenas em runtime, regenerado a cada `up`.
- **Alternativas consideradas**:
  1. **Vault / SOPS / sealed-secrets** — fora de escopo (sem orçamento extra, premissa §8 do REQUIREMENTS).
  2. **Status quo** — adia compliance; não aceitável.
- **Trade-offs aceitos**: complexidade no `setup-shared.sh` (ler+exportar); workaround para imagens sem `_FILE` documentado em `ADMINISTRATION.md`.
- **Consequências**: (+) `.env` deixa de aparecer em `docker inspect` com segredos; (−) restore de servidor exige recuperar `secrets/`.

---

## 6. Integrações

| Sistema | Propósito | Direção | Abordagem | Auth | Fallback |
|---------|-----------|---------|-----------|------|----------|
| **API REST consumidora** (outro repo) | Invocar `manage.sh` | Entrada (servidor recebe SSH) | SSH + shim + sudoers + JSON output | Chave SSH dedicada por consumidor (rotacionável); validação de argv no shim | — |
| **API REST consumidora** | Receber notificação de conclusão | Saída (servidor → API) | HTTPS POST + HMAC-SHA256 (`X-Signature`) + retry exponencial | HMAC compartilhado em `/run/secrets/worker_callback_secret` | Polling de `manage.sh job <id> status --json` |
| **Let's Encrypt** | TLS dos domínios de cliente e fixos | Saída | Traefik ACME | — | Já em prod, sem mudança |
| **DNS público dos clientes** | Resolução de domínio | Pré-condição | Verificação `dig +short` em `cmd_create` | — | Continua sendo manual antes do `create` |
| **Docker Hub / GHCR / Quay** | Pull de imagens | Saída | Anônimo (público) | — | Já em prod |
| **Docker Engine** (no host) | Orquestração | Saída do worker | `docker compose` direto pelo `manage.sh` (worker roda como root via systemd) | Filesystem (`/var/run/docker.sock`) — **acesso direto, não via socket-proxy** (worker é trusted) | — |
| **Docker Engine** (a partir de HaRP) | AppAPI pede a Docker | Saída do container HaRP | TCP via `socket-proxy:2375` (NOVO) | Allowlist de endpoints na imagem socket-proxy | — |
| **journald** (host) | Log estruturado de worker e SSH | Saída | `logger` + `printf '%s\n' "$json"` em stdout (capturado pelo systemd) | Identidade do processo | — |

---

## 7. Segurança (derivada das Seções 4, 6 e 2.7)

### 7.1 Classificação de Dados

| Dado | Sensibilidade | Módulo responsável | Proteção |
|------|--------------|-------------------|----------|
| Senha admin Nextcloud (por cliente) | **Alta** | `manage-cli` (geração) + filesystem `<cliente>/.credentials` | `chmod 600`; aparecer em `credentials` só para root local; **nunca** no payload do callback |
| Senha MariaDB do cliente | **Alta** | `manage-cli` + `<cliente>/.env` | `chmod 600`; **nunca** em log nem em JSON de saída |
| Secrets de signaling/recording/turn | **Alta** | `shared-services/.env` (hoje) → `/opt/shared-services/secrets/*` (v12.0) | `0600 root:root`; ADR-008 |
| `WORKER_CALLBACK_SECRET` (HMAC) | **Alta** | `worker` | `0600 root:root` em `/run/secrets/`; ler uma vez no startup do worker |
| `job_id` / `idempotency_key` | Baixa | `manage-cli` + `worker` | UUID v4; sem PII |
| Logs do worker (`<job_id>.log`) | **Média** | `worker` | `0640 root:adm`; rotação 30d via `nextcloud-saas-jobs-gc.timer`; **scrub** automático de senhas geradas (regex `MYSQL_PASSWORD=.*` → `***`) |
| Chave SSH do `ncsaas-api` (lado servidor) | **Alta** | `ssh-gateway` | `~/.ssh/authorized_keys` 0600 `ncsaas-api:ncsaas-api`; chave privada vive na API (fora do repo) |
| Chave SSH do `ncsaas-api` (lado cliente API) | **Alta** | API consumidora (outro repo) | Fora do escopo deste projeto; documentar contrato em `docs/CONTRACTS.md` |
| Conteúdo de instâncias Nextcloud | LGPD | Nextcloud + MariaDB + filesystem `<cliente>/app/` | TLS via Traefik; backup off-site (P2, fora da v12.0); criptografia em repouso é deferida |

### 7.2 Fronteiras de Confiança

| Origem | Destino | Protocolo | Auth | Validação | Rate Limit |
|--------|---------|-----------|------|-----------|------------|
| Internet (qualquer) | sshd (porta 22, user `ncsaas-api`) | SSH | Chave pública (allowlist em `authorized_keys`) | Shim valida argv contra lista permitida | `MaxStartups 4:30:8` no `Match User`; `MaxSessions 4` |
| Internet (browser do cliente final) | Traefik (`websecure`) | HTTPS | Let's Encrypt | Já em prod | Já em prod |
| `manage-cli` (sudo) | `shared-redis:6379` (auth via `REDIS_PASSWORD`, dbindex 16) | TCP rede docker `shared` | Senha do Redis | `nc:jobs:*`, `nc:idem:*` namespaces | — |
| `worker` (root, systemd) | `shared-redis:6379` | TCP rede docker `shared` | Senha do Redis | Idem | — |
| `worker` (root) | `docker.sock` | Filesystem | Permissão de FS (root) | — | — |
| `<cliente>-harp` (container) | `socket-proxy:2375` (rede docker `shared`) — NOVO | TCP | Sem auth (rede privada) | Allowlist na imagem socket-proxy | — |
| `worker` | `<callback_url>` (API consumidora) | HTTPS | HMAC-SHA256 (`X-Signature`) | TLS verifica certificado da API | Backoff 5s/30s/5min |
| Cliente final / Admin Nextcloud | Nextcloud (HTTPS) | HTTPS | Auth do Nextcloud | App-level | App-level |

### 7.3 Top 3 Vetores de Ataque

1. **Vazamento da chave SSH do `ncsaas-api`** (R01.5 derivado de R03/R08)
   - **Impacto**: controle total sobre todas as instâncias (criar/remover/exfiltrar via `backup`).
   - **Mitigação**:
     - Allowlist de argv no shim (`ncsaas-api-shim`) — sem ela, chave comprometida = `bash` no host.
     - Audit log em `journald` (tag `ncsaas-api-ssh`) com `caller_key_id`/`client_ip` para forense.
     - Rotação manual documentada (cmd no `ADMINISTRATION.md`) e *kill-switch*: `usermod -L ncsaas-api` desativa imediatamente.
     - `MaxStartups`/`MaxSessions` impede flood se chave é usada para DoS.
     - 2FA SSH para `ncsaas-api` continua adiado para v12.1+ (registrado).

2. **Exploit em ExApp instalada via HaRP escala para root no host** (R03)
   - **Impacto**: ExApp maliciosa hoje pode chamar `/containers/create` com `Privileged: true` e quebrar a sandbox.
   - **Mitigação**:
     - **Socket-proxy (ADR-007)** com allowlist mínima — `/containers/create` permitido, mas filtros adicionais (env `POST=1` mas `CONTAINERS_CREATE_PRIVILEGED_ALLOWED=0` quando suportado pela imagem).
     - Smoke test em CI confirma que ExApps esperadas (Whiteboard, Recognize, etc.) ainda instalam com a allowlist.
     - AppArmor profile fica para v12.1+ (registrado).

3. **Job destrutivo executado no cliente errado** (R05)
   - **Impacto**: `remove acme` executado quando alvo era `acne` apaga dados reais.
   - **Mitigação**:
     - `--confirm=<cliente>` obrigatório para `remove` síncrono (ADR derivado de Feature D).
     - `--async` aceita reentrada via `--idempotency-key` (ADR-005), evitando duplo `remove` por retry.
     - Backup automático antes de `update` (já existe na v11.3.4); estender para `remove` em v12.1 (registrado em §13 do REQUIREMENTS).
     - Audit log do worker preserva `caller_key_id` + `argv` exato.

### 7.4 Requisitos de Segurança por Módulo

| Módulo | Auth requerido? | Rate limit? | Input validation crítico? | Dados sensíveis manipulados? |
|--------|----------------|-------------|--------------------------|------------------------------|
| `ssh-gateway` (sshd + shim + sudoers) | **Sim** (chave SSH) | **Sim** (`MaxStartups`) | **Sim** (allowlist de comandos no shim) | Chave SSH (validação) |
| `manage-cli` | Implícito (root via sudo) | Não | **Sim** (validar `<cliente>` regex `^[a-z0-9-]{1,32}$`, `<dominio>` FQDN, `--callback` URL HTTPS) | Senhas geradas (logs sanitizados) |
| `worker` | Identidade do processo (root) | Não | **Sim** (rejeitar `cmd` fora da allowlist async) | Idem manage-cli + secret HMAC |
| `idempotency` | — | Não | **Sim** (`<idempotency-key>` regex UUID v4) | — |
| `health-command` | Não (read-only) | Não | Não | Não |
| `socket-proxy` | Sem auth (rede docker privada) | Não | Allowlist de endpoints na imagem | Acesso ao Docker daemon |
| `secrets-file` | Filesystem (root) | Não | — | Todos os secrets shared-services |
| `observability` | Identidade do processo | Não | — | Logs sanitizados (regex de senhas) |
| `tests-bats` | N/A (CI isolado) | Não | — | Fixtures, sem produção |
| `ci-shellcheck` | N/A | Não | — | — |

> O projeto atende **≥ 2 critérios de risco** (multi-tenancy + dados pessoais LGPD + integração externa SSH). Recomenda-se executar `/threat-model` após aprovação para análise aprofundada (não bloqueia v12.0).

---

## 8. Banco de Dados e Infraestrutura de Dados

> Esta seção é normalmente preenchida pelo **Arquiteto de Dados** (`/arquiteto dados`). Para este projeto a maior parte das decisões já está consolidada em produção (MariaDB 10.11 + Redis 7 alpine, ambos em `shared-services/docker-compose.yml`); o que muda em v12.0 é apenas o **uso operacional do Redis para fila de jobs** — detalhado abaixo. Schemas de aplicação Nextcloud não são gerenciados por este repositório.

### 8.1 BD Principal (operacional dos clientes)

- **Escolhido**: MariaDB 10.11 compartilhado, 1 database por cliente (`nextcloud_<cliente>`).
- **Justificativa**: Já em produção; a alternativa PostgreSQL exigiria migração e Nextcloud suporta ambos.

### 8.2 Tier de Infraestrutura

- **Tier**: 1 — Single Node (já em uso).
- **Justificativa**: Servidor único Ubuntu KVM (premissa §8 do REQUIREMENTS); HA é horizonte longo.

### 8.3 Composição

- **Nível**: 1 — Complementar (MariaDB transacional + Redis cache/fila).
- **Componentes operacionais novos da v12.0** (Redis):

| Estrutura Redis | Tipo | TTL | Propósito |
|-----------------|------|-----|-----------|
| `nc:jobs:queue` | LIST | — | Fila FIFO de `job_id` aguardando execução |
| `nc:jobs:<id>` | HASH | `EX 604800` (7 dias) **após** `finished_at` (set em transição de estado) | Estado completo do job |
| `nc:idem:<key>` | STRING `<job_id>:<args_hash>` | `EX 86400` (24h) na criação | Mapping idempotency-key → job_id (ADR-005) |
| `nc:worker:lock` | STRING (com `SET NX EX 60`) | renovado a cada 30s pelo worker | Garante 1 worker (defesa em profundidade ao `flock`) |
| `nc:worker:current` | STRING (`job_id` em execução) | sem TTL (apagado ao final) | Lido por `worker status` |
| `nc:worker:metrics:jobs_today` | STRING (counter `INCR`) | `EX` para meia-noite | Contador exposto em `worker status --json` |

**Schema canônico do `HSET nc:jobs:<id>`** (todas as chaves opcionais quando estado anterior não as define):

| Campo | Tipo | Quando setado | Exemplo |
|-------|------|--------------|---------|
| `schema_version` | string | enqueue | `"1"` |
| `state` | string | enqueue → running → success/failed/canceled | `"queued"` |
| `cmd` | string (allowlist) | enqueue | `"create"` |
| `client` | string | enqueue | `"acme"` |
| `args_json` | string (JSON array) | enqueue | `'["acme","nextcloud.acme.com.br","create"]'` |
| `args_hash` | string (sha256 hex) | enqueue | `"a1b2…"` |
| `idempotency_key` | string ou vazio | enqueue | `"550e8400-e29b-…"` |
| `callback_url` | string ou vazio | enqueue | `"https://api.exemplo/jobs/hook"` |
| `caller_key_id` | string (SHA256 da chave SSH) | enqueue | `"sha256:abc…"` |
| `caller_uid` | string | enqueue | `"1003"` (ncsaas-api) |
| `client_ip` | string | enqueue | `"203.0.113.10"` |
| `queued_at` | string (ISO8601 UTC) | enqueue | `"2026-05-08T14:32:01Z"` |
| `started_at` | string (ISO8601 UTC) | transição para `running` | — |
| `finished_at` | string (ISO8601 UTC) | transição para `success/failed/canceled` | — |
| `exit_code` | string (int) | finished | `"0"` |
| `error_msg` | string | quando `state=failed` | `"timeout waiting for nextcloud"` |
| `log_path` | string | enqueue | `"/opt/nextcloud-customers/jobs/<id>.log"` |
| `summary_json` | string (JSON) | quando `state=success` | `'{"created":["db","containers"],...}'` |
| `callback_attempts` | string (int, INCR) | a cada tentativa de webhook | `"3"` |
| `callback_failed` | string (`"true"`/ausente) | após 3 falhas | `"true"` |
| `callback_last_error` | string | última tentativa | `"connection refused"` |

**Transições de estado válidas** (worker rejeita qualquer outra com erro auditado):

```
queued → running → success
queued → running → failed
queued → canceled                (via `manage.sh job <id> cancel` — só se ainda na fila)
```

**Inicialização do AOF** (executada por `setup-shared.sh` em v12.0):
```
appendonly yes
appendfsync everysec
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
```

### 8.4 Segurança de Dados

- **Conexão app↔Redis**: senha (`REDIS_PASSWORD`) na rede docker `shared`; sem TLS (rede privada do daemon).
- **Encryption at rest**: ainda **não habilitado** no MariaDB (deferido; mitigação operacional via filesystem do servidor).
- **Backups**: automação off-site é P2 (fora da v12.0); para v12.0 o backup local manual via `manage.sh <cliente> _ backup` permanece o mecanismo oficial e cobre a fila Redis indiretamente porque AOF é re-derivável (jobs em fila são best-effort).

---

## 9. Observabilidade

- **Logs**:
  - Worker → stdout/stderr → systemd → journald (tag `nextcloud-saas-worker`), formato JSON estruturado por linha (campos: `ts`, `level`, `event`, `job_id`, `cmd`, `client`, `duration_ms`, `exit_code`).
  - Cada job tem também log "humano" em `/opt/nextcloud-customers/jobs/<id>.log` (saída completa do `manage.sh`); `manage.sh job <id> logs` retorna `cat` deste arquivo.
  - Shim SSH → journald (tag `ncsaas-api-ssh`) com `caller_key_id`, `command`, `argv`, `client_ip`, `accepted|rejected`.
- **Retenção journald**: configurar `/etc/systemd/journald.conf.d/50-nextcloud-saas.conf` com `SystemMaxUse=2G`, `MaxRetentionSec=30day` (ADR derivado de R12 do REQUIREMENTS).
- **Métricas básicas via CLI** (sem stack de métricas em v12.0):
  - `manage.sh worker status --json` → `{"active":true,"queue_depth":N,"current_job":"…","jobs_today":N,"last_failure":{"job_id":"…","at":"…","cmd":"…"}}`.
  - `manage.sh health --json` → estado consolidado de containers, certs, DNS, fila, worker, disco (Feature C).
- **Tracing**: Não.
- **Error tracking**: journald + `manage.sh job <id> logs`. Sentry/Loki/Prometheus = P2 (Feature F, fora desta evolução).

---

## 10. Decisões Técnicas por Módulo

> Esta seção é consumida pelo **planejador de tarefas** (`/pmo plan`) para gerar notas técnicas no `ROADMAP.md`. As decisões são específicas a este projeto Bash/SaaS multi-tenant — nada genérico.

### `manage-cli` (refactor de `scripts/manage.sh`)

**Anti-patterns a evitar:**
- Concatenar JSON via `echo "{\"foo\":\"$var\"}"` — quebra com aspas/quebras de linha em `var`. **Usar `jq -nc --arg foo "$var" '{foo:$foo}'` sempre.**
- Mover lógica para `lib/*.sh` mas continuar exportando variáveis globais (`SHARED_DIR`, `BASE_DIR`) — variáveis globais devem ser parâmetros explícitos das funções extraídas para serem testáveis em isolamento (Bats).
- Fazer `source` de `.env` do cliente sem `set -a` controlado — vaza vars no escopo global e contamina próximos `cmd_*`.
- Adicionar `--async` antes de a fila Redis estar disponível em `setup-shared.sh` — quebra deploys novos.

**Decisões de implementação:**
- Extrair em `scripts/lib/`: `validators.sh`, `output_json.sh`, `job_queue.sh`, `job_runner.sh`, `ssh_audit.sh`. Manter `manage.sh` como dispatcher fino.
- `--async`, `--json`, `--dry-run`, `--idempotency-key=`, `--callback=`, `--confirm=` parseados por `validators.sh::parse_global_flags` que retorna assoc array (Bash 4+; Ubuntu 24.04 tem 5.x).
- Validações com regex compiladas em `validators.sh` (`is_valid_client_name`, `is_valid_fqdn`, `is_valid_uuid_v4`, `is_valid_https_url`).
- Quando `--async` for incompatível com o `cmd` (ex.: `status --async`) → exit 5 com `{"error":"async_not_supported","cmd":"status"}`.
- Operações async-only: `create`, `remove`, `backup`, `restore`, `update`, `stop`, `start` (lista hardcoded em `validators.sh::ASYNC_ALLOWED`).
- Operações sync-only: `status`, `list`, `credentials`, `health`, `worker status`, `job <id> *`.

**Edge cases conhecidos:**
- Cliente passa `--async` mas sem `--json` → mesmo assim retorna JSON (modo async **sempre** é JSON; cores antiANSI no stderr para humano não-API).
- `--dry-run --async` → o **enqueue** não acontece; retorna o JSON descritivo das mudanças que **seriam** feitas, exit 0, sem tocar Redis.
- `--callback` sem `--async` → exit 5 (`callback_requires_async`); webhook só faz sentido para job real.
- Symlink `/usr/local/bin/nextcloud-manage` quebrado após upgrade → `deploy-server.sh` recria.

**Integrações críticas:**
- `manage-cli` → `shared-redis` via `redis-cli` (já presente no host? **adicionar dependência em `deploy-server.sh`**: `apt install -y redis-tools`). Wrapper em `lib/job_queue.sh`.
- `manage-cli` → worker: comunicação **só** por chaves Redis; nunca por sinal/PID.

### `worker` (`scripts/worker.sh` + `systemd/nextcloud-saas-worker.service`)

**Anti-patterns a evitar:**
- Loop em `while true; do redis-cli LPOP …; sleep 1; done` — busy wait. **Usar `BRPOP nc:jobs:queue 0`** (bloqueante).
- Executar `manage.sh` via `bash -c "$cmd"` — vulnerável a injection. **Reconstruir argv como array** a partir de `args_json` no Redis e invocar com `nextcloud-manage "${argv[@]}"`.
- Atualizar Redis hash diretamente via `redis-cli HSET` em loop sem pipeline — overhead de conexão. **Usar `MULTI/EXEC` ou pipeline com aspas escapadas via heredoc**.
- Trapping insuficiente — `SIGTERM` do systemd deve marcar `state=failed` com `error_msg=worker_terminated` e fazer `nc:worker:current` `DEL` antes de sair.

**Decisões de implementação:**
- Loop principal:
  1. `BRPOP nc:jobs:queue 0` → recebe `job_id`.
  2. `SET nc:worker:current <job_id>`; `HSET nc:jobs:<id> state running started_at <iso>`.
  3. Construir `argv` a partir de `HGET nc:jobs:<id> args_json` (parsed por `jq -r '.[]'`).
  4. Executar via `nextcloud-manage "${argv[@]}" --json --no-async-pickup`. Stdout/stderr → `<job_id>.log`. Capturar `exit_code`.
  5. Sanitizar log final (regex `(MYSQL_PASSWORD|NEXTCLOUD_ADMIN_PASSWORD|REDIS_PASSWORD|SIGNALING_SECRET|RECORDING_SECRET|TURN_SECRET)=[^[:space:]]+` → `\1=***`).
  6. `HSET nc:jobs:<id> state success|failed exit_code <n> finished_at <iso> [error_msg ...]; EXPIRE nc:jobs:<id> 604800`.
  7. Disparar callback se `callback_url` definido (worker faz; manage-cli não).
  8. `DEL nc:worker:current`.
- `--no-async-pickup` é uma flag interna que diz ao `manage-cli` para **não** tentar enfileirar de novo (defesa contra recursão se alguém setar `--async` nos args do hash por engano).
- Callback HMAC: `printf '%s' "$body" | openssl dgst -sha256 -hmac "$WORKER_CALLBACK_SECRET" -hex` → `X-Signature: sha256=<hex>`.
- Lock duplo: `flock` em `/opt/nextcloud-saas-worker/lockfile` (host) + `SET nc:worker:lock <pid> NX EX 60` renovado a cada 30s (rede docker).

**Edge cases conhecidos:**
- Worker é morto durante `cmd_create` (`SIGKILL`/OOM) → systemd reinicia; lockfile do `flock` é liberado pelo kernel; lock Redis expira em 60s. Job em `running` continua marcado como `running` até reinício, então primeiro ato do worker no startup é: para qualquer job em `nc:worker:current`, marcar `failed/error_msg=worker_killed` e disparar callback.
- API faz `BRPOP` enquanto worker está em `cmd_create` longo: outras invocações enfileiram normalmente; queue cresce. `worker status` mostra `queue_depth`.
- `cmd_remove` por engano em cliente que não existe → retorna exit 0 com aviso (idempotente, espelha Feature D).
- Disco cheio em `/opt/nextcloud-customers/jobs/` → log truncado; worker continua, mas `health` retorna `WARN`.

**Integrações críticas:**
- worker ↔ docker daemon: **direto** via `/var/run/docker.sock` (worker é trusted, root, dentro do host). Socket-proxy é apenas para HaRP (containers de cliente).
- worker → callback (HTTPS): `curl -fsS --max-time 10 -X POST -H "X-Signature: sha256=…" -H "Content-Type: application/json" -d "$body" "$callback_url"`. Não-2xx → retry.

### `ssh-gateway` (`/etc/ssh/sshd_config.d/50-ncsaas-api.conf` + `/etc/sudoers.d/ncsaas-api` + shim)

**Anti-patterns a evitar:**
- Permitir TTY ou X11 forwarding — pequena janela vira shell completo.
- Confiar em `$SSH_ORIGINAL_COMMAND` sem validar contra allowlist no shim — `command="..."` força um wrapper, mas se o wrapper apenas faz `eval $SSH_ORIGINAL_COMMAND` é como não ter shim. **O shim DEVE chamar `nextcloud-manage` com argv vindo de um parser próprio que rejeita metacaracteres `;|&$\``.
- Esquecer de adicionar `Match User ncsaas-api` — diretivas vazariam para outros usuários.
- Sudoers com wildcard (`/usr/local/bin/*`) — aceita qualquer binário; **fixar exatamente** `/usr/local/bin/nextcloud-manage`.

**Decisões de implementação:**
- Usuário criado por `deploy-server.sh`:
  - `useradd -r -m -d /home/ncsaas-api -s /usr/sbin/nologin ncsaas-api`
  - `mkdir -p ~ncsaas-api/.ssh && chmod 700 ~ncsaas-api/.ssh; chown ncsaas-api: ~ncsaas-api/.ssh`
- `~ncsaas-api/.ssh/authorized_keys` — operador colou a chave pública uma vez; cada linha contém:
  ```
  command="/usr/local/bin/ncsaas-api-shim",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-user-rc ssh-ed25519 AAAAC3... api-prod-2026
  ```
- `/etc/sudoers.d/ncsaas-api` (modo 0440):
  ```
  Defaults:ncsaas-api !requiretty
  Defaults:ncsaas-api log_input=off, log_output=on, logfile="/var/log/ncsaas-api-sudo.log"
  ncsaas-api ALL=(root) NOPASSWD: /usr/local/bin/nextcloud-manage
  ```
  - `log_output=on` grava trilha forense.
- `/etc/ssh/sshd_config.d/50-ncsaas-api.conf`:
  ```
  Match User ncsaas-api
      AllowTcpForwarding no
      X11Forwarding no
      PermitTTY no
      PermitTunnel no
      ForceCommand /usr/local/bin/ncsaas-api-shim
      MaxSessions 4
      MaxStartups 4:30:8
  ```
- **Shim** (`/usr/local/bin/ncsaas-api-shim`, 0755, owned by root):
  1. Lê `$SSH_ORIGINAL_COMMAND`.
  2. Tokeniza com `eval "set -- $SSH_ORIGINAL_COMMAND"` **dentro de subshell isolado** ou parser próprio que rejeita `;|&$\`.
  3. Verifica `argv[0] == "nextcloud-manage"` ou rejeita.
  4. Loga em journald (`logger -t ncsaas-api-ssh -p auth.notice`): `key_id=$(ssh-keygen -lf - <<< "$(cat /proc/self/fd/0)" 2>/dev/null | awk '{print $2}')`, `argv`, `client_ip=$(echo $SSH_CONNECTION | cut -d' ' -f1)`.
  5. `exec sudo -n /usr/local/bin/nextcloud-manage "$@"`.

**Edge cases conhecidos:**
- API esquece de passar `--json` → output é cores ANSI; aceitável (ainda parseable, mas API deve passar `--json`).
- Operador adiciona uma chave nova mas com flags errados (sem `command=`) → next deploy do `deploy-server.sh` faz lint nas chaves e avisa (refatorar `cmd_check_ssh` para isso).
- 50 invocações simultâneas → `MaxStartups 4:30:8` derruba excedentes com banner; API recebe ECONNREFUSED e retenta com backoff (responsabilidade da API).

**Integrações críticas:**
- shim → `nextcloud-manage` (sudo): única superfície confiável.
- shim → journald: única fonte de auditoria de invocações da API.

### `idempotency`

**Anti-patterns a evitar:**
- Computar `args_hash` sobre `$@` sem ordenar — duas chamadas com mesmas opções em ordem diferente seriam tratadas como diferentes. **Ordenar args alfabeticamente antes de hashear, exceto posicionais**.
- Aceitar `--idempotency-key` sem validar formato — chaves arbitrárias colidem com `*` em `KEYS` (que não usaremos, mas defesa em profundidade): exigir UUID v4 estrito.

**Decisões de implementação:**
- `validators.sh::is_valid_uuid_v4` (regex `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).
- `args_hash` = `sha256sum` da concatenação `<cmd>\n<client>\n<dom>\n<sorted_remaining_flags>` (sem `--idempotency-key` nem `--callback`, que são metadados).
- `SET nc:idem:<key> "<job_id>:<args_hash>" NX EX 86400` é a operação atômica; falha de NX → `GET` para ler o valor existente, comparar `args_hash`.

**Edge cases conhecidos:**
- API reusa `--idempotency-key` para `cmd` diferente (ex.: `create` e depois `remove`) com mesma chave → conflito (exit 3); operador deve gerar nova UUID.
- TTL expira durante retry agressivo (24h) → API trata como job novo (aceitável; raro).

**Integrações críticas:**
- `idempotency` é avaliada **antes** do enqueue em `manage-cli`. O worker nunca a consulta diretamente.

### `health-command`

**Anti-patterns a evitar:**
- Rodar checks em série — comando passa de 30s. **Usar `&` + `wait`** com `timeout 5s` por check.
- Falhar o comando inteiro se 1 check secundário falhar — granular: cada check tem `status: ok|warn|fail`; exit code é o pior status.

**Decisões de implementação:**
- 8 checks definidos como funções em `lib/health_checks.sh`: `check_shared_containers`, `check_traefik_certs`, `check_dns_fixed_domains`, `check_recording_welcome`, `check_harp_socket_proxy`, `check_disk`, `check_redis_queue`, `check_worker_active`.
- Saída `--json`: `{"schema_version":"1","checks":[{"name":"...","status":"ok|warn|fail","message":"...","duration_ms":N}],"summary":{"ok":N,"warn":N,"fail":N}}`.
- Cada check tem timeout duro de 5s; `cmd_health` tem timeout total de 10s.

**Edge cases conhecidos:**
- Redis indisponível → `check_redis_queue` = `fail`; demais continuam.
- Worker em `running` há >2h em `cmd_create` → `check_worker_active` = `warn` com `current_job`.

**Integrações críticas:**
- Lê estado direto do Redis e do filesystem; não depende de worker estar vivo (exceto para reportar status do worker).

### `socket-proxy` (HaRP hardening)

**Anti-patterns a evitar:**
- Expor `socket-proxy:2375` na rede `proxy` — só na `shared`. Traefik **não** roteia para ele.
- Permitir `POST` sem qualificar endpoints — abre `/exec` (= shell em qualquer container). **Usar variáveis específicas da imagem**: `CONTAINERS=1 POST=1 IMAGES=1 INFO=1 PING=1 NETWORKS=0 VOLUMES=0 EXEC=0 SECRETS=0 SWARM=0 NODES=0 SERVICES=0 TASKS=0 PLUGINS=0 SYSTEM=0 SESSION=0`.

**Decisões de implementação:**
- Container `socket-proxy` adicionado em `shared-services/docker-compose.yml`; `restart: always`; monta `/var/run/docker.sock:/var/run/docker.sock:ro`.
- HaRP de cada cliente passa a referenciar `tcp://socket-proxy:2375` no lugar de mount direto. Mudança na função `cmd_create` (geração do compose por cliente) — **operação de migração**: `manage.sh upgrade-harp <cliente>` regenera o compose e sobe HaRP de novo.
- Documentar em `TROUBLESHOOTING.md`: se ExApp pifar após upgrade, primeira hipótese é endpoint não-allowlisted.

**Edge cases conhecidos:**
- Versão nova de HaRP precisa de endpoint não previsto → ExApp não instala; erro fica claro no log do socket-proxy (`access denied`).

**Integrações críticas:**
- `<cliente>-harp` → `socket-proxy` (rede `shared`).
- worker continua usando `docker.sock` direto.

### `secrets-file`

**Anti-patterns a evitar:**
- Escrever secrets em `.env` durante runtime e esquecer de apagar — `setup-shared.sh` deve escrever, subir compose, e deixar o `.env` apenas com referências.
- Permissão fraca em `secrets/` — exigir `0600 root:root`; `setup-shared.sh` valida no startup.

**Decisões de implementação:**
- `secrets/` criado por `setup-shared.sh` com `install -d -m 0700 -o root -g root /opt/shared-services/secrets`.
- Cada secret em arquivo próprio (`db_root_password`, `redis_password`, `worker_callback_secret`, etc.).
- Compose: secrets do tipo "imagem suporta `_FILE`" (caso raro entre os used) → `secrets:` block. Secrets do tipo "imagem só lê env literal" (Collabora, signaling, etc.) → `setup-shared.sh` exporta em runtime via `export $(cat /opt/shared-services/secrets/* | …)` antes de `docker compose up`, e o `.env` referencia `${VAR}` sem escrever o valor.

**Edge cases conhecidos:**
- Restore de servidor: operador esquece `secrets/`, containers sobem com secrets vazios, MariaDB rejeita conexão. Documentar em `ADMINISTRATION.md`: backup do `secrets/` é **separado** e crítico.

### `observability`

**Anti-patterns a evitar:**
- Logar JSON e texto na mesma linha — quebra parsers downstream. **Sempre 1 JSON por linha** (NDJSON).
- Logar senhas/tokens — sanitizar **na origem** (no helper, não confiar no consumidor).

**Decisões de implementação:**
- `lib/output_json.sh::log_event` recebe `event=...`, `level=...` e args livres; emite NDJSON em stdout (capturado pelo journald via systemd).
- `journalctl -u nextcloud-saas-worker -o json` retorna campos diretamente.
- `manage.sh worker status --json` lê `nc:worker:current`, `LLEN nc:jobs:queue`, `nc:worker:metrics:jobs_today`, último job com `state=failed` (via SCAN com MATCH limitado a 100).

### `tests-bats`

**Anti-patterns a evitar:**
- Testar `cmd_create` real em CI — exige ambiente Docker completo. **Separar**: unit tests (`lib/*.sh` em isolamento), integration tests (`manage.sh` com Redis fake via `redis-mock` ou container `redis:alpine`), e2e (apenas `tests/e2e/` em job CI separado com docker-in-docker).
- Esquecer de exportar `BATS_LIB_PATH` — `bats-assert`/`bats-support` não carregam.

**Decisões de implementação:**
- Versão Bats: 1.10+ via `bats-core` (apt-get em CI; `npm i -g bats` evitado).
- Helpers em `tests/helpers/setup.bash` setam `PATH` para apontar a `scripts/` e mockam `docker`/`docker compose` quando necessário.
- Cobertura mínima: `lib/validators.sh`, `lib/output_json.sh`, `lib/job_queue.sh` 100% (são puros); `manage.sh` ≥60% das funções (meta).

### `ci-shellcheck`

**Anti-patterns a evitar:**
- Aceitar `severity: error` apenas — `warning` também é gate (REQUIREMENTS §6 manutenibilidade).
- Rodar em `tests/` (Bats tem regras próprias; ShellCheck dá falsos positivos com `assert_*`).

**Decisões de implementação:**
- `.github/workflows/shellcheck.yml`: `koalaman/shellcheck-alpine` + `find scripts shared-services -name "*.sh"`.
- `severity: warning`; falha se houver warning ou error.

---

## 11. Artefatos Gerados

- [x] `docs/ARCHITECTURE.md` (este arquivo) — `/arquiteto planejar`
- [x] Seção 10 "Decisões Técnicas por Módulo" (alimenta `/pmo plan` → `ROADMAP.md`)
- [x] Seção 8.3 com schema canônico de Redis (alimenta `/arquiteto contratos` para JSON Schema formal)
- [ ] `docs/CONTRACTS.md` formal (CLI flags + JSON Schemas + OpenAPI do callback) — **`/arquiteto contratos`** (próximo passo recomendado)
- [ ] `docs/DECISION-BRIEF.md` com ADR-001..ADR-008 (registrar via capability `decision-brief` após aprovação)
- [ ] Detalhamento BD adicional (não necessário — Seção 8 acima é suficiente para v12.0)
- [ ] `.cursor/rules/*.mdc` (`/arquiteto padroes` — opcional para perfil shell)
- [ ] `.github/workflows/shellcheck.yml` + `.github/workflows/bats.yml` + Docker (`/devops planejar`)
- [ ] `systemd/*.service` materializados (`/devops planejar`)
- [ ] `docs/INFRASTRUCTURE.md` (`/devops infra` — opcional; servidor único pode ser documentado em `ADMINISTRATION.md`)

---

## Apêndice A — Artefatos materializados (referência canônica)

Os trechos abaixo são a **fonte de verdade** que o `/devops planejar` (Fase 7) materializará em `systemd/`, `ssh/` e `shared-services/socket-proxy/`. Estão aqui para que o arquiteto, o planejador e o implementador conversem sobre o mesmo recorte.

### A.1 `systemd/nextcloud-saas-worker.service`

```ini
[Unit]
Description=Nextcloud SaaS Manager — async job worker
Documentation=file:/opt/nextcloud-customers/manage.sh
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/nextcloud-saas-worker
EnvironmentFile=/opt/nextcloud-saas-worker/.env
# WORKER_CALLBACK_SECRET vem de /run/secrets via LoadCredential
LoadCredential=callback_secret:/opt/shared-services/secrets/worker_callback_secret

ExecStart=/bin/bash /opt/nextcloud-customers/scripts/worker.sh
ExecStop=/bin/kill -TERM $MAINPID

# Resiliência
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=10
WatchdogSec=120
NotifyAccess=main

# Hardening (defesa em profundidade — worker precisa de root para docker.sock)
NoNewPrivileges=false
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/nextcloud-customers /opt/shared-services /var/run/docker.sock
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
LockPersonality=true

# Recursos — evita worker travado de comer memória
MemoryMax=2G
TasksMax=4096
LimitNOFILE=65536

# Logging estruturado — journald captura stdout/stderr; identifica como JSON
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nextcloud-saas-worker

[Install]
WantedBy=multi-user.target
```

> Observação: `ProtectSystem=full` é compatível com `ReadWritePaths` listando os diretórios que o worker precisa modificar. Se um teste de fumaça em staging mostrar que algum `cmd_*` precisa escrever fora dessa lista, **adicionar à lista** (não relaxar para `false`).

### A.2 `systemd/nextcloud-saas-worker.env.example`

```bash
# Concorrência: v12.0 só aceita 1. Reservado para futuro.
WORKER_CONCURRENCY=1

# dbindex do Redis dedicado para a fila (fora do range alocado a clientes)
WORKER_REDIS_DB=16

# Hostname do Redis (alcançável via rede docker shared)
WORKER_REDIS_HOST=shared-redis
WORKER_REDIS_PORT=6379

# Timeout duro por job (15 min cobre cmd_create normal; ajustar se update demorar mais)
WORKER_JOB_TIMEOUT_SEC=1800

# Diretório de logs por job
WORKER_JOBS_DIR=/opt/nextcloud-customers/jobs

# Política de callback
WORKER_CALLBACK_TIMEOUT_SEC=10
WORKER_CALLBACK_RETRIES=3
# Backoff em segundos: 5,30,300
WORKER_CALLBACK_BACKOFF=5,30,300
```

### A.3 `systemd/nextcloud-saas-jobs-gc.timer` + `.service`

```ini
# nextcloud-saas-jobs-gc.timer
[Unit]
Description=Garbage-collect logs antigos de jobs (>30 dias)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
```

```ini
# nextcloud-saas-jobs-gc.service
[Unit]
Description=Limpa /opt/nextcloud-customers/jobs/*.log com mtime > 30 dias

[Service]
Type=oneshot
ExecStart=/usr/bin/find /opt/nextcloud-customers/jobs -maxdepth 1 -type f -name '*.log' -mtime +30 -delete
ExecStartPost=/usr/bin/find /opt/nextcloud-customers/jobs -maxdepth 1 -type f -name '*.log.gz' -mtime +90 -delete
```

### A.4 `ssh/50-ncsaas-api.sshd.conf` (drop-in para `/etc/ssh/sshd_config.d/`)

```sshd_config
Match User ncsaas-api
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    AllowAgentForwarding no
    GatewayPorts no
    ForceCommand /usr/local/bin/ncsaas-api-shim
    MaxSessions 4
    MaxStartups 4:30:8
    LoginGraceTime 15s
    ClientAliveInterval 30
    ClientAliveCountMax 2
```

### A.5 `ssh/ncsaas-api.sudoers` (drop-in para `/etc/sudoers.d/`)

```sudoers
Defaults:ncsaas-api !requiretty
Defaults:ncsaas-api log_input=off, log_output=on, logfile="/var/log/ncsaas-api-sudo.log"
Defaults:ncsaas-api use_pty
Defaults:ncsaas-api env_reset

ncsaas-api ALL=(root) NOPASSWD: /usr/local/bin/nextcloud-manage
```

> Validar com `visudo -c -f /etc/sudoers.d/ncsaas-api` antes de instalar.

### A.6 `ssh/authorized_keys.example` (modelo para `~ncsaas-api/.ssh/authorized_keys`)

```
# Uma linha por chave; cada linha tem TODOS os flags abaixo.
# Substitua AAAAC3...key... pela chave pública real.
# O comment final (api-prod-2026) ajuda na rotação e auditoria.

command="/usr/local/bin/ncsaas-api-shim",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-user-rc ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...key... api-prod-2026
```

### A.7 Esqueleto do `ncsaas-api-shim` (referência — implementação no Sprint 2)

```bash
#!/bin/bash
# /usr/local/bin/ncsaas-api-shim
# Shim que recebe o comando original via $SSH_ORIGINAL_COMMAND, valida,
# audita e invoca nextcloud-manage via sudo.
set -euo pipefail

# Auditoria estruturada (sempre, antes de qualquer rejeição)
KEY_ID="${SSH_USER_AUTH:-unknown}"   # systemd >=255: chave usada na auth
CLIENT_IP="${SSH_CONNECTION%% *}"
ORIG="${SSH_ORIGINAL_COMMAND:-}"
logger -t ncsaas-api-ssh -p auth.notice \
  "{\"event\":\"invoke\",\"key_id\":\"$KEY_ID\",\"client_ip\":\"$CLIENT_IP\",\"command\":\"$ORIG\"}"

# Rejeitar metacaracteres antes de qualquer parse
if [[ "$ORIG" == *[';|&$`'"$'\\\\'"']* ]]; then
  logger -t ncsaas-api-ssh -p auth.warning "{\"event\":\"reject\",\"reason\":\"metachar\",\"command\":\"$ORIG\"}"
  echo '{"error":"invalid_command","message":"metacharacter detected"}' >&2
  exit 100
fi

# Tokenizar com IFS controlado
read -r -a ARGV <<< "$ORIG"

# Primeiro token DEVE ser o comando esperado
if [ "${ARGV[0]:-}" != "nextcloud-manage" ]; then
  logger -t ncsaas-api-ssh -p auth.warning "{\"event\":\"reject\",\"reason\":\"binary_not_allowed\",\"argv0\":\"${ARGV[0]:-}\"}"
  echo '{"error":"command_not_allowed"}' >&2
  exit 101
fi

unset 'ARGV[0]'
exec sudo -n /usr/local/bin/nextcloud-manage "${ARGV[@]}"
```

### A.8 `shared-services/socket-proxy/` — service no `docker-compose.yml`

```yaml
  # NOVO em v12.0 — interpor entre HaRP e o Docker daemon
  socket-proxy:
    image: tecnativa/docker-socket-proxy:0.3.0
    container_name: shared-socket-proxy
    restart: always
    privileged: true                 # exigência da imagem para ler o socket
    environment:
      # Allowlist mínima para AppAPI/HaRP funcionar
      CONTAINERS: 1
      IMAGES: 1
      INFO: 1
      PING: 1
      EVENTS: 1
      NETWORKS: 1
      VOLUMES: 1
      POST: 1
      # Tudo o mais explicitamente OFF
      EXEC: 0
      SECRETS: 0
      SWARM: 0
      NODES: 0
      SERVICES: 0
      TASKS: 0
      PLUGINS: 0
      SYSTEM: 0
      SESSION: 0
      DISTRIBUTION: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - shared
    # Não expor porta no host; só rede shared interna
```

> Em `cmd_create`, o template do compose por cliente passa a referenciar `tcp://socket-proxy:2375` para o HaRP no lugar de `/var/run/docker.sock`. Migração para clientes existentes via novo subcomando `manage.sh upgrade-harp <cliente>` (Sprint 3).

---

## Apêndice B — Premissas e dúvidas em aberto que afetam a arquitetura

Estas dúvidas vêm de §9 do `REQUIREMENTS.md` e são relevantes para a arquitetura. **Nenhuma bloqueia a aprovação desta proposta**, mas três delas (#1, #2, #8) podem virar ADRs adicionais quando respondidas.

| # | Dúvida | Premissa adotada na arquitetura (até resposta do usuário) | Sinal de revisão |
|---|--------|----------------------------------------------------------|------------------|
| 1 | Onde vive a API REST consumidora | Outro repositório, sob controle do mesmo time; URL do callback é HTTPS pública | Se for self-hosted no mesmo servidor: aceitar `http://localhost:...` no `--callback` (revisar validador) |
| 2 | Stack da API (Laravel/NestJS/FastAPI) | Irrelevante para este projeto — o contrato é SSH+JSON+HMAC, agnóstico de stack | Se cliente SSH usado for `phpseclib` ou similar com quirks, talvez precise relaxar `MaxSessions` |
| 3 | Volume esperado de operações/h | Capacidade calculada para ~10 jobs longos/h (ADR-002) | >100/h por 30d → ADR-002 reverte para pool |
| 4 | Rotação automática de chave SSH | Manual via `ADMINISTRATION.md` na v12.0 | v12.1+ candidata: hook quinzenal via cron |
| 5 | Provedor de backup off-site (P2) | Fora da v12.0 | Tratada quando E entrar em sprint |
| 6 | SLA contratual com clientes | Sem SLA formal assumido; metas NFR de §6 do REQUIREMENTS são internas | SLA contratual <99.9% pode exigir HA (revisa Tier 8.2) |
| 7 | Janela de manutenção pré-acordada | Assume 4h/mês (§6 NFR) | Se janela menor, escalonar `cmd_update` para canary (Feature H) |
| 8 | Versionamento dos contratos CLI | `schema_version=1` em todo JSON (ADR-006). SemVer dos flags formalizado em `docs/CONTRACTS.md` | Mudança breaking → bump major na próxima release |

---

## Histórico de Revisões

| Data | Versão | Alteração | Autor |
|------|--------|-----------|-------|
| 2026-05-07 | 0.1 | Proposta inicial — perfil shell adaptado; Redis schema (queue + hash + idem + lock), systemd unit completa (com hardening), SSH gateway (sshd + sudoers + shim), CLI/JSON contracts esboçados; 8 ADRs com alternativas e trade-offs; assessment de 10 módulos com sequência risk-first; apêndice A com artefatos canônicos | Arquiteto de Soluções (IA) |
| 2026-05-07 | 1.0 | **Aprovada pelo usuário**. Próximo passo escolhido: `/arquiteto contratos` para gerar `docs/CONTRACTS.md` formal (CLI flags + JSON Schemas + OpenAPI do callback HMAC). Registro de ADR-001..ADR-008 em `docs/DECISION-BRIEF.md` permanece pendente (capability `decision-brief`). | Arquiteto de Soluções (IA) |
