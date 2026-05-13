# Nextcloud SaaS Manager v12.2

Scripts para implantar e gerenciar uma plataforma Nextcloud SaaS multi-tenant com Docker, Traefik e Let's Encrypt. Suporta execução síncrona e assíncrona via fila Redis, com gateway SSH seguro para consumo por APIs REST externas.

## Índice de Documentação

| Documento | Conteúdo |
|---|---|
| [SSH-API-REFERENCE.md](docs/SSH-API-REFERENCE.md) | **Referência completa para APIs REST consumidoras** — comandos, flags, jobs assíncronos, idempotência, shim, webhooks, mapeamento REST↔SSH |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Módulos, ADRs e topologia v12.0 |
| [CONTRACTS.md](docs/CONTRACTS.md) | CLI, JSON Schemas, callback HMAC, Redis e integração API |
| [REQUIREMENTS.md](docs/REQUIREMENTS.md) | Escopo funcional, NFRs, riscos e premissas |
| [INFRASTRUCTURE.md](docs/INFRASTRUCTURE.md) | Tier 1 Proxmox/Ubuntu 24.04, firewall, storage e runbook |
| [ADMINISTRATION.md](docs/ADMINISTRATION.md) | Operação diária, worker, fila, staging e hardening |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Diagnóstico de worker, SSH, socket-proxy e clientes |
| [ROADMAP.md](docs/ROADMAP.md) | Sprints D1-D5 e gates de release |

---

## Changelog

| Versão | Data | Principais Mudanças |
|:-------|:-----------|:--------------------|
| **v12.2** | 2026-05-13 | **Fixes de produção:** `legacy_helpers.sh` — `update_collabora_allowlist`, `update_signaling_backends` e `update_recording_backends` agora usam `\|\| log_warning` e `return 1` em vez de `exit 1`/bare command, tornando falhas de recarga de serviços compartilhados não-fatais para jobs create/remove/restore. `shared-services/docker-compose.yml` — rede `shared` declarada como `external: true` para corrigir erro de label do Docker Compose v2 em redes criadas manualmente. `scripts/lib/dispatch.sh` — `remove --async` agora inclui `--force` no `args_json` gravado no Redis. `scripts/worker.sh` — `RETURN` trap usa `kill ... \|\| true` para evitar crash loop quando processo renew já finalizou. `scripts/manage.sh` — loop de instalação de apps detecta "already installed" e sai do retry; `MANAGE_SCRIPT_DIR` resolvido via `readlink -f` para funcionar via symlink. |
| **v12.1** | 2026-05-10 | **Fixes de estabilidade:** caminhos `WORKER_JOBS_DIR` corrigidos para `/opt/nextcloud-customers/jobs` em `manage.sh`, `worker.sh`, `job_queue.sh` e `feature_o_ext.sh`. `setup-worker.sh` reescrito para criar dirs, copiar scripts+libs, gerar secrets e injetar `WORKER_REDIS_PASS`. `nextcloud-saas-worker.service` — `StartLimitIntervalSec/Burst` movidos para `[Unit]`, `NotifyAccess=all` para watchdog funcionar com subshells, paths alinhados. `job_queue.sh` — `_redis_exec` usa `docker exec shared-redis redis-cli` quando `redis-cli` não está no host; flag `-i` removida do `docker exec`. |
| **v12.0** | 2026-05-08 | Release v12.0: modo assíncrono Redis + worker systemd + SSH gateway, lifecycle de users/groups/apps (Feature O), staging SCP/SFTP para anexos, OCC sync passthrough allowlisted (Feature P), client-lock, health consolidado, socket-proxy para HaRP, secrets em arquivos e documentação operacional/contratual completa. |
| **v12.0-dev** | 2026-05-08 | **Sprint D2 — Async Core:** Modo assíncrono completo via Redis queue + worker systemd + SSH gateway dedicado. `--async --json --idempotency-key --callback` em todos os comandos ASYNC_ALLOWED. Worker daemon (`nextcloud-saas-worker.service`) com BRPOP, callback HMAC-SHA256 e retry 5/30/300s. SSH gateway `ncsaas-api` (nologin + shim + sudoers) para consumo via API REST. Observabilidade NDJSON em journald (tags: `ncsaas-api-ssh`, `nextcloud-saas-worker`). Subcomandos: `worker status/stats`, `job <id> status/logs/cancel`, `job list`. |
| **v12.0-dev** | 2026-05-07 | **Sprint D1 — Foundation:** Suite Bats (unit + integration), lib/* (validators, output_json, job_queue, job_runner, ssh_audit, legacy_helpers), CI (shellcheck.yml, bats.yml, contracts-check.yml), manage.sh refatorado, systemd units, SSH configs, socket-proxy env, occ_bridge skeleton. |
| **v11.3** | 2026-05-04 | Fixes HaRP, recording, bootstrapping, segurança. |
| **v11.0** | 2026-04-30 | Nova arquitetura compartilhada: 3 containers/cliente + 8 serviços globais. |

---

## Visão Geral da Arquitetura

### Componentes

| Componente | Descrição |
|---|---|
| **Servidor Host** | Ubuntu 24.04 LTS (KVM obrigatório, não LXC) |
| **Orquestração** | Docker Engine 29.x + Docker Compose plugin v2 |
| **Reverse Proxy** | Traefik v3.x com Let's Encrypt automático |
| **Gerenciamento** | `nextcloud-manage` v12.0 (CRUD de instâncias + fila async) |
| **Worker daemon** | `nextcloud-saas-worker.service` (systemd, processa jobs Redis) |
| **Gateway SSH** | Usuário `ncsaas-api` + shim de segurança para APIs REST |
| **Fila** | Redis DB 16 (`nc:` prefix), worker com BRPOP |
| **Isolamento** | 3 containers/cliente + 8 serviços compartilhados globais |

### Fluxo de uma operação assíncrona

```
REST API (seu projeto)
    │
    │  SSH como ncsaas-api (chave Ed25519)
    ▼
ncsaas-api-shim          ← valida verbos, rejeita injeção, audita
    │
    └─► sudo nextcloud-manage <client> <domain> <cmd> --async --json
              │
              └─► Redis DB 16: LPUSH nc:jobs:queue <job_id>
                       │
              nextcloud-saas-worker (systemd)
                       │
                       └─► executa cmd → grava log → POST callback HMAC
```

### Serviços no servidor

**8 containers compartilhados (globais):**

| Container | Função |
|---|---|
| `shared-db` | MariaDB — 1 database isolado por cliente |
| `shared-redis` | Redis — 1 dbindex por cliente + DB 16 para fila |
| `shared-collabora` | Collabora Online (multi-domínio via allowlist) |
| `shared-turn` | coturn STUN/TURN para WebRTC (network_mode: host) |
| `shared-nats` | Message broker para Signaling |
| `shared-janus` | WebRTC media server para Talk |
| `shared-signaling` | Talk High Performance Backend (multi-tenant) |
| `shared-recording` | Talk Recording Server (multi-backend) |

**3 containers por cliente:**

| Container | Função |
|---|---|
| `<client>-app` | Nextcloud com Apache/PHP |
| `<client>-cron` | Background jobs (`cron.sh`) |
| `<client>-harp` | Daemon AppAPI (HaRP) via socket-proxy |

### DNS necessários

**Domínios globais** (configurar antes do deploy do servidor):
- `collabora-01.SEU-DOMINIO.com.br` → IP do servidor
- `signaling-01.SEU-DOMINIO.com.br` → IP do servidor
- `turn-01.SEU-DOMINIO.com.br` → IP do servidor

**Por cliente** (configurar antes de criar cada instância):
- `nextcloud.cliente.com.br` → IP do servidor (1 registro A por cliente)

---

## Deploy de um Novo Servidor

### Pré-requisitos

| Requisito | Detalhe |
|---|---|
| **Sistema** | Ubuntu 24.04 LTS (instalação limpa) |
| **Virtualização** | KVM/QEMU — **NÃO use LXC** (incompatível com Docker 29.x) |
| **Acesso** | Root ou sudo sem senha |
| **Portas** | 80 (HTTP), 443 (HTTPS) livres |
| **DNS** | Domínios globais já apontando para o IP antes do deploy |

### Passo 1: Clonar o repositório

```bash
git clone https://github.com/SoftwareBeesy/mework360-deploy-scripts.git
cd mework360-deploy-scripts
```

### Passo 2: Executar o deploy

```bash
sudo bash scripts/deploy-server.sh \
    --email seu-email@dominio.com \
    --collabora-domain collabora-01.SEU-DOMINIO.com.br \
    --signaling-domain signaling-01.SEU-DOMINIO.com.br \
    --turn-domain turn-01.SEU-DOMINIO.com.br
```

O script instala Docker, configura Traefik, sobe os 8 serviços compartilhados e instala `nextcloud-manage` em `/usr/local/bin/`.

### Passo 3: Instalar o worker assíncrono

```bash
sudo bash scripts/setup-worker.sh
sudo systemctl enable --now nextcloud-saas-worker
sudo systemctl status nextcloud-saas-worker
```

### Passo 4: Configurar o gateway SSH (para APIs REST)

```bash
sudo bash scripts/setup-ssh-gateway.sh
```

Isso cria o usuário `ncsaas-api`, instala o shim de segurança e configura o `sshd`. Veja a seção [Gateway SSH](#gateway-ssh-ncsaas-api-shim) abaixo.

---

## Administrando Instâncias

Use `nextcloud-manage` (disponível globalmente após o deploy):

```
sudo nextcloud-manage <cliente> <domínio|_> <comando> [flags]
```

### Comandos disponíveis

| Comando | Sintaxe | Async? |
|---|---|---|
| `create` | `nextcloud-manage acme cloud.acme.com create` | Sim |
| `remove` | `nextcloud-manage acme _ remove --force` | Sim |
| `status` | `nextcloud-manage acme _ status` | Não |
| `credentials` | `nextcloud-manage acme _ credentials` | Não |
| `backup` | `nextcloud-manage acme _ backup` | Sim |
| `restore` | `nextcloud-manage acme /path/backup.tar.gz restore` | Sim |
| `stop` | `nextcloud-manage acme _ stop` | Sim |
| `start` | `nextcloud-manage acme _ start` | Sim |
| `update` | `nextcloud-manage acme _ update` | Sim |
| `backup-offsite` | `nextcloud-manage acme _ backup-offsite` | Não |
| `health` | `nextcloud-manage health --json` | Não |
| `list` | `nextcloud-manage list` | Não |

### Flags globais

| Flag | Descrição |
|---|---|
| `--async` | Enfileira o job em vez de executar sincronamente |
| `--json` | Saída estruturada JSON (obrigatório para APIs) |
| `--dry-run` | Simula sem efeitos colaterais |
| `--idempotency-key=<uuid>` | Deduplicação de jobs (janela 24h) |
| `--callback=<url>` | Webhook HTTPS ao completar o job |
| `--force` | Pula confirmação interativa (ex: remove) |
| `--payload-stdin` | Lê payload JSON de stdin (para senhas) |

### Exemplo: criar instância

```bash
# Síncrono (bloqueia ~10 min)
sudo nextcloud-manage acme cloud.acme.com.br create

# Assíncrono (retorna em <2s, worker executa em background)
sudo nextcloud-manage acme cloud.acme.com.br create --async --json \
  --idempotency-key=$(uuidgen | tr '[:upper:]' '[:lower:]') \
  --callback=https://sua-api.com/webhooks/jobs
```

### Monitorar jobs

```bash
# Listar todos os jobs
nextcloud-manage job list --json

# Status de um job específico
nextcloud-manage job <job_id> status --json

# Logs de um job
nextcloud-manage job <job_id> logs

# Cancelar job em fila
nextcloud-manage job <job_id> cancel

# Status do worker
nextcloud-manage worker status --json
nextcloud-manage worker stats --by-cmd --by-client --json
```

---

## Gateway SSH — `ncsaas-api-shim`

O `ncsaas-api-shim` é o portão de segurança entre uma API REST externa e o `nextcloud-manage`. Sem ele, a chave SSH daria acesso shell root ao servidor.

### Como funciona

```
API REST → SSH como ncsaas-api → shim → sudo nextcloud-manage
                                  ↑
                    Valida: sem metacaracteres de shell
                            argv[0] == nextcloud-manage
                            verbo na allowlist
                            sem --password em argv
                    Audita: NDJSON em journald (tag: ncsaas-api-ssh)
```

**Três camadas de proteção redundantes:**
1. `authorized_keys` com `command="/usr/local/bin/ncsaas-api-shim"` — bloqueia shell mesmo que sshd falhe
2. `sshd ForceCommand` em `/etc/ssh/sshd_config.d/50-ncsaas-api.conf`
3. `sudoers` restrito: `ncsaas-api` só pode executar `/usr/local/bin/nextcloud-manage`

### Uso pela API REST

```bash
# Em vez de ssh root@servidor (inseguro), usar:
ssh -i /path/to/api_key ncsaas-api@servidor \
  "nextcloud-manage acme cloud.acme.com create --async --json"
```

A sintaxe do comando é idêntica. Só muda o usuário SSH.

### Audit log

```bash
# Monitorar em tempo real
journalctl -t ncsaas-api-ssh -f

# Ver rejeições
journalctl -t ncsaas-api-ssh | grep '"reject"'
```

Cada linha contém `key_id` (fingerprint SHA256 da chave), IP do cliente e o comando sanitizado (senhas mascaradas com `***`).

### Kill-switch de emergência

```bash
usermod -L ncsaas-api   # Desabilita acesso imediatamente
```

> Para documentação completa do shim (instalação, allowlist, rotação de chaves, tabela de diretivas sshd), veja [SSH-API-REFERENCE.md — Seção 1.5](docs/SSH-API-REFERENCE.md#15-o-ncsaas-api-shim--portão-de-segurança-ssh).

---

## Integrando com uma API REST

> **Para IAs implementando a API REST:** leia o [SSH-API-REFERENCE.md](docs/SSH-API-REFERENCE.md) — documento completo com todos os comandos, saídas JSON, ciclo de vida de jobs, idempotência, webhooks e mapeamento REST→SSH.

### Mapeamento de endpoints sugerido

| Endpoint REST | Comando SSH |
|---|---|
| `POST /tenants` | `create --async --json --idempotency-key=<uuid>` |
| `DELETE /tenants/{client}` | `remove --force --async --json` |
| `GET /tenants/{client}` | `status` |
| `GET /tenants/{client}/credentials` | `credentials` |
| `POST /tenants/{client}/backup` | `backup --async --json` |
| `GET /jobs/{id}` | `job <id> status --json` |
| `GET /jobs/{id}/logs` | `job <id> logs` |
| `DELETE /jobs/{id}` | `job <id> cancel --json` |
| `GET /health` | `health --json` |

### Saída de job enfileirado

```json
{
  "schema_version": "1",
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "state": "queued",
  "cmd": "create",
  "client": "acme",
  "domain": "cloud.acme.com.br",
  "queued_at": "2026-05-13T04:00:00Z"
}
```

### Idempotência

Use `--idempotency-key=<uuid-v4>` para garantir que retries não criem jobs duplicados. O servidor armazena `nc:idem:<uuid>` no Redis com TTL de 24h. Enviar a mesma chave + mesmos args retorna o job original com `"idempotent": true`.

---

## Aplicativos Instalados Automaticamente

Cada nova instância inclui:

| App | Descrição |
|---|---|
| Nextcloud Office (richdocuments) | Edição colaborativa via Collabora Online |
| Calendar | CalDAV |
| Contacts | CardDAV |
| Mail | Cliente de e-mail integrado |
| Deck | Kanban |
| Forms | Formulários e pesquisas |
| Notes | Notas Markdown |
| Tasks | Tarefas |
| Group Folders | Pastas por grupo |
| Photos | Galeria |
| Activity | Log de atividades |
| Talk (spreed) | Chat e chamadas com HPB |
| AppAPI | Daemon para ExApps (HaRP) |
| Client Push (notify_push) | Notificações em tempo real |

---

## Estrutura do Repositório

```
nextcloud-saas-manager/
├── scripts/
│   ├── manage.sh                  # Script principal (CRUD de instâncias)
│   ├── worker.sh                  # Worker daemon de jobs assíncronos
│   ├── deploy-server.sh           # Deploy de servidor do zero
│   ├── setup-worker.sh            # Instala e configura o worker daemon
│   ├── setup-ssh-gateway.sh       # Configura usuário ncsaas-api + shim
│   ├── ncsaas-api-shim            # Portão de segurança SSH para APIs REST
│   └── lib/
│       ├── validators.sh          # Validadores puros (client, FQDN, UUID)
│       ├── output_json.sh         # emit_json, emit_error, log_event
│       ├── job_queue.sh           # Operações Redis (enqueue, get_state, scan)
│       ├── job_runner.sh          # Execução de job isolada pelo worker
│       ├── dispatch.sh            # Parser legado + namespaces + idempotência
│       ├── legacy_helpers.sh      # update_collabora/signaling/recording
│       ├── feature_o.sh           # Lifecycle users/groups/apps
│       ├── feature_o_ext.sh       # Extensão Feature O (ext commands)
│       ├── occ_bridge.sh          # OCC sync passthrough (Feature P)
│       ├── health_checks.sh       # 8 checks paralelos com timeout
│       ├── backup_offsite.sh      # Backup remoto via Restic
│       └── ssh_audit.sh           # Auditoria NDJSON journald
├── shared-services/
│   ├── docker-compose.yml         # 8 containers compartilhados
│   └── setup-shared.sh            # Script de inicialização compartilhada
├── ssh/
│   ├── 50-ncsaas-api.sshd.conf    # Drop-in sshd para ncsaas-api
│   ├── 51-ncsaas-api-sftp.conf    # SFTP jail para staging (Feature O)
│   ├── authorized_keys.example    # Modelo para ~ncsaas-api/.ssh/authorized_keys
│   └── ncsaas-api.sudoers         # Regra sudo restrita ao nextcloud-manage
├── systemd/
│   ├── nextcloud-saas-worker.service    # Worker daemon
│   ├── nextcloud-saas-worker.env.example
│   ├── nextcloud-saas-backup@.service   # Backup por cliente (timer)
│   ├── nextcloud-saas-backup@.timer
│   ├── nextcloud-saas-jobs-gc.service   # GC de jobs expirados
│   └── nextcloud-saas-jobs-gc.timer
├── tests/
│   ├── unit/                      # Testes unitários Bats
│   ├── integration/               # Testes de integração Bats
│   └── fixtures/                  # Stubs de docker, redis-cli, etc.
├── docs/
│   ├── SSH-API-REFERENCE.md       # Referência para APIs REST consumidoras
│   ├── ARCHITECTURE.md
│   ├── CONTRACTS.md
│   ├── REQUIREMENTS.md
│   ├── INFRASTRUCTURE.md
│   ├── ADMINISTRATION.md
│   ├── TROUBLESHOOTING.md
│   └── ROADMAP.md
└── .github/
    └── workflows/                 # CI: shellcheck, bats, contracts-check
```

### Estrutura no servidor após deploy

```
/opt/
├── traefik/                       # Reverse proxy
├── shared-services/               # 8 containers globais + secrets
│   └── secrets/                   # harp_shared_key, etc. (chmod 600)
└── nextcloud-customers/
    ├── scripts/                   # manage.sh + libs (copiados pelo setup)
    ├── jobs/                      # Logs de jobs async (<job_id>/output.log)
    ├── backups/                   # Backups locais
    └── <cliente>/                 # Uma pasta por tenant
        ├── .env                   # CLIENT_NAME, DOMAIN, REDIS_DB
        ├── .credentials           # Credenciais completas (chmod 600)
        ├── docker-compose.yml
        ├── app/                   # Volume Nextcloud
        └── harp-certs/

/usr/local/bin/
├── nextcloud-manage -> /opt/nextcloud-customers/scripts/manage.sh
└── ncsaas-api-shim                # Portão de segurança SSH

/opt/nextcloud-saas-worker/
└── .env                           # WORKER_REDIS_PASS, WORKER_CALLBACK_SECRET
```

---

## Contribuindo

Contribuições são bem-vindas. Abra uma issue ou pull request no repositório.

## Licença

MIT. Veja [LICENSE](LICENSE).
