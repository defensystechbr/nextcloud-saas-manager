# Nextcloud SaaS Manager

Este repositório contém um conjunto de scripts para implantar e gerenciar uma plataforma Nextcloud SaaS multi-tenant, utilizando Docker, Traefik como reverse proxy e Let's Encrypt para certificados SSL automáticos.

O objetivo é permitir que qualquer pessoa com um servidor Ubuntu 24.04 (KVM) possa, seguindo este README, ter uma plataforma pronta para hospedar múltiplos clientes Nextcloud de forma segura e isolada.

## Visão Geral da Arquitetura

| Componente | Descrição |
|---|---|
| **Servidor Host** | Ubuntu 24.04 LTS (KVM recomendado) |
| **Orquestração** | Docker Engine + Docker Compose (plugin v2) |
| **Reverse Proxy** | Traefik v3.x+ (com Let's Encrypt para SSL) |
| **Gerenciamento** | `manage.sh` (script para CRUD de instâncias) |
| **Isolamento** | Cada cliente roda em seu próprio conjunto de containers |
| **Rede** | Rede `proxy` compartilhada para o Traefik |

## Como Começar: Deploy de um Novo Servidor

Siga estes passos para preparar um novo servidor do zero.

### Pré-requisitos

- Um servidor com **Ubuntu 24.04 LTS** (instalação limpa).
- **Virtualização KVM/QEMU é fortemente recomendada.** Não use LXC para evitar problemas de compatibilidade com o Docker.
- Acesso root/sudo.
- Portas 80, 443 e 8080 livres.
- Um e-mail válido para o registro de certificados Let's Encrypt.

### Passo 1: Clonar o Repositório

Clone este repositório para o seu novo servidor:

```bash
git clone https://github.com/defensystechbr/nextcloud-saas-manager.git
cd nextcloud-saas-manager
```

### Passo 2: Executar o Script de Deploy

O script `deploy-server.sh` automatiza toda a preparação do servidor. Ele irá:

1.  Atualizar o sistema e instalar dependências (`curl`, `jq`, `pwgen`).
2.  Instalar a última versão do Docker Engine e Docker Compose.
3.  Configurar e iniciar o Traefik v3.x como um serviço.
4.  Instalar o script `manage.sh` no sistema.

Execute o script com seu e-mail para o Let's Encrypt:

```bash
sudo ./scripts/deploy-server.sh --email seu-email@dominio.com
```

Ao final, o script exibirá um resumo com todas as informações do servidor, que agora está pronto para receber clientes.

## Administrando Instâncias de Clientes

Após o deploy do servidor, use o comando `nextcloud-manage` para criar, listar, atualizar e remover instâncias de clientes.

### Passo 1: Configurar DNS

Antes de criar uma nova instância, você **deve** configurar os seguintes registros DNS no seu provedor, apontando para o IP do seu servidor:

| Tipo de Registro | Hostname | Aponta para |
|---|---|---|
| A | `nextcloud.dominio-do-cliente.com` | `IP_DO_SEU_SERVIDOR` |
| A | `collabora-nextcloud.dominio-do-cliente.com` | `IP_DO_SEU_SERVIDOR` |

O Traefik não conseguirá emitir o certificado SSL se o DNS não estiver propagado.

### Passo 2: Criar uma Nova Instância

Use o comando `create` para provisionar uma nova instância completa do Nextcloud + Collabora Online.

**Sintaxe:**
`sudo nextcloud-manage <nome-do-cliente> <dominio-nextcloud> create`

**Exemplo:**
```bash
sudo nextcloud-manage acme nextcloud.acme.com create
```

O script irá gerar senhas aleatórias e seguras para todos os serviços e, ao final, exibirá as credenciais completas da nova instância (Nextcloud, banco de dados, Collabora, etc.).

### Outros Comandos de Gerenciamento

Consulte a documentação completa de administração para mais detalhes sobre os comandos disponíveis:

-   [Documentação de Administração](./docs/ADMINISTRATION.md)

## Estrutura do Repositório

-   `README.md`: Este arquivo.
-   `scripts/`: Contém os scripts principais.
    -   `deploy-server.sh`: Para preparar um novo servidor.
    -   `manage.sh`: Para gerenciar instâncias de clientes.
-   `docs/`: Contém documentação auxiliar.
    -   `ADMINISTRATION.md`: Guia completo de administração de instâncias.
    -   `TROUBLESHOOTING.md`: Guia para resolver problemas comuns.

## Contribuindo

Contribuições são bem-vindas! Sinta-se à vontade para abrir uma issue ou enviar um pull request.

## Licença

Este projeto é licenciado sob a Licença MIT. Veja o arquivo `LICENSE` para mais detalhes.
