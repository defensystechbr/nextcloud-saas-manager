# Nextcloud SaaS Manager

Este repositório contém um conjunto de scripts para implantar e gerenciar uma plataforma Nextcloud SaaS multi-tenant, utilizando Docker, Traefik como reverse proxy e Let's Encrypt para certificados SSL automáticos.

O objetivo é permitir que qualquer pessoa com um servidor Ubuntu 24.04 (KVM) possa, seguindo este README, ter uma plataforma pronta para hospedar múltiplos clientes Nextcloud de forma segura e isolada.

---

## Visão Geral da Arquitetura

| Componente | Descrição |
|---|---|
| **Servidor Host** | Ubuntu 24.04 LTS (KVM recomendado, **não** LXC) |
| **Orquestração** | Docker Engine 29.x + Docker Compose plugin v2 |
| **Reverse Proxy** | Traefik v3.x+ (latest) com Let's Encrypt automático |
| **Gerenciamento** | `manage.sh` v9.0 (script para CRUD de instâncias) |
| **Isolamento** | Cada cliente roda em seu próprio conjunto de 7 containers |
| **Rede** | Rede Docker `proxy` compartilhada para o Traefik |

### Containers por Instância de Cliente

Cada instância criada pelo `manage.sh` gera os seguintes 7 containers:

| Container | Imagem | Função |
|---|---|---|
| `<nome>-app` | `nextcloud:latest` | Aplicação Nextcloud |
| `<nome>-db` | `mariadb:10.11` | Banco de dados MariaDB |
| `<nome>-redis` | `redis:alpine` | Cache e file locking |
| `<nome>-collabora` | `collabora/code:latest` | Collabora Online (edição de documentos) |
| `<nome>-turn` | `coturn/coturn:latest` | Servidor TURN para Nextcloud Talk |
| `<nome>-cron` | `nextcloud:latest` | Background jobs via cron |
| `<nome>-dsp` | `tecnativa/docker-socket-proxy:latest` | Docker Socket Proxy para AppAPI |

### Estrutura de Diretórios no Servidor

Após o deploy, o servidor terá a seguinte estrutura:

```
/opt/
├── traefik/                          # Reverse proxy
│   ├── docker-compose.yml            # Compose do Traefik
│   ├── config/
│   │   └── traefik.yml               # Configuração do Traefik
│   ├── acme.json                     # Certificados Let's Encrypt (gerado automaticamente)
│   └── logs/
│       ├── traefik.log
│       └── access.log
│
└── nextcloud-customers/              # Diretório principal da plataforma
    ├── manage.sh                     # Script de gerenciamento (v9.0)
    ├── backups/                      # Backups de todas as instâncias
    ├── <nome-cliente-1>/             # Instância do cliente 1
    │   ├── docker-compose.yml
    │   ├── .env                      # Credenciais e configuração
    │   └── data/                     # Dados do Nextcloud
    └── <nome-cliente-2>/             # Instância do cliente 2
        ├── docker-compose.yml
        ├── .env
        └── data/

/usr/local/bin/
└── nextcloud-manage -> /opt/nextcloud-customers/manage.sh   # Link simbólico
```

---

## Como Começar: Deploy de um Novo Servidor

Siga estes passos para preparar um novo servidor do zero.

### Pré-requisitos

O servidor deve atender aos seguintes requisitos antes de iniciar o deploy:

| Requisito | Detalhe |
|---|---|
| **Sistema Operacional** | Ubuntu 24.04 LTS (instalação limpa) |
| **Virtualização** | **KVM/QEMU obrigatório** — NÃO use LXC (incompatível com Docker 29.x) |
| **Acesso** | Root ou sudo sem senha |
| **Portas livres** | 80 (HTTP), 443 (HTTPS) |
| **Internet** | Acesso à internet para baixar imagens Docker e emitir certificados |
| **E-mail** | Um e-mail válido para registro de certificados Let's Encrypt |

### Passo 1: Clonar o Repositório

Conecte-se ao novo servidor via SSH e clone este repositório:

```bash
ssh usuario@IP_DO_SERVIDOR
git clone https://github.com/defensystechbr/nextcloud-saas-manager.git
cd nextcloud-saas-manager
```

### Passo 2: Executar o Script de Deploy

O script `deploy-server.sh` automatiza toda a preparação do servidor. Ele executa as seguintes etapas:

1. Atualiza o sistema e instala dependências (`curl`, `jq`, `pwgen`, `openssl`).
2. Instala o Docker Engine e Docker Compose (plugin v2) do repositório oficial.
3. Cria a rede Docker `proxy` e a estrutura de diretórios.
4. Configura e inicia o Traefik v3.x (latest) com Let's Encrypt.
5. Instala o `manage.sh` em `/opt/nextcloud-customers/` e cria o link simbólico `/usr/local/bin/nextcloud-manage`.

Execute com seu e-mail para o Let's Encrypt:

```bash
sudo ./scripts/deploy-server.sh --email seu-email@dominio.com
```

Opcionalmente, pode forçar o IP do servidor (útil se a detecção automática falhar):

```bash
sudo ./scripts/deploy-server.sh --email seu-email@dominio.com --ip 200.50.151.10
```

Ao final, o script exibirá um resumo com todas as informações do servidor. O servidor agora está pronto para receber clientes.

---

## Administrando Instâncias de Clientes

Após o deploy do servidor, use o comando `nextcloud-manage` para gerenciar instâncias. O comando está disponível globalmente graças ao link simbólico em `/usr/local/bin/`.

A sintaxe geral é:

```
sudo nextcloud-manage <nome-do-cliente> <domínio-ou-placeholder> <comando>
```

Onde:

| Parâmetro | Descrição | Exemplo |
|---|---|---|
| `<nome-do-cliente>` | Identificador curto e único (sem espaços ou caracteres especiais) | `acme`, `nxuorg`, `cliente1` |
| `<domínio-ou-placeholder>` | Domínio do Nextcloud (usado no `create` e `restore`) ou `_` (underscore) como placeholder para os demais comandos | `nextcloud.acme.com.br` ou `_` |
| `<comando>` | Ação a executar | `create`, `status`, `backup`, etc. |

### Passo 1: Configurar DNS (OBRIGATÓRIO antes de criar)

Antes de criar uma nova instância, você **deve** configurar **dois registros DNS do tipo A** no provedor DNS do cliente, ambos apontando para o IP do servidor:

| Registro DNS (Tipo A) | Exemplo | Aponta para |
|---|---|---|
| Domínio do Nextcloud | `nextcloud.acme.com.br` | `IP_DO_SERVIDOR` |
| Domínio do Collabora | `collabora-nextcloud.acme.com.br` | `IP_DO_SERVIDOR` |

O domínio do Collabora é gerado automaticamente pelo script com o prefixo `collabora-` antes do domínio do Nextcloud. Exemplos:

| Domínio Nextcloud | Domínio Collabora (gerado automaticamente) |
|---|---|
| `nxu.defensys.seg.br` | `collabora-nxu.defensys.seg.br` |
| `nextcloud.acme.com.br` | `collabora-nextcloud.acme.com.br` |
| `cloud.empresa.com` | `collabora-cloud.empresa.com` |

**Aguarde a propagação do DNS** antes de prosseguir. O Traefik não conseguirá emitir o certificado SSL se o DNS não estiver resolvendo para o IP do servidor.

### Passo 2: Criar a Instância

```bash
sudo nextcloud-manage acme nextcloud.acme.com.br create
```

O script irá:
1. Gerar senhas aleatórias e seguras para todos os serviços.
2. Criar o `docker-compose.yml` e o `.env` em `/opt/nextcloud-customers/acme/`.
3. Subir os 7 containers.
4. Aguardar o Nextcloud inicializar.
5. Configurar Collabora, Talk (TURN), Redis, Client Push e demais apps.
6. Exibir as credenciais completas da nova instância.

### Referência Completa de Comandos

| Comando | Sintaxe | Descrição |
|---|---|---|
| **create** | `sudo nextcloud-manage acme nextcloud.acme.com.br create` | Cria uma nova instância completa |
| **status** | `sudo nextcloud-manage acme _ status` | Mostra status dos containers e URLs |
| **backup** | `sudo nextcloud-manage acme _ backup` | Faz backup completo (dados + banco) para `/opt/nextcloud-customers/backups/` |
| **restore** | `sudo nextcloud-manage acme /caminho/do/backup.tar.gz restore` | Restaura uma instância a partir de um backup |
| **stop** | `sudo nextcloud-manage acme _ stop` | Para todos os containers da instância |
| **start** | `sudo nextcloud-manage acme _ start` | Inicia todos os containers da instância |
| **update** | `sudo nextcloud-manage acme _ update` | Faz backup, puxa novas imagens e executa upgrade |
| **remove** | `sudo nextcloud-manage acme _ remove` | Remove a instância e todos os dados (**irreversível**) |
| **list** | `sudo nextcloud-manage list` | Lista todas as instâncias e seus status |

Para mais detalhes sobre cada operação, consulte a [Documentação de Administração](docs/ADMINISTRATION.md).

Para resolver problemas comuns, consulte o [Guia de Troubleshooting](docs/TROUBLESHOOTING.md).

---

## Estrutura do Repositório

```
nextcloud-saas-manager/
├── README.md                      # Este arquivo
├── LICENSE                        # Licença MIT
├── .gitignore
├── scripts/
│   ├── deploy-server.sh           # Script para preparar um novo servidor do zero
│   └── manage.sh                  # Script para gerenciar instâncias de clientes (v9.0)
└── docs/
    ├── ADMINISTRATION.md          # Guia completo de administração de instâncias
    └── TROUBLESHOOTING.md         # Guia para resolver problemas comuns
```

---

## Contribuindo

Contribuições são bem-vindas. Sinta-se à vontade para abrir uma issue ou enviar um pull request.

## Licença

Este projeto é licenciado sob a Licença MIT. Veja o arquivo [LICENSE](LICENSE) para mais detalhes.
