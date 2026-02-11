# Guia de Administração — Nextcloud SaaS Manager

Este documento detalha o uso do script `nextcloud-manage` para o gerenciamento completo do ciclo de vida das instâncias de clientes na plataforma Nextcloud SaaS.

## Visão Geral

O comando principal é `nextcloud-manage`, que é um link simbólico para o script `manage.sh`. Todos os comandos devem ser executados com `sudo`.

## Sintaxe dos Comandos

A maioria dos comandos segue a sintaxe:

`sudo nextcloud-manage <nome-do-cliente> <dominio-nextcloud> <comando>`

-   `<nome-do-cliente>`: Um nome curto e único para o cliente (ex: `acme`, `globex`). Usado para nomear containers e diretórios.
-   `<dominio-nextcloud>`: O domínio principal da instância Nextcloud (ex: `nextcloud.acme.com`).
-   `<comando>`: A ação a ser executada (`create`, `status`, `backup`, etc.).

Para comandos que não precisam de um domínio (como `backup` ou `status`), você pode usar um placeholder como `_` ou qualquer string no lugar do domínio.

## Comandos Disponíveis

### `create` - Criar Nova Instância

Provisiona uma nova instância completa do Nextcloud, incluindo banco de dados, Redis, Collabora Online e servidor TURN.

**Importante:** Certifique-se de que os registros DNS para o Nextcloud e o Collabora já foram criados e propagados antes de executar este comando.

```bash
# Sintaxe
sudo nextcloud-manage <nome-do-cliente> <dominio-nextcloud> create

# Exemplo
sudo nextcloud-manage acme nextcloud.acme.com create
```

Ao final, o script exibirá uma tabela com todas as credenciais geradas.

### `list` - Listar Todas as Instâncias

Mostra uma lista de todas as instâncias de clientes instaladas no servidor.

```bash
sudo nextcloud-manage list
```

### `status` - Verificar Status de uma Instância

Exibe o status dos containers Docker de uma instância específica.

```bash
# Sintaxe
sudo nextcloud-manage <nome-do-cliente> _ status

# Exemplo
sudo nextcloud-manage acme _ status
```

### `credentials` - Exibir Credenciais de uma Instância

Mostra novamente a tabela de credenciais que foi gerada durante a criação da instância.

```bash
# Sintaxe
sudo nextcloud-manage <nome-do-cliente> _ credentials

# Exemplo
sudo nextcloud-manage acme _ credentials
```

### `backup` - Fazer Backup de uma Instância

Cria um backup completo da instância, incluindo o banco de dados, arquivos de configuração e dados do usuário. O backup é salvo em `/opt/nextcloud-customers/backups/`.

```bash
# Sintaxe
sudo nextcloud-manage <nome-do-cliente> _ backup

# Exemplo
sudo nextcloud-manage acme _ backup
```

### `restore` - Restaurar uma Instância a partir de um Backup

Restaura uma instância a partir de um arquivo de backup. A instância será completamente sobrescrita com os dados do backup.

```bash
# Sintaxe
sudo nextcloud-manage <nome-do-cliente> <caminho-do-backup> restore

# Exemplo
sudo nextcloud-manage acme /opt/nextcloud-customers/backups/acme-backup-20260211.tar.gz restore
```

### `update` - Atualizar uma Instância

Faz o pull das últimas imagens Docker para os componentes da instância (Nextcloud, Collabora, etc.) e recria os containers.

```bash
# Sintaxe
sudo nextcloud-manage <nome-do-cliente> _ update

# Exemplo
sudo nextcloud-manage acme _ update
```

### `remove` - Remover uma Instância

**Atenção: Esta ação é destrutiva e irreversível!**

Para e remove todos os containers da instância e apaga permanentemente todos os dados, incluindo o banco de dados, arquivos de configuração e dados do usuário.

```bash
# Sintaxe
sudo nextcloud-manage <nome-do-cliente> _ remove

# Exemplo
sudo nextcloud-manage acme _ remove
```
