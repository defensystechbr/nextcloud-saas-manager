# Infraestrutura — Nextcloud SaaS Manager v12.0

> **Documento gerado por** `/devops planejar` (skill `engenheiro-infra`, Fase 7).
> **Tier**: 1 — Single Node (host KVM Ubuntu 24.04 sob Proxmox).
> **Pré-requisitos verificados**: `docs/ARCHITECTURE.md` (§2 stack, §3 estrutura, §8.2 tier), `docs/REQUIREMENTS.md` (§6 NFRs, §8 premissas), `.cursorsession` (perfil `shell`).
> **Escopo**: provisionamento, topologia, recursos, rede, storage, segurança e checklist executável para outro humano subir o servidor do zero. **Não automatiza** — é um runbook (premissa: sem Ansible/Terraform na v12.0).

---

## 1. Topologia geral

```
                ┌───────────────────────────────────────────────────────┐
                │  Internet                                              │
                └───────┬─────────────────────────────────────┬─────────┘
                        │                                     │
                  HTTPS │ 443                            SSH  │ 22
                  HTTP  │ 80 (ACME-only redir)           SCP  │ 22
                        │                                     │
                        ▼                                     ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │  Proxmox host (HV — fora deste documento)                       │
        │   └─ KVM VM "ncsaas-prod" (este servidor)                       │
        │      ┌──────────────────────────────────────────────────────┐   │
        │      │  Ubuntu 24.04 LTS — single node                      │   │
        │      │                                                      │   │
        │      │  Edge: sshd (Match User ncsaas-api)  ──→ shim ──→    │   │
        │      │                                          sudo nextcloud-manage  │
        │      │                                                      │   │
        │      │  Edge: Traefik :80,:443 (Let's Encrypt)              │   │
        │      │                                                      │   │
        │      │  Containers (Docker Engine + Compose v2):            │   │
        │      │    Rede `proxy`   ── Traefik, *-app, *-collabora, *-signaling │
        │      │    Rede `shared`  ── db, redis, collabora, nats,     │   │
        │      │                      janus, signaling, recording,    │   │
        │      │                      socket-proxy (S3), <c>-harp     │   │
        │      │    network_mode: host ── coturn (TURN/STUN)          │   │
        │      │                                                      │   │
        │      │  systemd:                                            │   │
        │      │    nextcloud-saas-worker.service (BRPOP, root)       │   │
        │      │    nextcloud-saas-jobs-gc.timer  (daily, GC)         │   │
        │      │                                                      │   │
        │      │  Storage:                                            │   │
        │      │    /opt/shared-services/{db,redis,recording-tmp}     │   │
        │      │    /opt/nextcloud-customers/<c>/{app,harp-certs}     │   │
        │      │    /opt/nextcloud-customers/{jobs,inbox,backups}     │   │
        │      │    /opt/shared-services/secrets/* (0600 root)        │   │
        │      └──────────────────────────────────────────────────────┘   │
        └─────────────────────────────────────────────────────────────────┘
                                    │
                                    │  HTTPS POST + HMAC-SHA256
                                    ▼
                   API REST consumidora (outro repositório, outro host)
```

> **Premissas operacionais explícitas** (do `REQUIREMENTS.md §8`):
>
> 1. Single tenant de operação (1 time DevOps controla 1 servidor).
> 2. Sem orçamento para PaaS/SaaS adicional (sem Vault, SOPS, Datadog).
> 3. Janela de manutenção 4h/mês acordada — HA não obrigatório em v12.0.
> 4. API consumidora vive em outro repositório/host; comunicação só via SSH e callback HTTPS.

---

## 2. Specs do host (KVM)

| Recurso | Mínimo (até 5 clientes) | Recomendado (até 20 clientes) | Notas |
|---|---|---|---|
| vCPU | 4 cores | 8 cores | Worker é sequencial (`WORKER_CONCURRENCY=1`); CPU é gargalo de Collabora/recording, não do worker. |
| RAM | 8 GB | 16 GB | MariaDB ~2GB; Redis ~512MB; Collabora ~1GB/sessão ativa; Janus/signaling ~500MB cada. |
| Disco SSD | 80 GB | 200 GB+ | `/var/lib/docker` ~30GB; `/opt/nextcloud-customers/<c>/app/` cresce conforme uso (PDFs, imagens). |
| Disco rotacional (opcional) | — | 500 GB | Para `/opt/nextcloud-customers/backups/` (off-site fica para Feature E, P2). |
| Rede | 100 Mbps simétrico | 1 Gbps simétrico | WebRTC (Janus/coturn) consome banda em chamadas Talk. |
| IP | 1 IPv4 público estático | 1 IPv4 + 1 IPv6 público estáticos | Necessário para Let's Encrypt + WebRTC (TURN). |

**Sizing dinâmico**: cada cliente Nextcloud consome **+512MB RAM ociosa** + **+1 vCPU sob pico**. Acrescente 25% de margem.

---

## 3. Sistema operacional e pacotes

### 3.1 Distribuição

- **Ubuntu 24.04 LTS** (kernel 6.8+, systemd 255+).
- Filesystem: ext4 ou xfs (preferência ext4 para consistência com snapshots Proxmox).
- Locale: `en_US.UTF-8` (padrão do projeto, evita surpresas com OCC `--output=json`).
- Timezone: `UTC` (todos os timestamps em ISO 8601 UTC, ver `CONTRACTS.md §1.2`).

### 3.2 Pacotes obrigatórios (instalados por `scripts/deploy-server.sh`)

| Pacote | Versão | Origem | Por quê |
|---|---|---|---|
| `docker-ce` + `docker-ce-cli` + `docker-buildx-plugin` + `docker-compose-plugin` | Engine 29.x / Compose v2.x | Docker repo oficial | Stack base. |
| `bash` | 5.x | Ubuntu | Já vem; mas `manage.sh` usa Bash 5 features (`declare -A`). |
| `jq` | 1.7+ | Ubuntu | Geração de JSON segura (ADR-006). |
| `redis-tools` | 7.x | Ubuntu | `redis-cli` para `manage.sh` e worker (ARCHITECTURE §10 manage-cli). |
| `uuid-runtime` | — | Ubuntu | `uuidgen` para job_id e idempotency-key. |
| `openssl` | 3.x | Ubuntu | HMAC-SHA256 do callback + geração de senhas. |
| `coreutils` | 9.x | Ubuntu | `flock` para lock do worker. |
| `curl` | 8.x | Ubuntu | Worker callback (HTTPS POST). |
| `dnsutils` | — | Ubuntu | `dig +short` em `cmd_create` (validação DNS). |
| `bats` | 1.10+ | Ubuntu | **Apenas em CI / staging** — não produção. |
| `shellcheck` | 0.10+ | Ubuntu | **Apenas em CI** — `severity=warning` bloqueia merge. |

### 3.3 Pacotes a NÃO instalar

- `docker.io` (snap) — incompatível com `docker compose v2`. **Remover** se vier por padrão.
- `redis-server` apt — usamos container `redis:7-alpine`; servidor host conflita na porta.
- `ufw` — assumimos que o firewall vive no Proxmox (regra 4 abaixo). Em ambientes onde não há firewall externo, habilitar `ufw` com regra equivalente.

---

## 4. Rede e firewall

### 4.1 Portas expostas pelo host

| Porta | Protocolo | Origem permitida | Destino interno | Propósito |
|---|---|---|---|---|
| 22/tcp | SSH | **Allowlist** (IPs da API REST consumidora + admin DevOps) | sshd | Gateway de operação + SCP staging (Feature O.5) |
| 80/tcp | HTTP | 0.0.0.0/0 | Traefik | Apenas redir 301 → 443 + ACME challenge `/.well-known/acme-challenge/` |
| 443/tcp | HTTPS | 0.0.0.0/0 | Traefik | Nextcloud + Collabora + signaling (todos hosts) |
| 3478/udp+tcp | TURN/STUN | 0.0.0.0/0 | coturn (host network) | WebRTC Talk — relay |
| 5349/udp+tcp | TURNS | 0.0.0.0/0 | coturn | WebRTC Talk — TLS |
| 49152–65535/udp | RTP/RTCP | 0.0.0.0/0 | Janus / coturn | Relay de mídia (range padrão Janus) |

### 4.2 Portas internas (rede docker) — **nunca expostas ao host**

| Serviço | Porta | Rede | Cliente típico |
|---|---|---|---|
| `shared-db` (MariaDB) | 3306 | `shared` | `<c>-app`, `<c>-cron` |
| `shared-redis` | 6379 | `shared` | `<c>-app`, `<c>-cron`, `worker` (do host), `manage-cli` (do host) |
| `shared-collabora` | 9980 | `shared` + `proxy` | Traefik (proxy) e Nextcloud (shared) |
| `shared-signaling` | 8080 | `shared` + `proxy` | Traefik |
| `shared-nats` | 4222 | `shared` | `signaling` |
| `shared-janus` | 8088 | `shared` | `signaling` |
| `shared-recording` | 1234 | `shared` | `signaling` |
| `socket-proxy` (Sprint S3) | 2375 | `shared` | `<c>-harp` |

### 4.3 Egress (saída) necessário

- `443/tcp` para `acme-v02.api.letsencrypt.org`, `*.docker.io`, `ghcr.io`, `quay.io` (pulls).
- `443/tcp` para o callback URL da API REST consumidora (varia por deployment — registrar em `/opt/nextcloud-saas-worker/.env::WORKER_CALLBACK_HOST_ALLOWLIST` se firewall egress for restrito).
- `53/udp+tcp` para resolver público (Cloudflare 1.1.1.1, Google 8.8.8.8).
- `123/udp` para NTP (chrony).

### 4.4 Regras de firewall (Proxmox SDN ou ufw fallback)

```text
# INGRESS (default deny)
allow tcp 22  from <api-cidr>, <admin-cidr>
allow tcp 80  from 0.0.0.0/0
allow tcp 443 from 0.0.0.0/0
allow udp 3478,5349 from 0.0.0.0/0
allow tcp 3478,5349 from 0.0.0.0/0
allow udp 49152:65535 from 0.0.0.0/0
deny  all from 0.0.0.0/0

# EGRESS (default allow, mas auditável)
allow established,related
allow tcp 443 to 0.0.0.0/0
allow tcp 53,udp 53 to 0.0.0.0/0
allow udp 123 to 0.0.0.0/0
```

> Se a API consumidora vive **no mesmo Proxmox** (outra VM), restringir 22/tcp à rede privada da Proxmox (não passar pela internet).

---

## 5. DNS e TLS

### 5.1 Registros DNS necessários (gerenciados externamente)

| Tipo | Nome | Aponta para | Quando |
|---|---|---|---|
| A | `<cliente>.dominio.tld` | IP público do servidor | Por cliente, antes de `cmd_create <cliente>` |
| A | `collabora.shared.tld` | IP público | Uma vez (deploy inicial) |
| A | `signaling.shared.tld` | IP público | Uma vez (deploy inicial) |
| A | `turn.shared.tld` | IP público | Uma vez (opcional — coturn aceita IP) |
| AAAA | (opcional, igual aos A) | IPv6 público | Quando IPv6 disponível |

> O `cmd_create` valida `dig +short <cliente>.dominio.tld` antes de subir o container. Se DNS não resolver → exit code dedicado (ver `CONTRACTS.md §3.6`).

### 5.2 TLS

- **Mecanismo**: Traefik v3 com Let's Encrypt (HTTP-01 challenge).
- **Renovação**: automática (Traefik renova 30 dias antes do vencimento).
- **Cipher suite**: TLS 1.2+ apenas; ciphers default do Traefik (modernos).
- **HSTS**: header `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload` aplicado em `cmd_create` via label Traefik.

### 5.3 Hostnames internos (rede docker)

Todos via DNS embutido do Docker (resolução por container name):

```
shared-db, shared-redis, shared-collabora, shared-nats, shared-janus,
shared-signaling, shared-recording, shared-socket-proxy (S3),
<cliente>-app, <cliente>-cron, <cliente>-harp
```

---

## 6. Storage e backup

### 6.1 Layout em disco

| Caminho | Owner | Modo | Conteúdo | Backup |
|---|---|---|---|---|
| `/opt/shared-services/db/` | root | 0700 | MariaDB datadir | **Crítico** — dump diário (Feature E P2) |
| `/opt/shared-services/redis/` | root | 0700 | Redis AOF | **Crítico** — append-only file (jobs em fila, idempotency-keys) |
| `/opt/shared-services/secrets/` | root | 0700 | 0600 secrets/* | **Crítico** — perda = restore impossível (ver §7.2) |
| `/opt/shared-services/recording-tmp/` (volume) | root | — | Talk recordings em processo | Efêmero (recriado) |
| `/opt/nextcloud-customers/<cliente>/app/` | www-data (uid 33) | 0750 | Volume Nextcloud (data) | **Crítico** — `manage.sh <c> _ backup` cobre |
| `/opt/nextcloud-customers/<cliente>/.env` | root | 0600 | Senhas DB do cliente | **Crítico** — sem ele, container sobe sem auth |
| `/opt/nextcloud-customers/<cliente>/.credentials` | root | 0600 | Admin password Nextcloud | **Crítico** |
| `/opt/nextcloud-customers/<cliente>/harp-certs/` | root | 0700 | Certs do AppAPI HaRP | Recriáveis |
| `/opt/nextcloud-customers/jobs/` | root | 0750 | Logs por `<job_id>.log` | GC automático: `*.log` >30d, `*.log.gz` >90d |
| `/opt/nextcloud-customers/inbox/` | root | 0755 | SFTP staging (Feature O.5) — subdirs `<staging-id>/` 0700 ncsaas-api | GC automático: dirs vazios >24h |
| `/opt/nextcloud-customers/backups/` | root | 0700 | Saída de `cmd_backup` | **Crítico** — off-site = Feature E (P2) |
| `/opt/nextcloud-saas-worker/` | root | 0700 | `.env`, `lockfile` | `.env` é **crítico**; lockfile efêmero |
| `/var/lib/docker/` | root | 0710 | Imagens + volumes | Reconstruível |
| `/etc/ssh/sshd_config.d/{50,51}-ncsaas-api.conf` | root | 0644 | Drop-ins SSH (`ssh/` no repo) | Versionado no repo |
| `/etc/sudoers.d/ncsaas-api` | root | 0440 | Sudoers (`ssh/` no repo) | Versionado no repo |
| `/etc/systemd/system/nextcloud-saas-worker.service` | root | 0644 | Unit (`systemd/` no repo) | Versionado no repo |
| `/etc/systemd/system/nextcloud-saas-jobs-gc.{service,timer}` | root | 0644 | Unit (`systemd/` no repo) | Versionado no repo |

### 6.2 Política de backup

| Tipo | Frequência | Onde | Retenção | Ferramenta v12.0 |
|---|---|---|---|---|
| Snapshot do filesystem (Proxmox) | Diário | Proxmox storage | 7 dias | Proxmox built-in |
| MariaDB logical dump (`mysqldump --single-transaction`) | (futuro — Feature E P2) | Off-site (S3/B2) | 30 dias | A definir |
| `manage.sh <c> _ backup` | Sob demanda + antes de `update` | `/opt/nextcloud-customers/backups/` | Manual | Já existe |
| Redis AOF | Continuamente (`appendfsync everysec`) | Junto com snapshot Proxmox | 7 dias | Habilitado por `setup-shared.sh` |
| `secrets/` (off-line cópia inicial pelo operador) | No deploy + a cada rotação | Cofre físico ou gestor de senhas DevOps | Permanente | Manual |

> **Restore drill**: testar restore de Proxmox snapshot **uma vez por trimestre** em VM staging. Documentar tempo de recuperação em `ADMINISTRATION.md`.

---

## 7. Segurança operacional

### 7.1 Hardening do SO (executar uma vez no provisionamento)

Checklist (cada item é um comando):

- [ ] `unattended-upgrades` habilitado para CVEs (`apt install unattended-upgrades; dpkg-reconfigure -plow unattended-upgrades`).
- [ ] `fail2ban` instalado com jail para `sshd` (3 falhas = ban 1h).
- [ ] `auditd` instalado; regra para auditar `/etc/sudoers.d/` e `/etc/ssh/sshd_config.d/`.
- [ ] Kernel parameters em `/etc/sysctl.d/99-ncsaas.conf`:
  - `net.ipv4.tcp_syncookies=1`
  - `net.ipv4.conf.all.rp_filter=1`
  - `net.ipv4.conf.all.accept_redirects=0`
  - `kernel.dmesg_restrict=1`
- [ ] `apparmor` ativo (default Ubuntu 24.04 — verificar com `aa-status`).
- [ ] Login direto de `root` via SSH desabilitado (default Ubuntu — confirmar `PermitRootLogin no` em `/etc/ssh/sshd_config`).
- [ ] Usuário admin DevOps em `sudo` group; chave SSH em `~/.ssh/authorized_keys` 0600.
- [ ] Chrony sincronizando NTP (`chronyc tracking | grep 'Leap status.*Normal'`).

### 7.2 Gestão de secrets (ADR-008)

`/opt/shared-services/secrets/` (0700 root) contém:

- `db_root_password`
- `redis_password`
- `collabora_admin_password`
- `signaling_secret`
- `signaling_hash_key`
- `signaling_block_key`
- `signaling_internal_secret`
- `recording_secret`
- `turn_secret`
- `worker_callback_secret`

**Cada arquivo**: `0600 root:root`, conteúdo de 1 linha (sem newline final).

**Procedimento de criação inicial** (executado por `setup-shared.sh` quando ausente):

```bash
install -d -m 0700 -o root -g root /opt/shared-services/secrets
for s in db_root_password redis_password collabora_admin_password \
         signaling_secret signaling_hash_key signaling_block_key \
         signaling_internal_secret recording_secret turn_secret \
         worker_callback_secret; do
  if [ ! -s "/opt/shared-services/secrets/$s" ]; then
    install -m 0600 -o root -g root /dev/null "/opt/shared-services/secrets/$s"
    openssl rand -hex 32 > "/opt/shared-services/secrets/$s"
  fi
done
```

> Após geração, **fazer cópia off-line** (cofre físico ou gestor DevOps). Restore sem `secrets/` = MariaDB rejeita conexão e reset manual de senhas.

### 7.3 Rotação manual

| Item | Periodicidade recomendada | Procedimento (em `ADMINISTRATION.md` Sprint S2) |
|---|---|---|
| Chave SSH `ncsaas-api` | Anual ou imediata em incidente | Adicionar nova linha em `~ncsaas-api/.ssh/authorized_keys`; trocar lado API; remover antiga |
| `worker_callback_secret` | Anual | Rotacionar arquivo + restart `nextcloud-saas-worker.service` + atualizar lado API |
| `db_root_password`, `redis_password` | Bianual | Procedure documentada (afeta todos os clientes — fazer em janela de manutenção) |
| Certs Let's Encrypt | Automático (Traefik) | Sem ação |

### 7.4 Top 3 vetores de ataque (ARCHITECTURE §7.3) — controles operacionais

1. **Vazamento da chave SSH `ncsaas-api`**:
   - Kill switch: `usermod -L ncsaas-api` (5 segundos).
   - Detecção: `journalctl -t ncsaas-api-ssh | jq 'select(.client_ip != "<expected>")'`.
2. **Exploit em ExApp via HaRP escala root** (mitigado por `socket-proxy` em S3):
   - Pre-S3: monitorar `journalctl -u docker | grep -i 'privileged'`.
   - Pos-S3: alertar em `journalctl -t shared-socket-proxy | grep 'access denied'` >10/min.
3. **Job destrutivo no cliente errado**:
   - `--confirm=<cliente>` exigido (ARCHITECTURE §7.3 #3).
   - `--idempotency-key` evita retry duplicar; arquitetura documenta exit code 3 em `CONTRACTS.md §3.6`.

---

## 8. Checklist de provisionamento Proxmox (executar uma vez)

> Outro humano deve conseguir ir do zero ao servidor pronto para `scripts/deploy-server.sh` seguindo este checklist. Tempo estimado: **2h** (sem download de imagens base) a **4h** (full).

### 8.1 Criação da VM

- [ ] No Proxmox: criar VM com OS Type `Linux 6.x — 2.6 Kernel`, BIOS `OVMF (UEFI)`, machine `q35`.
- [ ] CPU: 4 cores (mínimo) ou 8 cores (recomendado), tipo `host` (passthrough).
- [ ] RAM: 8GB / 16GB conforme §2.
- [ ] Disco: 80GB (SSD) — virtio scsi, cache `none`, discard `on`, ssd `on`.
- [ ] Rede: bridge `vmbr0`, modelo `virtio`, firewall **on** (Proxmox SDN).
- [ ] Anexar ISO do Ubuntu Server 24.04 LTS.
- [ ] Boot, instalar Ubuntu (LVM padrão, sem swap encryption — feita por dm-crypt fora do escopo v12.0).
- [ ] Pós-install: `apt update && apt -y full-upgrade && reboot`.

### 8.2 Configuração inicial do SO

- [ ] Definir hostname: `hostnamectl set-hostname ncsaas-prod`.
- [ ] Definir timezone: `timedatectl set-timezone UTC`.
- [ ] Habilitar chrony: `systemctl enable --now chrony`.
- [ ] Criar usuário admin DevOps com sudo + chave SSH.
- [ ] Endurecer SSH: `PasswordAuthentication no`, `PermitRootLogin no` em `/etc/ssh/sshd_config`; `systemctl restart ssh`.
- [ ] Aplicar §7.1 hardening checklist.
- [ ] Configurar firewall Proxmox SDN conforme §4.4.

### 8.3 Instalação do projeto

- [ ] Clonar repositório: `cd /opt && git clone <url> nextcloud-saas-manager`.
- [ ] Symlinks de uso: `ln -s /opt/nextcloud-saas-manager /opt/nextcloud-customers` (compatibilidade com paths absolutos do `manage.sh`).
- [ ] Rodar `sudo bash /opt/nextcloud-saas-manager/scripts/deploy-server.sh` — ele instala Docker, pacotes, secrets/, systemd units (worker + gc), drop-ins SSH, sudoers, cria usuário `ncsaas-api`.
- [ ] Inserir chave pública da API REST em `/home/ncsaas-api/.ssh/authorized_keys` (modelo em `ssh/authorized_keys.example`).
- [ ] Validar sudoers: `visudo -c -f /etc/sudoers.d/ncsaas-api`.
- [ ] Validar systemd units: `systemctl daemon-reload && systemctl enable --now nextcloud-saas-worker.service nextcloud-saas-jobs-gc.timer`.
- [ ] Testar: `sudo -u ncsaas-api ssh -i <key> -p 22 ncsaas-api@127.0.0.1 'nextcloud-manage --version'` (vai pelo shim).

### 8.4 Smoke test pós-deploy

- [ ] `systemctl status nextcloud-saas-worker.service` → active (running).
- [ ] `systemctl list-timers | grep nextcloud-saas-jobs-gc` → próximo trigger documentado.
- [ ] `docker compose -f /opt/shared-services/docker-compose.yml ps` → todos os serviços `Up (healthy)`.
- [ ] Criar cliente teste: `manage.sh teste teste.dominio.tld create`.
- [ ] Validar Traefik certs: `curl -fsS https://teste.dominio.tld/status.php` → JSON válido.
- [ ] Validar fila: `manage.sh worker status --json` → `{"active":true,"queue_depth":0,...}`.
- [ ] Remover cliente teste: `manage.sh teste _ remove --confirm=teste`.

---

## 9. Operação contínua

### 9.1 Monitoramento (sem stack externa em v12.0 — ARCHITECTURE §9)

| O quê | Como | Frequência |
|---|---|---|
| Worker vivo | `systemctl is-active nextcloud-saas-worker` | A cada minuto (cron simples ou `manage.sh health`) |
| Fila grande | `manage.sh worker status --json \| jq .queue_depth` | A cada 5min; alertar >50 |
| Disco | `df -h /opt/nextcloud-customers /var/lib/docker` | Diário; alertar <10% livre |
| Certs Traefik | `manage.sh health --json` (check `traefik_certs`) | Diário |
| Logs do shim | `journalctl -t ncsaas-api-ssh -p auth.warning --since '24h'` | Diário; alertar >10 rejeições/24h |
| Audit sudoers | `journalctl -t ncsaas-api-sudo` | Diário |

### 9.2 Janela de manutenção

- **Acordada**: 4h/mês (premissa REQUIREMENTS §6 NFR).
- **Atividades dentro da janela**:
  - `apt full-upgrade` + reboot.
  - Renovação de imagens Docker (manual em v12.0; Feature K Renovate é P3).
  - Rotação de secrets bianual.
  - Testes de restore (trimestral).

### 9.3 Resposta a incidentes (runbook resumido — referência completa em `TROUBLESHOOTING.md`)

| Sintoma | Primeiro passo | Onde olhar |
|---|---|---|
| API recebe 5xx do callback | `journalctl -u nextcloud-saas-worker -p err --since '1h'` | Worker logs |
| `MaxStartups` derrubando conexões | `journalctl -t sshd \| grep 'exceeded MaxStartups'` | sshd |
| Cliente fora do ar | `docker compose -f /opt/nextcloud-customers/<c>/docker-compose.yml ps` | Container status |
| Fila parou de avançar | `manage.sh worker status --json` + `redis-cli -h shared-redis -n 16 LLEN nc:jobs:queue` | Redis + worker |
| Disco cheio | `du -sh /opt/* /var/lib/docker` + GC manual | Filesystem |
| Drift de OCC-allowlist em PR | CI `contracts-check` falha — atualizar `lib/occ_bridge.sh` ou `CONTRACTS.md §3.10.1` | GitHub Actions |

---

## 10. Decisões de infraestrutura registradas

| ID local | Decisão | Justificativa | Fonte |
|---|---|---|---|
| INFRA-001 | Tier 1 single-node em KVM/Proxmox | Premissa REQUIREMENTS §8 (sem orçamento HA) | ARCHITECTURE §8.2 |
| INFRA-002 | Firewall vive no Proxmox SDN; `ufw` apenas como fallback | Dupla camada complica troubleshooting | §4 deste doc |
| INFRA-003 | `unattended-upgrades` habilitado para CVEs | Janela de manutenção 4h/mês não cobre CVE crítico | §7.1 |
| INFRA-004 | Backup off-site (S3/B2) é Feature E P2 — fora da v12.0 | Snapshot Proxmox 7 dias é o backstop atual | §6.2 |
| INFRA-005 | Sem stack de métricas (Prometheus/Loki/Grafana) em v12.0 | Feature F P2; CLI + journald cobrem 80% dos casos | §9.1 |
| INFRA-006 | secrets/ off-line (cópia em cofre físico) é responsabilidade do operador | Sem Vault/SOPS por escopo (REQUIREMENTS §8) | §7.2 |

---

## 11. Próximos passos sugeridos

1. **`/devops cicd`** — caso queira ajustar pipelines individualmente (já gerados em `.github/workflows/`).
2. **`/pmo plan`** — quebrar v12.0 em 4 sprints risk-first com base em `ARCHITECTURE §4.1` e `ROADMAP` derivado.
3. **`/dev`** (Sprint S1) — implementar módulo `tests-bats` antes de tocar em `manage.sh`.

---

## Histórico de Revisões

| Data | Versão | Alteração | Autor |
|---|---|---|---|
| 2026-05-07 | 0.1 | Documento inicial — Tier 1 single-node Proxmox, specs, firewall, storage, hardening, checklist provisionamento, monitoramento CLI-only (sem Loki/Prometheus em v12.0), 6 INFRA-* decisões. Materializado a partir de ARCHITECTURE §3 (host runtime), §8 (BD), Apêndice A (artefatos systemd/sshd/sudoers). | Engenheiro de Infraestrutura (IA) |
