# Guia de Administração — Nextcloud SaaS Manager

Este documento detalha todos os procedimentos de administração de instâncias de clientes no servidor de produção.

---

## Informações do Servidor

| Item | Valor |
|---|---|
| Script | `/opt/nextcloud-customers/manage.sh` (v10.0) |
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

Antes de criar a instância, configure **3 registros DNS do tipo A** no provedor DNS do cliente:

| Registro | Exemplo | Aponta para |
|---|---|---|
| Domínio Nextcloud | `nextcloud.acme.com.br` | IP do servidor |
| Domínio Collabora | `collabora-nextcloud.acme.com.br` | IP do servidor |
| Domínio Signaling | `signaling-nextcloud.acme.com.br` | IP do servidor |

Os domínios do Collabora e Signaling são gerados automaticamente pelo script adicionando os prefixos `collabora-` e `signaling-` ao domínio do Nextcloud.

Verifique a propagação do DNS antes de prosseguir:

```bash
dig +short nextcloud.acme.com.br
dig +short collabora-nextcloud.acme.com.br
dig +short signaling-nextcloud.acme.com.br
```

Todos devem retornar o IP do servidor.

### 2. Criar a Instância

```bash
sudo nextcloud-manage acme nextcloud.acme.com.br create
```

O script irá:
1. Verificar se os 3 registros DNS estão resolvendo.
2. Gerar senhas e chaves para todos os serviços.
3. Criar configurações HPB (Janus, NATS, Signaling).
4. Criar `docker-compose.yml`, `.env` e `.credentials` em `/opt/nextcloud-customers/acme/`.
5. Subir os **10 containers**.
6. Aguardar o Nextcloud inicializar.
7. Configurar Collabora, Talk (TURN + HPB), Redis, HaRP (AppAPI), Client Push e demais apps.
8. Exibir as credenciais completas.

### 3. Verificar a Instância

```bash
sudo nextcloud-manage acme _ status
```

Este comando mostra o status de todos os **10 containers**, as URLs de acesso (Nextcloud, Collabora, Signaling) e verifica se o Nextcloud está respondendo.

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

O backup é salvo em `/opt/nextcloud-customers/backups/` com o nome `acme-backup-YYYYMMDD_HHMMSS.tar.gz`. Inclui todos os dados do Nextcloud, configurações HPB, e um dump completo do banco de dados.

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

Para acessar o banco de dados MariaDB de uma instância:

```bash
# Consultar a senha no .env
sudo grep MYSQL_ROOT_PASSWORD /opt/nextcloud-customers/acme/.env

# Acessar o banco
docker exec -it acme-db mysql -u root -p nextcloud
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

## Estrutura de Arquivos por Instância

```
/opt/nextcloud-customers/acme/
├── docker-compose.yml          # Definição dos 10 containers
├── .env                        # Variáveis de ambiente (senhas, domínios, chaves)
├── .credentials                # Credenciais em formato legível
├── install.log                 # Log da instalação inicial
├── app/                        # Dados do Nextcloud (/var/www/html)
├── db/                         # Dados do MariaDB
├── redis/                      # Dados do Redis
├── harp-certs/                 # Certificados do HaRP (AppAPI)
└── hpb/                        # Configurações do HPB (Talk)
    └── config/
        ├── gnatsd.conf                         # NATS
        ├── janus.jcfg                          # Janus Gateway
        ├── janus.transport.websockets.jcfg     # Janus WebSocket
        └── janus.plugin.videoroom.jcfg         # Janus VideoRoom
```
