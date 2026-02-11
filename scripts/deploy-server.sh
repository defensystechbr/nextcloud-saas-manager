#!/bin/bash
# ============================================================
# Nextcloud SaaS — Deploy de Servidor de Produção
# Autor: Defensys
# Data: 2026-02-11
# Versão: 1.0
# ============================================================
#
# Este script prepara um servidor Ubuntu 24.04 (KVM) do zero
# para hospedar instâncias Nextcloud SaaS com:
#   - Docker Engine (repositório oficial)
#   - Docker Compose (plugin v2)
#   - Traefik v3.x (latest) como reverse proxy com Let's Encrypt
#   - manage.sh v9.0 para gerenciamento de instâncias
#   - Dependências: pwgen, jq, curl, openssl
#
# Uso:
#   chmod +x deploy-server.sh
#   sudo ./deploy-server.sh --email admin@dominio.com
#
# Requisitos:
#   - Ubuntu 24.04 LTS (KVM recomendado, NÃO LXC)
#   - Acesso root/sudo
#   - Portas 80 e 443 livres
#   - Acesso à internet
#
# IMPORTANTE:
#   - NÃO use em containers LXC (problemas com /proc/sys)
#   - O Traefik DEVE ser v3.x+ para compatibilidade com Docker 29.x+
#   - Certificados SSL são gerenciados automaticamente pelo Traefik/Let's Encrypt
# ============================================================

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[AVISO]${NC} $1"; }

# ============================================================
# VALIDAÇÕES
# ============================================================

# Verificar root
if [ "$EUID" -ne 0 ]; then
    log_error "Execute como root: sudo $0 $*"
    exit 1
fi

# Verificar Ubuntu
if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    log_error "Este script requer Ubuntu 24.04 LTS"
    exit 1
fi

# Verificar se NÃO é LXC
if systemd-detect-virt 2>/dev/null | grep -qi "lxc"; then
    log_error "Servidor LXC detectado! Use KVM/QEMU para evitar problemas com Docker."
    log_error "O Docker 29.x+ tem incompatibilidades com /proc/sys em containers LXC."
    exit 1
fi

# Parsear argumentos
ACME_EMAIL=""
MANAGE_URL=""
SERVER_IP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --email)
            ACME_EMAIL="$2"
            shift 2
            ;;
        --manage-url)
            MANAGE_URL="$2"
            shift 2
            ;;
        --ip)
            SERVER_IP="$2"
            shift 2
            ;;
        *)
            log_error "Argumento desconhecido: $1"
            echo "Uso: sudo $0 --email admin@dominio.com [--ip IP_DO_SERVIDOR] [--manage-url URL_DO_MANAGE_SH]"
            exit 1
            ;;
    esac
done

if [ -z "$ACME_EMAIL" ]; then
    log_error "O e-mail para Let's Encrypt é obrigatório!"
    echo "Uso: sudo $0 --email admin@dominio.com [--ip IP_DO_SERVIDOR]"
    exit 1
fi

# Detectar IP público se não fornecido
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null)
    fi
fi

echo ""
echo "============================================"
echo "  Nextcloud SaaS — Deploy de Servidor"
echo "============================================"
echo ""
echo "  E-mail ACME:  $ACME_EMAIL"
echo "  IP Servidor:  $SERVER_IP"
echo "  Virtualização: $(systemd-detect-virt 2>/dev/null || echo 'desconhecida')"
echo ""
echo "============================================"
echo ""

# ============================================================
# ETAPA 1: ATUALIZAR SISTEMA E INSTALAR DEPENDÊNCIAS
# ============================================================
log_info "Etapa 1/5: Atualizando sistema e instalando dependências..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    jq \
    pwgen \
    openssl \
    apt-transport-https \
    software-properties-common

log_success "Sistema atualizado e dependências instaladas"

# ============================================================
# ETAPA 2: INSTALAR DOCKER ENGINE (REPOSITÓRIO OFICIAL)
# ============================================================
log_info "Etapa 2/5: Instalando Docker Engine..."

if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')
    log_warning "Docker já instalado (v${DOCKER_VER}). Pulando instalação."
else
    # Remover versões antigas
    apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Adicionar repositório oficial do Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Habilitar e iniciar Docker
    systemctl enable docker
    systemctl start docker

    log_success "Docker instalado: $(docker --version)"
fi

# Verificar que Docker funciona
if ! docker run --rm hello-world &>/dev/null; then
    log_error "Docker não está funcionando corretamente!"
    exit 1
fi
log_success "Docker funcionando corretamente"

# ============================================================
# ETAPA 3: CRIAR REDE DOCKER E ESTRUTURA DE DIRETÓRIOS
# ============================================================
log_info "Etapa 3/5: Criando estrutura de diretórios..."

# Criar rede proxy (se não existir)
docker network create proxy 2>/dev/null || true

# Criar diretórios
mkdir -p /opt/traefik/config
mkdir -p /opt/traefik/logs
mkdir -p /opt/nextcloud-customers/backups

log_success "Estrutura de diretórios criada"

# ============================================================
# ETAPA 4: CONFIGURAR E INICIAR TRAEFIK
# ============================================================
log_info "Etapa 4/5: Configurando Traefik..."

# Criar traefik.yml
# NOTA: Usar APENAS httpChallenge (NÃO misturar com tlsChallenge)
# NOTA: NÃO usar file provider apontando para si mesmo
cat > /opt/traefik/config/traefik.yml << EOF
api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entrypoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ACME_EMAIL}
      storage: /acme.json
      httpChallenge:
        entryPoint: web

log:
  level: INFO
EOF

# Criar acme.json com permissões corretas
touch /opt/traefik/acme.json
chmod 600 /opt/traefik/acme.json

# Criar docker-compose.yml do Traefik
# NOTA: Usar traefik:latest (v3.x+) — obrigatório para Docker 29.x+ (API mínima 1.44)
# NOTA: Rede proxy DEVE ser external: true (já criada acima)
cat > /opt/traefik/docker-compose.yml << 'EOF'
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/traefik.yml:/traefik.yml:ro
      - ./acme.json:/acme.json
      - ./logs:/var/log/traefik
    networks:
      - proxy

networks:
  proxy:
    name: proxy
    external: true
EOF

# Iniciar Traefik
cd /opt/traefik
docker compose up -d

# Validar Traefik
log_info "Aguardando Traefik iniciar..."
TRAEFIK_OK=false
for i in $(seq 1 30); do
    if docker ps --filter name=traefik --format '{{.Status}}' 2>/dev/null | grep -q "Up"; then
        TRAEFIK_OK=true
        break
    fi
    sleep 2
done

if [ "$TRAEFIK_OK" = true ]; then
    TRAEFIK_VER=$(docker inspect traefik --format '{{.Config.Image}}' 2>/dev/null || echo "latest")
    log_success "Traefik (${TRAEFIK_VER}) rodando"
else
    log_error "Traefik não está respondendo! Verifique: docker logs traefik"
    exit 1
fi

# Verificar que o provider Docker está funcionando (sem erros de API version)
sleep 3
if docker logs traefik 2>&1 | grep -q "client version.*too old"; then
    log_error "Traefik incompatível com a versão do Docker!"
    log_error "Isso geralmente ocorre em containers LXC ou com versões antigas do Traefik."
    log_error "Verifique: docker logs traefik"
    exit 1
fi
log_success "Traefik comunicando com Docker corretamente"

# ============================================================
# ETAPA 5: INSTALAR MANAGE.SH
# ============================================================
log_info "Etapa 5/5: Instalando manage.sh..."

if [ -n "$MANAGE_URL" ]; then
    # Baixar de URL fornecida
    curl -sSL "$MANAGE_URL" -o /opt/nextcloud-customers/manage.sh
elif [ -f /tmp/manage.sh ]; then
    # Copiar de arquivo local
    cp /tmp/manage.sh /opt/nextcloud-customers/manage.sh
else
    log_warning "manage.sh não fornecido. Copie manualmente para /opt/nextcloud-customers/manage.sh"
    log_warning "Use: scp manage.sh user@${SERVER_IP}:/opt/nextcloud-customers/manage.sh"
fi

if [ -f /opt/nextcloud-customers/manage.sh ]; then
    # Atualizar SERVER_IP no manage.sh
    sed -i "s|SERVER_IP=\"[^\"]*\"|SERVER_IP=\"${SERVER_IP}\"|" /opt/nextcloud-customers/manage.sh

    # Garantir que usa docker compose (plugin v2)
    # O manage.sh v9.0 já usa "docker compose" (sem hífen)

    # Permissões e link simbólico
    chmod +x /opt/nextcloud-customers/manage.sh
    ln -sf /opt/nextcloud-customers/manage.sh /usr/local/bin/nextcloud-manage

    log_success "manage.sh instalado: nextcloud-manage"
fi

# ============================================================
# FINALIZAÇÃO
# ============================================================
echo ""
echo "============================================"
log_success "Servidor de produção pronto!"
echo "============================================"
echo ""
echo "  Resumo da instalação:"
echo "  ─────────────────────────────────────────"
echo "  IP:              ${SERVER_IP}"
echo "  Docker:          $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')"
echo "  Docker Compose:  $(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')"
echo "  Traefik:         ${TRAEFIK_VER:-latest}"
echo "  ACME Email:      ${ACME_EMAIL}"
echo "  manage.sh:       /opt/nextcloud-customers/manage.sh"
echo "  Comando:         nextcloud-manage"
echo "  Backups:         /opt/nextcloud-customers/backups/"
echo "  Traefik Dashboard: desabilitado (segurança)"
echo "  Traefik Logs:      docker logs traefik"
echo ""
echo "  Para criar a primeira instância:"
echo "  ─────────────────────────────────────────"
echo "  1. Configure os registros DNS:"
echo "     nextcloud.dominio.com.br      → A → ${SERVER_IP}"
echo "     collabora-nextcloud.dominio.com.br → A → ${SERVER_IP}"
echo ""
echo "  2. Aguarde a propagação do DNS"
echo ""
echo "  3. Execute:"
echo "     sudo nextcloud-manage cliente1 nextcloud.dominio.com.br create"
echo ""
echo "============================================"
