#!/bin/bash
# ============================================================
# Nextcloud SaaS — Deploy de Servidor de Produção
# Autor: Defensys
# Data: 2026-04-30
# Versão: 2.0 (Arquitetura v11.0 — Serviços Compartilhados)
# ============================================================
#
# Este script prepara um servidor Ubuntu 24.04 (KVM) do zero
# para hospedar instâncias Nextcloud SaaS com:
#   - Docker Engine (repositório oficial)
#   - Docker Compose (plugin v2)
#   - Traefik v3.x (latest) como reverse proxy com Let's Encrypt
#   - Serviços Compartilhados (MariaDB, Redis, Collabora, coturn,
#     NATS, Janus, Signaling, Recording)
#   - manage.sh v11.0 para gerenciamento de instâncias
#   - Dependências: pwgen, jq, curl, openssl
#
# Uso:
#   chmod +x deploy-server.sh
#   sudo ./deploy-server.sh --email admin@dominio.com \
#     --collabora-domain collabora-01.dominio.com \
#     --signaling-domain signaling-01.dominio.com
#
# Requisitos:
#   - Ubuntu 24.04 LTS (KVM recomendado, NÃO LXC)
#   - Acesso root/sudo
#   - Portas 80, 443, 3478 (UDP/TCP) livres
#   - Acesso à internet
#   - DNS configurado para os domínios do Collabora e Signaling
#
# IMPORTANTE:
#   - NÃO use em containers LXC (problemas com /proc/sys)
#   - O Traefik DEVE ser v3.x+ para compatibilidade com Docker 29.x+
#   - Certificados SSL são gerenciados automaticamente pelo Traefik/Let's Encrypt
#   - O coturn usa network_mode: host (porta 3478 UDP/TCP + range 49152-65535)
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

# Verificar se NÃO é LXC (aviso, não bloqueio)
if systemd-detect-virt 2>/dev/null | grep -qi "lxc"; then
    log_warning "Servidor LXC detectado! KVM/QEMU é recomendado para produção."
    log_warning "O Docker pode ter limitações com /proc/sys em containers LXC."
    log_warning "Continuando mesmo assim... Use --force-lxc para suprimir este aviso."
fi

# Parsear argumentos
ACME_EMAIL=""
SERVER_IP=""
COLLABORA_DOMAIN=""
SIGNALING_DOMAIN=""
MANAGE_URL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --email)
            ACME_EMAIL="$2"
            shift 2
            ;;
        --ip)
            SERVER_IP="$2"
            shift 2
            ;;
        --collabora-domain)
            COLLABORA_DOMAIN="$2"
            shift 2
            ;;
        --signaling-domain)
            SIGNALING_DOMAIN="$2"
            shift 2
            ;;
        --manage-url)
            MANAGE_URL="$2"
            shift 2
            ;;
        *)
            log_error "Argumento desconhecido: $1"
            echo ""
            echo "Uso: sudo $0 --email admin@dominio.com \\"
            echo "     --collabora-domain collabora-01.dominio.com \\"
            echo "     --signaling-domain signaling-01.dominio.com \\"
            echo "     [--ip IP_DO_SERVIDOR] [--manage-url URL_DO_MANAGE_SH]"
            exit 1
            ;;
    esac
done

# Validar parâmetros obrigatórios
if [ -z "$ACME_EMAIL" ]; then
    log_error "O e-mail para Let's Encrypt é obrigatório! (--email)"
    echo "Uso: sudo $0 --email admin@dominio.com --collabora-domain ... --signaling-domain ..."
    exit 1
fi

if [ -z "$COLLABORA_DOMAIN" ]; then
    log_error "O domínio do Collabora é obrigatório! (--collabora-domain)"
    echo "Exemplo: --collabora-domain collabora-01.defensys.seg.br"
    exit 1
fi

if [ -z "$SIGNALING_DOMAIN" ]; then
    log_error "O domínio do Signaling é obrigatório! (--signaling-domain)"
    echo "Exemplo: --signaling-domain signaling-01.defensys.seg.br"
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
echo "  Nextcloud SaaS — Deploy de Servidor v2.0"
echo "  Arquitetura v11.0 (Serviços Compartilhados)"
echo "============================================"
echo ""
echo "  E-mail ACME:       $ACME_EMAIL"
echo "  IP Servidor:       $SERVER_IP"
echo "  Collabora Domain:  $COLLABORA_DOMAIN"
echo "  Signaling Domain:  $SIGNALING_DOMAIN"
echo "  Virtualização:     $(systemd-detect-virt 2>/dev/null || echo 'desconhecida')"
echo ""
echo "============================================"
echo ""

# ============================================================
# ETAPA 1: ATUALIZAR SISTEMA E INSTALAR DEPENDÊNCIAS
# ============================================================
log_info "Etapa 1/7: Atualizando sistema e instalando dependências..."

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
    software-properties-common \
    iptables-persistent

log_success "Sistema atualizado e dependências instaladas"

# ============================================================
# ETAPA 2: INSTALAR DOCKER ENGINE (REPOSITÓRIO OFICIAL)
# ============================================================
log_info "Etapa 2/7: Instalando Docker Engine..."

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
# ETAPA 3: CONFIGURAR NAT/MASQUERADE E REDES DOCKER
# ============================================================
log_info "Etapa 3/7: Configurando rede e NAT..."

# Configurar NAT/MASQUERADE para que containers acessem a internet
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$DEFAULT_IFACE" ]; then
    if ! iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
        log_success "Regra NAT/MASQUERADE adicionada (interface: $DEFAULT_IFACE)"
    else
        log_info "NAT/MASQUERADE já configurado"
    fi
    # Persistir regras
    netfilter-persistent save 2>/dev/null || true
else
    log_warning "Interface de rede padrão não encontrada. Verifique NAT manualmente."
fi

# Criar redes Docker
docker network create proxy 2>/dev/null || true
docker network create shared 2>/dev/null || true

# Criar diretórios
mkdir -p /opt/traefik/config
mkdir -p /opt/traefik/logs
mkdir -p /opt/nextcloud-customers/backups
mkdir -p /opt/shared-services/{db,redis,hpb,recording}

log_success "Redes Docker e diretórios criados"

# ============================================================
# ETAPA 4: CONFIGURAR E INICIAR TRAEFIK
# ============================================================
log_info "Etapa 4/7: Configurando Traefik..."

# Criar traefik.yml
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

# Verificar que o provider Docker está funcionando
sleep 3
if docker logs traefik 2>&1 | grep -q "client version.*too old"; then
    log_error "Traefik incompatível com a versão do Docker!"
    exit 1
fi
log_success "Traefik comunicando com Docker corretamente"

# ============================================================
# ETAPA 5: CONFIGURAR E INICIAR SERVIÇOS COMPARTILHADOS
# ============================================================
log_info "Etapa 5/7: Configurando serviços compartilhados..."

SHARED_DIR="/opt/shared-services"

# Gerar secrets
generate_password() { openssl rand -hex 16; }
generate_secret()   { openssl rand -hex 32; }

if [ ! -f "$SHARED_DIR/.env" ]; then
    DB_ROOT_PASSWORD=$(generate_password)
    REDIS_PASSWORD=$(generate_password)
    COLLABORA_ADMIN_PASSWORD=$(generate_password)
    TURN_SECRET=$(generate_secret)
    SIGNALING_SECRET=$(generate_secret)
    SIGNALING_HASH_KEY=$(generate_secret)
    SIGNALING_BLOCK_KEY=$(openssl rand -hex 16)
    SIGNALING_INTERNAL_SECRET=$(generate_secret)
    HARP_SHARED_KEY=$(generate_password)
    RECORDING_SECRET=$(generate_secret)

    cat > "$SHARED_DIR/.env" << EOF
# Nextcloud SaaS — Shared Services Configuration
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')
# NÃO EDITE MANUALMENTE (a menos que saiba o que está fazendo)

# Servidor
SERVER_IP=${SERVER_IP}

# Domínios dos serviços compartilhados
COLLABORA_DOMAIN=${COLLABORA_DOMAIN}
SIGNALING_DOMAIN=${SIGNALING_DOMAIN}

# MariaDB
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}

# Collabora
COLLABORA_ADMIN_PASSWORD=${COLLABORA_ADMIN_PASSWORD}
COLLABORA_ALLOWLIST=

# TURN/STUN
TURN_SECRET=${TURN_SECRET}

# Signaling (HPB)
SIGNALING_SECRET=${SIGNALING_SECRET}
SIGNALING_HASH_KEY=${SIGNALING_HASH_KEY}
SIGNALING_BLOCK_KEY=${SIGNALING_BLOCK_KEY}
SIGNALING_INTERNAL_SECRET=${SIGNALING_INTERNAL_SECRET}

# HaRP (AppAPI)
HARP_SHARED_KEY=${HARP_SHARED_KEY}

# Recording Server
RECORDING_SECRET=${RECORDING_SECRET}
EOF
    chmod 600 "$SHARED_DIR/.env"
    log_success "Credenciais geradas em $SHARED_DIR/.env"
else
    log_info "Credenciais já existem, carregando..."
fi
source "$SHARED_DIR/.env"

# Configurar coturn
cat > "$SHARED_DIR/turnserver.conf" << EOF
listening-port=3478
fingerprint
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=${SERVER_IP}
total-quota=100
bps-capacity=0
stale-nonce=600
no-tls
no-dtls
no-loopback-peers
no-multicast-peers
min-port=49152
max-port=65535
log-file=stdout
new-log-timestamp
external-ip=${SERVER_IP}
EOF

# Configurar NATS
cat > "$SHARED_DIR/hpb/nats.conf" << EOF
listen: 0.0.0.0:4222
EOF

# Configurar Janus
cat > "$SHARED_DIR/hpb/janus.jcfg" << EOF
general: {
    configs_folder = "/usr/etc/janus"
    plugins_folder = "/usr/lib/janus/plugins"
    transports_folder = "/usr/lib/janus/transports"
    events_folder = "/usr/lib/janus/events"
    debug_level = 4
    log_to_stdout = true
    admin_secret = "janusoverlord"
}

nat: {
    ice_lite = false
    ice_tcp = false
    full_trickle = true
    rtp_port_range = "20000-40000"
}

media: {
    ipv6 = false
}

plugins: {
}

transports: {
}
EOF

cat > "$SHARED_DIR/hpb/janus.transport.websockets.jcfg" << EOF
general: {
}

admin: {
    admin_ws = true
    admin_ws_port = 7188
}

ws: {
    ws = true
    ws_port = 8188
    ws_interface = "0.0.0.0"
}

wss: {
    wss = false
}
EOF

cat > "$SHARED_DIR/hpb/janus.plugin.videoroom.jcfg" << EOF
general: {
    admin_key = "supersecret"
}
EOF

# Configurar Signaling
cat > "$SHARED_DIR/hpb/signaling.conf" << EOF
[http]
listen = 0.0.0.0:8080

[app]
debug = false

[sessions]
hashkey = ${SIGNALING_HASH_KEY}
blockkey = ${SIGNALING_BLOCK_KEY}

[clients]
internalsecret = ${SIGNALING_INTERNAL_SECRET}

[nats]
url = nats://shared-nats:4222

[mcu]
type = janus
url = ws://shared-janus:8188

[backend]
backends = 
allowall = false
secret = ${SIGNALING_SECRET}

[turn]
apikey = static
secret = ${TURN_SECRET}
servers = turn:${SERVER_IP}:3478?transport=udp,turn:${SERVER_IP}:3478?transport=tcp
EOF

# Configurar Recording Server
cat > "$SHARED_DIR/recording/recording.conf" << EOF
[app]
debug = false

[signaling]
internalsecret = ${SIGNALING_INTERNAL_SECRET}

[backend]
backends = 
allowall = false
secret = ${RECORDING_SECRET}

[recording]
tempdir = /tmp
EOF

# Criar docker-compose.yml dos serviços compartilhados
cat > "$SHARED_DIR/docker-compose.yml" << 'COMPOSE_EOF'
name: 'shared-services'
services:
  # MariaDB Compartilhado
  db:
    image: mariadb:10.11
    container_name: shared-db
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW --innodb-file-per-table=1 --skip-innodb-read-only-compressed
    networks:
      - shared

  # Redis Compartilhado
  redis:
    image: redis:alpine
    container_name: shared-redis
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - ./redis:/data
    networks:
      - shared

  # Collabora Online — multi-tenant
  collabora:
    image: collabora/code:latest
    container_name: shared-collabora
    restart: always
    environment:
      - "aliasgroup1=${COLLABORA_ALLOWLIST}"
      - username=admin
      - password=${COLLABORA_ADMIN_PASSWORD}
      - "extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:net.frame_ancestors=${COLLABORA_ALLOWLIST}"
      - server_name=${COLLABORA_DOMAIN}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.shared-collabora.rule=Host(`${COLLABORA_DOMAIN}`)"
      - "traefik.http.routers.shared-collabora.entrypoints=websecure"
      - "traefik.http.routers.shared-collabora.tls=true"
      - "traefik.http.routers.shared-collabora.tls.certresolver=letsencrypt"
      - "traefik.http.services.shared-collabora.loadbalancer.server.port=9980"
      - "traefik.docker.network=proxy"
    networks:
      - shared
      - proxy

  # coturn (TURN/STUN) — network_mode: host para WebRTC
  turn:
    image: coturn/coturn:latest
    container_name: shared-turn
    restart: always
    network_mode: host
    volumes:
      - ./turnserver.conf:/etc/coturn/turnserver.conf:ro

  # NATS — Message broker para signaling
  nats:
    image: nats:2.10
    container_name: shared-nats
    restart: always
    volumes:
      - ./hpb/nats.conf:/config/nats.conf:ro
    command: ["-c", "/config/nats.conf"]
    networks:
      - shared

  # Janus Gateway — WebRTC media server
  janus:
    image: canyan/janus-gateway:latest
    container_name: shared-janus
    restart: always
    command: ["janus", "--full-trickle"]
    volumes:
      - ./hpb/janus.jcfg:/usr/etc/janus/janus.jcfg:ro
      - ./hpb/janus.transport.websockets.jcfg:/usr/etc/janus/janus.transport.websockets.jcfg:ro
      - ./hpb/janus.plugin.videoroom.jcfg:/usr/etc/janus/janus.plugin.videoroom.jcfg:ro
    networks:
      - shared

  # Spreed Signaling Server — HPB multi-tenant
  signaling:
    image: strukturag/nextcloud-spreed-signaling:latest
    container_name: shared-signaling
    restart: always
    depends_on:
      - nats
      - janus
    volumes:
      - ./hpb/signaling.conf:/config/server.conf:ro
    environment:
      - CONFIG=/config/server.conf
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.shared-signaling.rule=Host(`${SIGNALING_DOMAIN}`)"
      - "traefik.http.routers.shared-signaling.entrypoints=websecure"
      - "traefik.http.routers.shared-signaling.tls=true"
      - "traefik.http.routers.shared-signaling.tls.certresolver=letsencrypt"
      - "traefik.http.services.shared-signaling.loadbalancer.server.port=8080"
      - "traefik.docker.network=proxy"
    networks:
      - shared
      - proxy

  # Talk Recording Server — multi-backend
  recording:
    image: ghcr.io/nextcloud-releases/aio-talk-recording:latest
    container_name: shared-recording
    restart: always
    init: true
    shm_size: '2gb'
    entrypoint: ["python", "-m", "nextcloud.talk.recording", "--config", "/conf/recording.conf"]
    volumes:
      - ./recording/recording.conf:/conf/recording.conf:ro
      - recording-tmp:/tmp
    depends_on:
      - signaling
    networks:
      - shared

volumes:
  recording-tmp:

networks:
  shared:
    external: true
  proxy:
    external: true
COMPOSE_EOF

log_success "Configurações dos serviços compartilhados criadas"

# Iniciar serviços compartilhados
log_info "Iniciando serviços compartilhados..."
cd "$SHARED_DIR"
docker compose up -d

# Aguardar MariaDB
log_info "Aguardando MariaDB ficar pronto..."
for i in $(seq 1 30); do
    if docker exec shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" -e "SELECT 1" &>/dev/null; then
        log_success "MariaDB pronto!"
        break
    fi
    sleep 2
done

# Verificar todos os serviços
log_info "Verificando serviços compartilhados..."
SERVICES=("shared-db" "shared-redis" "shared-collabora" "shared-turn" "shared-nats" "shared-janus" "shared-signaling" "shared-recording")
SHARED_OK=true
for svc in "${SERVICES[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        log_success "$svc: running"
    else
        log_warning "$svc: NOT running (verificar com: docker logs $svc)"
        SHARED_OK=false
    fi
done

if [ "$SHARED_OK" = true ]; then
    log_success "Todos os serviços compartilhados estão ativos!"
else
    log_warning "Alguns serviços não iniciaram. Verifique os logs."
fi

# ============================================================
# ETAPA 6: INSTALAR MANAGE.SH v11.0
# ============================================================
log_info "Etapa 6/7: Instalando manage.sh v11.0..."

if [ -n "$MANAGE_URL" ]; then
    curl -sSL "$MANAGE_URL" -o /opt/nextcloud-customers/manage.sh
elif [ -f /tmp/manage.sh ]; then
    cp /tmp/manage.sh /opt/nextcloud-customers/manage.sh
else
    log_warning "manage.sh não fornecido. Copie manualmente para /opt/nextcloud-customers/manage.sh"
    log_warning "Use: scp manage.sh user@${SERVER_IP}:/opt/nextcloud-customers/manage.sh"
fi

if [ -f /opt/nextcloud-customers/manage.sh ]; then
    # Atualizar SERVER_IP no manage.sh
    sed -i "s|SERVER_IP=\"[^\"]*\"|SERVER_IP=\"${SERVER_IP}\"|" /opt/nextcloud-customers/manage.sh

    # Permissões e link simbólico
    chmod +x /opt/nextcloud-customers/manage.sh
    ln -sf /opt/nextcloud-customers/manage.sh /usr/local/bin/nextcloud-manage

    log_success "manage.sh v11.0 instalado: nextcloud-manage"
fi

# ============================================================
# ETAPA 7: VALIDAÇÃO FINAL
# ============================================================
log_info "Etapa 7/7: Validação final..."

# Verificar que o Traefik pode emitir certificados (teste de conectividade ACME)
if curl -s --connect-timeout 5 https://acme-v02.api.letsencrypt.org/directory | grep -q "newNonce"; then
    log_success "Let's Encrypt acessível — certificados serão emitidos automaticamente"
else
    log_warning "Let's Encrypt não acessível. Verifique conectividade na porta 443 de saída."
fi

# Contar containers
TOTAL_CONTAINERS=$(docker ps --format '{{.Names}}' | wc -l)
log_success "Total de containers rodando: $TOTAL_CONTAINERS"

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
echo "  IP:                ${SERVER_IP}"
echo "  Docker:            $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')"
echo "  Docker Compose:    $(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')"
echo "  Traefik:           ${TRAEFIK_VER:-latest}"
echo "  ACME Email:        ${ACME_EMAIL}"
echo "  Collabora:         https://${COLLABORA_DOMAIN}"
echo "  Signaling:         https://${SIGNALING_DOMAIN}"
echo "  TURN:              turn:${SERVER_IP}:3478"
echo "  manage.sh:         /opt/nextcloud-customers/manage.sh"
echo "  Comando:           nextcloud-manage"
echo "  Backups:           /opt/nextcloud-customers/backups/"
echo "  Credenciais:       /opt/shared-services/.env"
echo "  Containers:        ${TOTAL_CONTAINERS} ativos"
echo ""
echo "  Serviços Compartilhados (8 containers globais):"
echo "  ─────────────────────────────────────────"
echo "  shared-db          MariaDB 10.11 (1 database por cliente)"
echo "  shared-redis       Redis (1 dbindex por cliente)"
echo "  shared-collabora   Collabora Online (multi-domínio)"
echo "  shared-turn        coturn STUN/TURN (network_mode: host)"
echo "  shared-nats        NATS message broker"
echo "  shared-janus       Janus WebRTC gateway"
echo "  shared-signaling   HPB Signaling (multi-tenant)"
echo "  shared-recording   Talk Recording (multi-backend)"
echo ""
echo "  Para criar a primeira instância:"
echo "  ─────────────────────────────────────────"
echo "  1. Configure 1 registro DNS (tipo A) para o cliente:"
echo "     cloud.cliente.com.br → ${SERVER_IP}"
echo ""
echo "  2. Aguarde a propagação do DNS"
echo ""
echo "  3. Execute:"
echo "     sudo nextcloud-manage cliente1 cloud.cliente.com.br create"
echo ""
echo "  Sintaxe do manage.sh:"
echo "  ─────────────────────────────────────────"
echo "  nextcloud-manage <cliente> <domínio> create    # Criar instância"
echo "  nextcloud-manage <cliente> _ status            # Status"
echo "  nextcloud-manage <cliente> _ credentials       # Credenciais"
echo "  nextcloud-manage <cliente> _ backup            # Backup"
echo "  nextcloud-manage <cliente> _ stop              # Parar"
echo "  nextcloud-manage <cliente> _ start             # Iniciar"
echo "  nextcloud-manage <cliente> _ update            # Atualizar"
echo "  nextcloud-manage <cliente> _ remove            # Remover"
echo "  nextcloud-manage list                          # Listar todas"
echo "  nextcloud-manage shared-status                 # Status compartilhados"
echo ""
echo "============================================"
