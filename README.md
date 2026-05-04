# Nextcloud SaaS Manager v11.3.4

Este repositório contém um conjunto de scripts para implantar e gerenciar uma plataforma Nextcloud SaaS multi-tenant, utilizando Docker, Traefik como reverse proxy e Let's Encrypt para certificados SSL automáticos.

O objetivo é permitir que qualquer pessoa com um servidor Ubuntu 24.04 (KVM) possa, seguindo este README, ter uma plataforma pronta para hospedar múltiplos clientes Nextcloud de forma segura e isolada.

---

### Changelog
| Versão | Data       | Principais Mudanças |
|:-------|:-----------|:--------------------|
| **v11.3.4** | 2026-05-04 | **Onboarding mais simples (zero `chmod`):** o passo de clone do repositório foi simplificado para apenas `git clone` + `cd`, sem SSH redundante e sem `chmod +x scripts/*.sh`. O deploy passa a ser sempre invocado via `sudo bash scripts/deploy-server.sh ...`, eliminando a dependência do bit de execução do filesystem (que não é preservado pelo `git clone` quando o arquivo está em modo `100644` no índice). O próprio `deploy-server.sh` aplica `chmod +x` no `manage.sh` quando o instala em `/opt/nextcloud-customers/`. Cabeçalhos do `deploy-server.sh` e do `manage.sh` atualizados para refletir o novo padrão de invocação e bumpados para v11.3.4. |
| **v11.3.3** | 2026-05-04 | **Fix HaRP — "Deploy daemon `harp_install` inacessível":** o container `<cliente>-harp` passou a montar `/var/run/docker.sock:/var/run/docker.sock` (read-only) tanto no template gerado por `scripts/manage.sh` (linha 454) quanto no template embutido em `scripts/deploy-server.sh` (linha 338). O daemon AppAPI/HaRP precisa do socket do Docker no host para criar, atualizar e remover containers de ExApps; sem o mount o painel admin do Nextcloud exibia o aviso permanente *"Deploy daemon `harp_install` inacessível"* e qualquer instalação de ExApp falhava. Para instâncias legadas, ver guia em `docs/TROUBLESHOOTING.md` — seção *AppAPI / HaRP não funciona*, item 4. Validado em produção (`mecloud360`, `terminalx`, `nextcloud-teste`). |
| **v11.3** | 2026-05-01 | **QA Round 3 — Correções críticas:** (1) Recording Server: adicionada seção `[signaling2]` com URL pública (`https://signaling-01...`) que elimina o erro `No configured signaling secret for https://...` e permite que o bot de gravação entre na chamada como participante. (2) Renomeado `recording.conf` → `server.conf` para alinhar com o `Dockerfile` (build estava quebrado em ambientes novos). (3) `setup-shared.sh` agora substitui placeholders no template `server.conf` no boot inicial (evita config inválida antes do primeiro cliente). (4) Removido secret hardcoded `janusoverlord` — agora `JANUS_ADMIN_SECRET` e `JANUS_ROOM_KEY` são gerados dinamicamente via `openssl rand -hex 32`. (5) `signaling.conf` template inicial não emite mais `backends = ` vazio (define `[backend1] placeholder.invalid`). (6) `manage.sh remove`: proteção `${VAR:?}` no `rm -rf` + `cd ... \|\| exit` em todos os pontos críticos. (7) Documentação: contagem de containers unificada para 3 por cliente (`app`, `cron`, `harp`). (8) Adicionado workflow GitHub Actions `shellcheck.yml` para auditoria automática em PRs. Validado por QA Round 3 contra deploy em produção `nxdev.defensys.seg.br` com SSL Labs A+, 12 apps funcionando e chamada Talk com gravação real. |
| **v11.2** | 2026-05-01 | **Fix de bootstrap do Recording:** o template inicial gerado por `deploy-server.sh` para `recording.conf` (e também `signaling.conf`) tinha `backends = ` vazio, provocando `KeyError: ''` em loop no container `shared-recording` antes da criação da primeira instância. Agora o template traz um placeholder `backend1 → https://placeholder.invalid`, e as funções `update_*_backends` no `manage.sh` aplicam o mesmo fallback ao remover a última instância. README documenta que o deploy deve ser invocado com `sudo bash scripts/deploy-server.sh` (não depende do bit de execução após `git clone`). |
| **v11.1** | 2026-05-01 | **Fixes Críticos do Talk:** (1) URL do TURN agora usa hostname `turn-01.defensys.seg.br` sem prefixo duplicado `turn:turn:`; (2) `recording_servers` aplicado via `run_occ` em vez de `echo yes \| docker exec` (eliminando erro `--update-only`); (3) template `recording.conf` reescrito com `backend1`/`signaling1` (sem hífen) eliminando `KeyError: ''` no boot; (4) nova variável `TURN_DOMAIN` no `manage.sh` e `deploy-server.sh` com flag CLI `--turn-domain`; (5) coturn ganha `lt-cred-mech` e `realm` por hostname. Validado por chamada Talk real entre 2 navegadores (1m46s). |
| **v11.0** | 2026-04-30 | **Nova Arquitetura Compartilhada:** 3 containers por cliente + 8 globais. Fix de áudio/vídeo no Talk (coturn network_mode: host). Recording Server compartilhado (multi-backend). |
| **v10.0** | 2026-02-13 | **Fix Crítico:** Nome do backend do Signaling alterado para `backend1` para evitar bugs com hífens. Adicionado `db:add-missing-indices` na instalação. |
| **v9.1**  | 2026-02-12 | **Fix:** Corrigido registro do daemon HaRP e flags de inicialização. |
| **v9.0**  | 2026-02-12 | **Recurso:** Integração completa do HPB (High-Performance Backend) para Talk e HaRP (AppAPI daemon), elevando a arquitetura para 10 containers. |
| **v8.0**  | 2026-02-11 | **Segurança:** Removida exposição da porta 8080 do Traefik e desabilitado o dashboard inseguro. Acesso via `docker exec`. |
| **v7.0**  | 2026-02-11 | **Docs:** Correção geral da documentação (`README`, `ADMINISTRATION`, `TROUBLESHOOTING`) com caminhos e comandos corretos. |
| **v6.0**  | 2026-02-11 | **Docs:** Adicionados guias de Administração e Troubleshooting. |
| **v5.0**  | 2026-02-11 | **Recurso:** Criação do script `deploy-server.sh` para automação do deploy do servidor. |
| **v1.0 - v4.0** | 2026-02-10 | Lançamento inicial e refinamentos do `manage.sh` com arquitetura base (Nextcloud, Collabora, TURN). |

---

## Visão Geral da Arquitetura

| Componente | Descrição |
|---|---|
| **Servidor Host** | Ubuntu 24.04 LTS (KVM recomendado, **não** LXC) |
| **Orquestração** | Docker Engine 29.x + Docker Compose plugin v2 |
| **Reverse Proxy** | Traefik v3.x+ (latest) com Let's Encrypt automático |
| **Gerenciamento** | `manage.sh` v11.3.4 (script para CRUD de instâncias) |
| **Isolamento** | Arquitetura híbrida: **3 containers por cliente + 8 serviços compartilhados globais** |
| **Rede** | Rede Docker `proxy` (Traefik) e `shared` (Serviços Compartilhados) |

### Arquitetura Compartilhada (introduzida na v11.0)

Para otimizar o uso de recursos (CPU/Memória), a arquitetura agora divide os serviços em globais e específicos por cliente.

**Serviços Compartilhados (8 containers globais):**
- `shared-db`: MariaDB (1 database por cliente)
- `shared-redis`: Redis (1 dbindex por cliente)
- `shared-collabora`: Collabora Online (suporta multi-domínios via allowlist)
- `shared-turn`: coturn STUN/TURN server (network_mode: host para WebRTC)
- `shared-nats`: Message broker para Signaling
- `shared-janus`: WebRTC media server para Talk
- `shared-signaling`: Nextcloud Talk High Performance Backend (multi-tenant)
- `shared-recording`: Talk Recording Server (multi-backend)

**Serviços por Cliente (3 containers por instância):**

A implementação atual provisiona três containers dedicados a cada cliente: o `<nome>-app` rodando Nextcloud com Apache e PHP isolado, o `<nome>-cron` responsável pelas tarefas de background (`cron.sh`), e o `<nome>-harp` que atua como daemon do AppAPI (HaRP) para hospedar ExApps externos. O container `harp` recebe o socket do Docker do host (`/var/run/docker.sock`, mount RW) por exigência do daemon AppAPI, que precisa criar e gerenciar containers de ExApps no host — sem esse mount, o painel admin exibe o aviso *"Deploy daemon `harp_install` inacessível"* (corrigido em **v11.3.3**).

### DNS Necessários

**Dominios Fixos (Globais)** — substitua `EXEMPLO.com.br` pelo dominio que voce controla:
- `collabora-01.EXEMPLO.com.br` (Collabora Online)
- `signaling-01.EXEMPLO.com.br` (Talk High Performance Backend)
- `turn-01.EXEMPLO.com.br` (coturn STUN/TURN — usado pelo Talk para WebRTC, aponta para o IP publico do servidor)

Todos devem ser configurados como registros DNS tipo `A` apontando para o IP do servidor **antes** de rodar o deploy. Os tres devem ser passados via `--collabora-domain`, `--signaling-domain` e `--turn-domain` no `deploy-server.sh`.

**Por Instância de Cliente:**
Cada instância requer **apenas 1 registro DNS do tipo A** apontando para o IP do servidor:

| Registro DNS | Exemplo | Função |
|---|---|---|
| Domínio do Nextcloud | `nextcloud.acme.com.br` | Acesso à aplicação isolada do cliente |

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
├── shared-services/                  # Serviços Compartilhados (introduzido na v11.0)
│   ├── docker-compose.yml            # Compose dos serviços globais
│   ├── .env                          # Credenciais compartilhadas
│   ├── setup-shared.sh               # Script de inicialização
│   └── ...                           # Configurações (coturn, janus, etc)
│
└── nextcloud-customers/              # Diretório principal da plataforma
    ├── manage.sh                     # Script de gerenciamento (v11.3.4+)
    ├── backups/                      # Backups de todas as instâncias
    ├── <nome-cliente-1>/             # Instância do cliente 1
    │   ├── docker-compose.yml        # Compose da instância (app + cron)
    │   ├── .env                      # Configuração específica do cliente
    │   ├── .credentials              # Arquivo de credenciais legível
    │   ├── app/                      # Dados do Nextcloud
    │   └── harp-certs/               # Certificados HaRP
    └── <nome-cliente-2>/
        └── ...

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

Já conectado ao servidor de destino, clone este repositório em qualquer diretório (sugestão: `/root` ou `~`):

```bash
git clone https://github.com/defensystechbr/nextcloud-saas-manager.git
cd nextcloud-saas-manager
```

> **Sobre permissões:** os scripts deste repositório são sempre invocados via `bash <script>` (veja Passo 2 e o guia de administração), portanto não é necessário rodar `chmod +x` manualmente. O próprio `deploy-server.sh` aplica `chmod +x` no `manage.sh` quando o instala em `/opt/nextcloud-customers/`.

### Passo 2: Executar o Script de Deploy

O script `deploy-server.sh` automatiza toda a preparação do servidor. Ele executa as seguintes etapas:

1. Atualiza o sistema e instala dependências (`curl`, `jq`, `pwgen`, `openssl`).
2. Instala o Docker Engine e Docker Compose (plugin v2) do repositório oficial.
3. Cria a rede Docker `proxy` e a estrutura de diretórios.
4. Configura e inicia o Traefik v3.x (latest) com Let's Encrypt (sem porta 8080 exposta).
5. Instala o `manage.sh` v11.3.4 em `/opt/nextcloud-customers/` e cria o link simbólico `/usr/local/bin/nextcloud-manage`.
6. Configura e inicia os **Serviços Compartilhados** em `/opt/shared-services/`.

Execute com seu e-mail e os tres dominios compartilhados (todos obrigatorios). Os scripts são sempre chamados com `bash` — isso evita depender do bit de execução do filesystem ou do estado pós-`git clone`:

```bash
sudo bash scripts/deploy-server.sh \
    --email seu-email@dominio.com \
    --collabora-domain collabora-01.SEU-DOMINIO.com.br \
    --signaling-domain signaling-01.SEU-DOMINIO.com.br \
    --turn-domain turn-01.SEU-DOMINIO.com.br
```

> **Substitua `SEU-DOMINIO.com.br` pelo dominio que voce controla** e que ja tenha registros DNS A apontando para o IP do servidor (ver secao `DNS Necessarios` acima).

Opcionalmente, pode forcar o IP do servidor (util se a deteccao automatica falhar):

```bash
sudo bash scripts/deploy-server.sh \
    --email seu-email@dominio.com \
    --ip 200.50.151.10 \
    --collabora-domain collabora-01.SEU-DOMINIO.com.br \
    --signaling-domain signaling-01.SEU-DOMINIO.com.br \
    --turn-domain turn-01.SEU-DOMINIO.com.br
```

> **Importante:** se voce nao passar `--turn-domain`, o `manage.sh` instalado ficara com o default `turn-01.defensys.seg.br` hardcoded e gerara configuracoes erradas para suas instancias. Sempre passe os tres dominios.

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

Antes de criar uma nova instância, você **deve** configurar **1 registro DNS do tipo A** no provedor DNS do cliente apontando para o IP do servidor:

| Registro DNS (Tipo A) | Exemplo | Aponta para |
|---|---|---|
| Domínio do Nextcloud | `nextcloud.acme.com.br` | `IP_DO_SERVIDOR` |

**Aguarde a propagação do DNS** antes de prosseguir. O Traefik não conseguirá emitir os certificados SSL se o DNS não estiver resolvendo para o IP do servidor.

### Passo 2: Criar a Instância

```bash
sudo nextcloud-manage acme nextcloud.acme.com.br create
```

O script irá:
1. Verificar se o registro DNS está resolvendo corretamente.
2. Gerar credenciais e criar o database no MariaDB compartilhado.
3. Alocar um DB index exclusivo no Redis compartilhado.
4. Criar o `docker-compose.yml` e o `.env` em `/opt/nextcloud-customers/acme/`.
5. Subir os **3 containers** do cliente (`app`, `cron` e `harp`).
6. Aguardar o Nextcloud inicializar.
7. Configurar integração com os serviços compartilhados (Collabora, Talk HPB, TURN, Redis, HaRP).
8. Exibir as credenciais completas da nova instância.

### Referência Completa de Comandos

| Comando | Sintaxe | Descrição |
|---|---|---|
| **create** | `sudo nextcloud-manage acme nextcloud.acme.com.br create` | Cria uma nova instância |
| **status** | `sudo nextcloud-manage acme _ status` | Mostra status dos containers e URLs |
| **credentials** | `sudo nextcloud-manage acme _ credentials` | Exibe as credenciais da instância |
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

## Aplicativos Instalados Automaticamente

Cada nova instância inclui os seguintes aplicativos pré-configurados:

| Aplicativo | Descrição |
|---|---|
| **Nextcloud Office** (richdocuments) | Edição colaborativa via Collabora Online |
| **Calendar** | Calendário com suporte a CalDAV |
| **Contacts** | Contatos com suporte a CardDAV |
| **Mail** | Cliente de e-mail integrado |
| **Deck** | Kanban para gerenciamento de projetos |
| **Forms** | Formulários e pesquisas |
| **Notes** | Notas em Markdown |
| **Tasks** | Gerenciamento de tarefas |
| **Group Folders** | Pastas compartilhadas por grupo |
| **Photos** | Galeria de fotos |
| **Activity** | Registro de atividades |
| **Talk** (spreed) | Chat, chamadas de voz/vídeo com HPB |
| **AppAPI** | API para aplicativos externos (com HaRP) |
| **Client Push** (notify_push) | Notificações push em tempo real |

---

## Estrutura do Repositório

```
nextcloud-saas-manager/
├── README.md                      # Este arquivo
├── LICENSE                        # Licença MIT
├── .gitignore
├── .github/
│   └── workflows/
│       └── shellcheck.yml         # CI: lint automatico de scripts em PRs
├── scripts/
│   ├── deploy-server.sh           # Script para preparar um novo servidor do zero
│   └── manage.sh                  # Script para gerenciar instancias de clientes (v11.3+)
├── shared-services/               # Definicoes dos servicos compartilhados (8 containers)
│   ├── docker-compose.yml         # Compose dos shared-services
│   ├── setup-shared.sh            # Script alternativo standalone para subir shared-services
│   └── recording/
│       ├── Dockerfile             # Imagem custom do Recording Server (opcional)
│       └── server.conf            # Template de configuracao do Recording Server
└── docs/
    ├── ADMINISTRATION.md          # Guia completo de administracao de instancias
    └── TROUBLESHOOTING.md         # Guia para resolver problemas comuns
```

---

## Contribuindo

Contribuições são bem-vindas. Sinta-se à vontade para abrir uma issue ou enviar um pull request.

## Licença

Este projeto é licenciado sob a Licença MIT. Veja o arquivo [LICENSE](LICENSE) para mais detalhes.
