# Guia de Administração — Nextcloud SaaS Manager

Este documento detalha todos os procedimentos de administração de instâncias de clientes no servidor de produção.

---

## Informações do Servidor

| Item | Valor |
|---|---|
| Script | `/opt/nextcloud-customers/manage.sh` |
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

### 1. Configurar DNS

Antes de criar a instância, configure **dois registros DNS do tipo A** no provedor DNS do cliente:

| Registro | Exemplo | Aponta para |
|---|---|---|
| Domínio Nextcloud | `nextcloud.acme.com.br` | IP do servidor |
| Domínio Collabora | `collabora-nextcloud.acme.com.br` | IP do servidor |

O domínio do Collabora é gerado automaticamente pelo script adicionando o prefixo `collabora-` ao domínio do Nextcloud.

Verifique a propagação do DNS antes de prosseguir:

```bash
dig +short nextcloud.acme.com.br
dig +short collabora-nextcloud.acme.com.br
```

Ambos devem retornar o IP do servidor.

### 2. Criar a Instância

```bash
sudo nextcloud-manage acme nextcloud.acme.com.br create
```

O script gera automaticamente todas as senhas e credenciais, que são salvas no arquivo `/opt/nextcloud-customers/acme/.env`. Ao final da criação, as credenciais são exibidas na tela.

### 3. Verificar a Instância

```bash
sudo nextcloud-manage acme _ status
```

Este comando mostra o status de todos os 7 containers, as URLs de acesso e verifica se o Nextcloud está respondendo.

### 4. Consultar Credenciais

As credenciais ficam armazenadas no arquivo `.env` da instância:

```bash
sudo cat /opt/nextcloud-customers/acme/.env
```

O arquivo contém: nome do cliente, domínio, domínio do Collabora, senhas do banco de dados (root e nextcloud), senha do admin do Nextcloud, senha do admin do Collabora, secret do TURN server e porta do TURN.

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

O backup é salvo em `/opt/nextcloud-customers/backups/` com o nome `acme-backup-YYYYMMDD_HHMMSS.tar.gz`. Inclui todos os dados do Nextcloud e um dump completo do banco de dados.

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

O Traefik gerencia automaticamente os certificados SSL via Let's Encrypt. Para verificar:

```bash
# Status do Traefik
docker ps --filter name=traefik

# Logs do Traefik
docker logs traefik --tail 50

# Verificar routers ativos (via docker exec)
docker exec traefik wget -qO- http://localhost:8080/api/http/routers 2>/dev/null | python3 -m json.tool
```

Os certificados são armazenados em `/opt/traefik/acme.json` e renovados automaticamente pelo Traefik antes de expirarem.
