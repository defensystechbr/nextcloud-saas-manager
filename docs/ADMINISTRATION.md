# Guia de Administração — Nextcloud SaaS Manager

Este documento detalha todos os procedimentos de administração de instâncias de clientes no servidor de produção.

---

## Informações do Servidor

| Item | Valor |
|---|---|
| Script | `/opt/nextcloud-customers/manage.sh` (v11.1) |
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
5. Subir os **2 containers** da instância (`app` e `cron`).
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

### Fazer Backup

```bash
sudo nextcloud-manage acme _ backup
```

O backup é salvo em `/opt/nextcloud-customers/backups/` com o nome `acme-backup-YYYYMMDD_HHMMSS.tar.gz`. Inclui todos os dados do Nextcloud, certificados HaRP, e um dump completo do banco de dados a partir do MariaDB compartilhado.

### Restaurar de um Backup

```bash
sudo nextcloud-manage acme /opt/nextcloud-customers/backups/acme-backup-20260211_025535.tar.gz restore
```

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
```

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

## Estrutura de Arquivos por Instância (v11.1)

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
