# Guia de Administração — Nextcloud SaaS Manager

Este documento detalha todos os procedimentos de administração de instâncias de clientes no servidor de produção.

---

## Informações do Servidor

| Item | Valor |
|---|---|
| Script | `/opt/nextcloud-customers/manage.sh` (v11.3) |
| Link simbólico | `/usr/local/bin/nextcloud-manage` |
| Diretório das instâncias | `/opt/nextcloud-customers/<nome-cliente>/` |
| Diretório de backups | `/opt/nextcloud-customers/backups/` |
| Traefik | `/opt/traefik/` |
| Certificados SSL | `/opt/traefik/acme.json` (gerenciado automaticamente pelo Traefik/Let's Encrypt) |

---

## Sintaxe Geral

```
sudo nextcloud-manage <nome-do-cliente> <domínio-ou-placeholder> <comando>
```

O segundo argumento é o domínio do Nextcloud para os comandos `create` e `restore`, ou `_` (underscore) como placeholder para os demais comandos. O comando `list` não precisa de argumentos adicionais.

---

## Onboarding de Novo Cliente

### 1. Configurar DNS (OBRIGATÓRIO)

Antes de criar a instância, configure **1 registro DNS do tipo A** no provedor DNS do cliente:

| Registro | Exemplo | Aponta para |
|---|---|---|
| Domínio Nextcloud | `nextcloud.acme.com.br` | IP do servidor |

Os domínios do Collabora e Signaling agora são fixos e compartilhados (`collabora-01...` e `signaling-01...`).

Verifique a propagação do DNS antes de prosseguir:

```bash
dig +short nextcloud.acme.com.br
```

Deve retornar o IP do servidor.

### 2. Criar a Instância

```bash
sudo nextcloud-manage acme nextcloud.acme.com.br create
```

O script irá:
1. Verificar se o registro DNS está resolvendo.
2. Gerar senhas e alocar recursos nos serviços compartilhados (MariaDB, Redis).
3. Atualizar configurações HPB e Collabora globais.
4. Criar `docker-compose.yml`, `.env` e `.credentials` em `/opt/nextcloud-customers/acme/`.
5. Subir os **3 containers** da instância (`app`, `cron` e `harp`).
6. Aguardar o Nextcloud inicializar.
7. Configurar integração com os serviços compartilhados (Collabora, Talk HPB, Redis, TURN, HaRP).
8. Exibir as credenciais completas.

### 3. Verificar a Instância

```bash
sudo nextcloud-manage acme _ status
```

Este comando mostra o status dos containers do cliente, as URLs de acesso e verifica se o Nextcloud está respondendo.

### 4. Consultar Credenciais

```bash
sudo nextcloud-manage acme _ credentials
```

Ou diretamente no arquivo:

```bash
sudo cat /opt/nextcloud-customers/acme/.credentials
```

O arquivo `.credentials` contém todas as informações de acesso em formato legível: URLs, senhas do Nextcloud, Collabora, banco de dados, TURN server, Signaling server e HaRP.

---

## Operações do Dia a Dia

### Listar Todas as Instâncias

```bash
sudo nextcloud-manage list
```

### Ver Status de uma Instância

```bash
sudo nextcloud-manage acme _ status
```

### Ver Credenciais de uma Instância

```bash
sudo nextcloud-manage acme _ credentials
```

### Parar uma Instância

```bash
sudo nextcloud-manage acme _ stop
```

### Iniciar uma Instância

```bash
sudo nextcloud-manage acme _ start
```

---

## Backup e Restauração

### Fazer Backup Local

```bash
sudo nextcloud-manage acme _ backup
```

O backup é salvo em `/opt/nextcloud-customers/backups/` com o nome `acme-backup-YYYYMMDD_HHMMSS.tar.gz`. Inclui todos os dados do Nextcloud, certificados HaRP, e um dump completo do banco de dados a partir do MariaDB compartilhado.

### Restaurar de um Backup

```bash
sudo nextcloud-manage acme /opt/nextcloud-customers/backups/acme-backup-20260211_025535.tar.gz restore
```

---

## Backup Off-site (Feature E — v12.2)

Backup criptografado e incremental para S3 ou Backblaze B2, usando [restic](https://restic.net/).

### Pré-requisitos

1. **Instalar restic** (Ubuntu 24.04):
   ```bash
   apt-get install -y restic
   restic self-update   # opcional: atualiza para versão mais recente
   ```

2. **Criar os arquivos de secret** em `/opt/shared-services/secrets/` (modo 0600, dono root):

   ```bash
   # Obrigatórios
   echo "s3:https://s3.amazonaws.com/<bucket>" > /opt/shared-services/secrets/backup-repo-url
   echo "<senha-de-encriptacao-restic>"         > /opt/shared-services/secrets/backup-repo-password
   chmod 0600 /opt/shared-services/secrets/backup-repo-url \
              /opt/shared-services/secrets/backup-repo-password

   # Para S3 (se não usar instance profile / IAM role)
   echo "<aws-access-key-id>"     > /opt/shared-services/secrets/backup-aws-key-id
   echo "<aws-secret-access-key>" > /opt/shared-services/secrets/backup-aws-secret-key
   chmod 0600 /opt/shared-services/secrets/backup-aws-key-id \
              /opt/shared-services/secrets/backup-aws-secret-key

   # Para Backblaze B2 (alternativa ao S3)
   # echo "b2:<bucket>/<path>"  > /opt/shared-services/secrets/backup-repo-url
   # echo "<b2-account-id>"     > /opt/shared-services/secrets/backup-b2-account-id
   # echo "<b2-account-key>"    > /opt/shared-services/secrets/backup-b2-account-key
   ```

   | Secret | Descrição |
   |--------|-----------|
   | `backup-repo-url` | URL do repositório restic (`s3:https://...` ou `b2:<bucket>/<path>`) |
   | `backup-repo-password` | Senha de encriptação do repositório restic (gerada uma vez, guardar com segurança) |
   | `backup-aws-key-id` | AWS Access Key ID (opcional se usar IAM role) |
   | `backup-aws-secret-key` | AWS Secret Access Key (opcional se usar IAM role) |
   | `backup-b2-account-id` | Backblaze B2 Account ID |
   | `backup-b2-account-key` | Backblaze B2 Account Key |

### Fazer Backup Off-site (manual)

```bash
# Dry-run — verifica configuração sem criar snapshot
sudo nextcloud-manage acme _ backup-offsite --dry-run --json

# Backup real (sync, pode demorar vários minutos)
sudo nextcloud-manage acme _ backup-offsite --json
```

Saída JSON de exemplo:
```json
{
  "schema_version": "1",
  "result": "success",
  "client": "acme",
  "snapshot_id": "3d4f8a12",
  "files_new": 42,
  "files_changed": 7,
  "data_added_bytes": 1048576,
  "repo_url_redacted": "s3:https://s3.amazonaws.com/meu-bucket",
  "timestamp": "2026-05-11T14:00:00Z"
}
```

### Agendamento Automático (systemd timer)

Habilitar timer por cliente (roda diariamente às 02h + delay aleatório de até 1h):

```bash
# Habilitar para cliente 'acme'
systemctl enable --now nextcloud-saas-backup@acme.timer

# Verificar status
systemctl status nextcloud-saas-backup@acme.timer
systemctl status nextcloud-saas-backup@acme.service   # após última execução

# Ver logs do último backup
journalctl -u nextcloud-saas-backup@acme.service -n 50

# Executar imediatamente (ignora timer, executa o service)
systemctl start nextcloud-saas-backup@acme.service
```

Os units systemd ficam em `systemd/nextcloud-saas-backup@.{service,timer}` e são instalados em `/etc/systemd/system/` pelo `scripts/deploy-server.sh`.

### Política de Retenção (padrão restic)

| Critério | Valor |
|----------|-------|
| Manter por dia | 7 snapshots |
| Manter por semana | 4 snapshots |
| Manter por mês | 6 snapshots |
| Prune automático | Após cada backup agendado |

### Códigos de Saída

| Código | Significado |
|--------|-------------|
| 0 | Backup concluído com sucesso |
| 12 | Secrets ausentes (`backup-repo-url` ou `backup-repo-password` não encontrados) |
| 1 | Erro ao inicializar repositório restic ou falha do restic |

---

## Atualização de Instância

O comando `update` faz backup automático, puxa as novas imagens Docker e executa o upgrade do Nextcloud:

```bash
sudo nextcloud-manage acme _ update
```

---

## Remoção de Instância

**ATENÇÃO: Esta operação é irreversível. Todos os dados serão perdidos.**

Faça backup antes de remover:

```bash
sudo nextcloud-manage acme _ backup
sudo nextcloud-manage acme _ remove
```

---

## Acesso Direto ao Nextcloud (occ)

Para executar comandos `occ` diretamente no container do Nextcloud:

```bash
docker exec -u www-data acme-app php occ <comando>
```

Exemplos úteis:

```bash
# Ver status da instância
docker exec -u www-data acme-app php occ status

# Listar apps instalados
docker exec -u www-data acme-app php occ app:list

# Adicionar índices faltantes no banco
docker exec -u www-data acme-app php occ db:add-missing-indices

# Desativar modo de manutenção
docker exec -u www-data acme-app php occ maintenance:mode --off

# Criar novo usuário
docker exec -u www-data acme-app php occ user:add --display-name="João Silva" joao

# Verificar configuração do signaling (HPB)
docker exec -u www-data acme-app php occ config:app:get spreed signaling_servers

# Verificar daemon AppAPI (HaRP)
docker exec -u www-data acme-app php occ app_api:daemon:list

# Verificar se o socket do Docker está montado no container harp
# (requisito do daemon AppAPI a partir da v11.3.3 — sem ele o painel
# admin mostra "Deploy daemon harp_install inacessível")
docker inspect acme-harp --format '{{json .Mounts}}' | python3 -m json.tool | grep -A1 docker.sock
```

> **Nota sobre o HaRP e `/var/run/docker.sock`:** o container `<cliente>-harp` monta o socket do Docker do host em modo RW. Esse mount é obrigatório para que o daemon AppAPI consiga criar, iniciar, parar e remover containers de ExApps; sem ele o painel admin reporta o daemon como inacessível e nenhum ExApp pode ser instalado. O acesso ao socket Docker concede privilégios equivalentes a root no host — por isso o container HaRP usa apenas a imagem oficial do AppAPI da Nextcloud GmbH e fica restrito à rede Docker `proxy`/`shared`. Para detalhes de diagnóstico em instâncias legadas, consulte `docs/TROUBLESHOOTING.md`, seção *AppAPI / HaRP não funciona*, item 4.

---

## Acesso ao Banco de Dados

Para acessar o banco de dados MariaDB de uma instância (agora no container compartilhado):

```bash
# Consultar a senha no .env
sudo grep MYSQL_PASSWORD /opt/nextcloud-customers/acme/.env

# Acessar o banco via container compartilhado
docker exec -it shared-db mariadb -u nextcloud_acme -p
```

---

## Traefik e Certificados SSL

O Traefik gerencia automaticamente os certificados SSL via Let's Encrypt. O dashboard do Traefik está **desabilitado por segurança** (não há porta 8080 exposta). Para diagnóstico:

```bash
# Status do Traefik
docker ps --filter name=traefik

# Logs do Traefik
docker logs traefik --tail 50

# Verificar routers ativos (via docker exec)
docker exec traefik wget -qO- http://localhost:8080/api/http/routers 2>/dev/null | python3 -m json.tool
```

Os certificados são armazenados em `/opt/traefik/acme.json` e renovados automaticamente pelo Traefik antes de expirarem. Cada instância gera 3 certificados (Nextcloud, Collabora, Signaling).

---

## Worker Daemon e Modo Assíncrono (v12.0)

### Gerenciar o Worker

```bash
# Status do serviço systemd
systemctl status nextcloud-saas-worker

# Iniciar / parar / reiniciar
systemctl start nextcloud-saas-worker
systemctl stop nextcloud-saas-worker
systemctl restart nextcloud-saas-worker

# Ver logs do worker (journald)
journalctl -u nextcloud-saas-worker -f
journalctl -u nextcloud-saas-worker --since "1 hour ago" -o json

# Status via manage.sh
nextcloud-manage worker status --json
nextcloud-manage worker stats --by-cmd --by-client --json
```

### Gerenciar Jobs

```bash
# Listar jobs na fila
nextcloud-manage job list --state=queued --json

# Ver status de um job específico
nextcloud-manage job <job_id> status --json

# Ver logs de execução de um job
nextcloud-manage job <job_id> logs

# Cancelar job em fila (só funciona para state=queued)
nextcloud-manage job <job_id> cancel

# Listar com filtros
nextcloud-manage job list --client=acme --cmd=create --limit=10 --json
```

### Configuração do Worker

Editar `/etc/nextcloud-saas/worker.env`:

```bash
WORKER_CONCURRENCY=1            # Sempre 1 (ADR-002)
WORKER_REDIS_HOST=127.0.0.1
WORKER_REDIS_PORT=6379
WORKER_REDIS_DB=16              # dbindex dedicado (ARCH-001)
WORKER_JOB_TIMEOUT_SEC=1800     # Timeout por job (30min)
WORKER_CALLBACK_BACKOFF=5,30,300
CLIENT_LOCK_TTL_SEC=5
WORKER_JOBS_DIR=/opt/nextcloud-saas/jobs
```

### Logs de Auditoria (journald)

```bash
# SSH gateway (quem invoou via API REST)
journalctl -t ncsaas-api-ssh -o json | jq .

# Worker daemon
journalctl -t nextcloud-saas-worker -o json | jq .

# OCC exec (D4)
journalctl -t nextcloud-saas-occ-exec -o json | jq .
```

### OCC Exec Sync (Feature P)

Use `occ-exec` para executar apenas subcomandos OCC allowlisted com timeout curto:

```bash
nextcloud-manage acme occ-exec user:list --json
nextcloud-manage acme occ-exec app:enable calendar --json
printf '{"password":"..."}' | nextcloud-manage acme occ-exec user:add john --payload-stdin --json
```

Regras operacionais:
- `occ-exec` e sempre sincrono; `--async`, `--callback` e `--idempotency-key` retornam erro.
- Subcomandos mutaveis pegam `client-lock`; se o worker async estiver operando o mesmo cliente, a CLI retorna exit `17`.
- Senhas nunca devem ir em argv. Use `--payload-stdin` para `user:add` e `user:resetpassword`.
- O timeout padrao e `WORKER_OCC_TIMEOUT_SEC=60`.

### Health Consolidado

```bash
nextcloud-manage health --json
```

O comando roda 8 checks em paralelo: containers compartilhados, certificados Traefik, DNS fixos, recording, HaRP via socket-proxy, disco, fila Redis e worker.

### Socket Proxy e Secrets

Clientes novos usam `DOCKER_HOST=tcp://shared-socket-proxy:2375` no HaRP. Para migrar cliente existente:

```bash
nextcloud-manage upgrade-harp acme
```

Os secrets compartilhados ficam em `/opt/shared-services/secrets/*` com modo `0600`; o `.env` dos shared services deve conter apenas referencias `*_FILE`.

### SSH Gateway ncsaas-api

```bash
# Verificar usuário
getent passwd ncsaas-api

# Ver authorized_keys
cat /home/ncsaas-api/.ssh/authorized_keys

# Testar conexão (da máquina da API REST)
ssh -i /path/to/api_key ncsaas-api@servidor 'nextcloud-manage list'

# Kill-switch de emergência
usermod -L ncsaas-api

# Reabilitar
usermod -U ncsaas-api

# Rotação de chave SSH
# 1. Gere nova chave: ssh-keygen -t ed25519 -C "api-prod-$(date +%Y)"
# 2. Adicione nova chave em /home/ncsaas-api/.ssh/authorized_keys
# 3. Remova chave antiga
# 4. Teste nova chave
# 5. Remova entrada antiga do authorized_keys
```

---

## Estrutura de Arquivos por Instância (v11.3.3)

```
/opt/nextcloud-customers/acme/
├── docker-compose.yml          # Definição dos containers do cliente (app, cron, harp)
├── .env                        # Variáveis de ambiente (senhas, domínios, chaves)
├── .credentials                # Credenciais em formato legível
├── install.log                 # Log da instalação inicial
├── app/                        # Dados do Nextcloud (/var/www/html)
└── harp-certs/                 # Certificados do HaRP (AppAPI)
```

*(Nota: Os dados do banco de dados, redis, e configurações HPB agora residem no diretório `/opt/shared-services/`)*
