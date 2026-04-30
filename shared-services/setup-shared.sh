#!/bin/bash
# ============================================================
# Nextcloud SaaS — Setup dos Serviços Compartilhados
# Versão: 11.0
# Autor: Defensys
# ============================================================
# Este script inicializa os serviços compartilhados que serão
# usados por todas as instâncias de clientes Nextcloud.
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
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# CONFIGURAÇÃO
# ============================================================
SHARED_DIR="/opt/shared-services"
SERVER_IP="${SERVER_IP:-$(curl -s4 ifconfig.me)}"
COLLABORA_DOMAIN="${COLLABORA_DOMAIN:-collabora-01.defensys.seg.br}"
SIGNALING_DOMAIN="${SIGNALING_DOMAIN:-signaling-01.defensys.seg.br}"

# ============================================================
# VERIFICAÇÕES
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
    log_error "Execute como root: sudo $0"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    log_error "Docker não encontrado. Execute deploy-server.sh primeiro."
    exit 1
fi

# ============================================================
# GERAR SECRETS
# ============================================================
generate_password() { openssl rand -hex 16; }
generate_secret()   { openssl rand -hex 32; }

log_info "============================================"
log_info "Nextcloud SaaS — Setup Serviços Compartilhados"
log_info "============================================"
log_info "IP do Servidor: $SERVER_IP"
log_info "Collabora: $COLLABORA_DOMAIN"
log_info "Signaling: $SIGNALING_DOMAIN"
log_info "============================================"

# ============================================================
# CRIAR ESTRUTURA DE DIRETÓRIOS
# ============================================================
log_info "Criando estrutura de diretórios..."
mkdir -p "$SHARED_DIR"/{db,redis,harp-certs,hpb}

# ============================================================
# GERAR CREDENCIAIS (se não existirem)
# ============================================================
if [ ! -f "$SHARED_DIR/.env" ]; then
    log_info "Gerando credenciais..."
    DB_ROOT_PASSWORD=$(generate_password)
    REDIS_PASSWORD=$(generate_password)
    COLLABORA_ADMIN_PASSWORD=$(generate_password)
    TURN_SECRET=$(generate_secret)
    SIGNALING_SECRET=$(generate_secret)
    SIGNALING_HASH_KEY=$(generate_secret)
    SIGNALING_BLOCK_KEY=$(openssl rand -hex 16)  # MUST be 16 bytes (32 hex chars)
    SIGNALING_INTERNAL_SECRET=$(generate_secret)
    HARP_SHARED_KEY=$(generate_password)

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
EOF
    chmod 600 "$SHARED_DIR/.env"
    log_success "Credenciais geradas em $SHARED_DIR/.env"
else
    log_info "Credenciais já existem, carregando..."
    source "$SHARED_DIR/.env"
fi

# Recarregar variáveis
source "$SHARED_DIR/.env"

# ============================================================
# CONFIGURAÇÃO DO COTURN (turnserver.conf)
# ============================================================
log_info "Configurando coturn..."
cat > "$SHARED_DIR/turnserver.conf" << EOF
# coturn configuration for Nextcloud Talk
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
# Relay port range
min-port=49152
max-port=65535
# Logging
log-file=stdout
new-log-timestamp
# External IP (for NAT)
external-ip=${SERVER_IP}
EOF
log_success "turnserver.conf criado"

# ============================================================
# CONFIGURAÇÃO DO NATS
# ============================================================
log_info "Configurando NATS..."
cat > "$SHARED_DIR/hpb/nats.conf" << EOF
listen: 0.0.0.0:4222
EOF
log_success "nats.conf criado"

# ============================================================
# CONFIGURAÇÃO DO JANUS
# ============================================================
log_info "Configurando Janus Gateway..."
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
log_success "Janus configurado"

# ============================================================
# CONFIGURAÇÃO DO SIGNALING (server.conf)
# ============================================================
log_info "Configurando Signaling Server..."
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
log_success "signaling.conf criado"

# ============================================================
# COPIAR DOCKER-COMPOSE
# ============================================================
log_info "Instalando docker-compose.yml..."
if [ -f "$(dirname "$0")/docker-compose.yml" ]; then
    cp "$(dirname "$0")/docker-compose.yml" "$SHARED_DIR/docker-compose.yml"
elif [ -f "/tmp/shared-services-compose.yml" ]; then
    cp "/tmp/shared-services-compose.yml" "$SHARED_DIR/docker-compose.yml"
else
    log_error "docker-compose.yml não encontrado!"
    log_error "Copie para $SHARED_DIR/docker-compose.yml manualmente."
    exit 1
fi
log_success "docker-compose.yml instalado"

# ============================================================
# CRIAR REDE DOCKER 'shared'
# ============================================================
if ! docker network inspect shared &>/dev/null; then
    log_info "Criando rede Docker 'shared'..."
    docker network create shared
    log_success "Rede 'shared' criada"
else
    log_info "Rede 'shared' já existe"
fi

# ============================================================
# INICIAR SERVIÇOS
# ============================================================
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
log_info "Verificando serviços..."
echo ""
SERVICES=("shared-db" "shared-redis" "shared-collabora" "shared-turn" "shared-nats" "shared-janus" "shared-signaling" "shared-harp")
ALL_OK=true
for svc in "${SERVICES[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        log_success "$svc: running"
    else
        log_error "$svc: NOT running"
        ALL_OK=false
    fi
done

echo ""
if [ "$ALL_OK" = true ]; then
    log_success "============================================"
    log_success "Todos os serviços compartilhados estão ativos!"
    log_success "============================================"
    echo ""
    echo "  Collabora:  https://${COLLABORA_DOMAIN}"
    echo "  Signaling:  https://${SIGNALING_DOMAIN}"
    echo "  TURN:       turn:${SERVER_IP}:3478"
    echo "  MariaDB:    shared-db:3306"
    echo "  Redis:      shared-redis:6379"
    echo "  HaRP:       shared-harp:8780"
    echo ""
    echo "  Credenciais: $SHARED_DIR/.env"
    echo ""
else
    log_error "Alguns serviços falharam. Verifique com: docker compose logs"
fi
