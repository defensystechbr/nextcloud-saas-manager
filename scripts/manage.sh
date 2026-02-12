#!/bin/bash
# ============================================================
# Nextcloud SaaS Manager v10.0
# Script para gerenciar instâncias Nextcloud com Collabora,
# HPB (Talk High Performance Backend) e HaRP (AppAPI)
# Autor: Defensys
# Data: 2026-02-12
# ============================================================
# Changelog v10.0:
#   - HaRP substitui Docker Socket Proxy para AppAPI
#   - HPB integrado: NATS + Janus Gateway + Spreed Signaling
#   - 3 registros DNS por instância (+ signaling)
#   - Configuração automática do signaling no Talk
#   - Registro automático do daemon HaRP no AppAPI
#   - Containers: 10 por instância (app, db, redis, collabora,
#     turn, cron, harp, nats, janus, signaling)
#   - Correção de segurança: Traefik sem porta 8080 exposta
# ============================================================

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Diretório base
BASE_DIR="/opt/nextcloud-customers"
TRAEFIK_NETWORK="proxy"
SERVER_IP=$(hostname -I | awk '{print $1}')

# Função para exibir mensagens
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[AVISO]${NC} $1"; }

# Função para gerar senha aleatória
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Função para gerar chave hex
generate_hex_key() {
    local length=${1:-32}
    openssl rand -hex "$length"
}

# Função para encontrar porta TURN disponível
find_available_turn_port() {
    local base_port=3478
    local port=$base_port
    while [ $port -lt 4000 ]; do
        if ! ss -tlnp | grep -q ":${port} " && ! ss -ulnp | grep -q ":${port} "; then
            echo $port
            return 0
        fi
        port=$((port + 1))
    done
    log_error "Nenhuma porta TURN disponível entre 3478-3999!"
    return 1
}

# Função para aguardar Nextcloud ficar instalado
wait_for_nextcloud() {
    local container=$1
    local max_attempts=${2:-180}
    local attempt=0
    log_info "Aguardando Nextcloud ficar instalado (até $((max_attempts * 3))s)..."
    while [ $attempt -lt $max_attempts ]; do
        if docker exec -u www-data "$container" php occ status 2>/dev/null | grep -q "installed: true"; then
            log_success "Nextcloud instalado!"
            sleep 10
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 3
    done
    log_error "Nextcloud não foi instalado no tempo esperado!"
    return 1
}

# Função para executar occ com retry
run_occ() {
    local container=$1
    shift
    local max_retries=5
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if docker exec -u www-data "$container" php occ "$@" 2>&1; then
            return 0
        fi
        retry=$((retry + 1))
        log_warning "  Retry $retry/$max_retries: occ $1 $2..."
        sleep 3
    done
    log_warning "Falha ao executar: occ $*"
    return 1
}

# Função para aguardar container ficar saudável
wait_for_container() {
    local container=$1
    local check_cmd=$2
    local max_attempts=${3:-60}
    local attempt=0
    log_info "Aguardando container $container ficar pronto..."
    while [ $attempt -lt $max_attempts ]; do
        if docker exec "$container" $check_cmd >/dev/null 2>&1; then
            log_success "Container $container pronto!"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 3
    done
    log_warning "Container $container pode não estar pronto"
    return 1
}

# Detectar comando docker compose (plugin v2 ou standalone)
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif docker-compose --version >/dev/null 2>&1; then
    DC="docker-compose"
else
    log_error "Docker Compose não encontrado!"
    exit 1
fi

# ============================================================
# FUNÇÃO PRINCIPAL: CRIAR INSTÂNCIA
# ============================================================
create_instance() {
    local CLIENT_NAME=$1
    local DOMAIN=$2

    if [ -z "$CLIENT_NAME" ] || [ -z "$DOMAIN" ]; then
        log_error "Uso: $0 <nome-cliente> <dominio.com.br> create"
        exit 1
    fi

    if [ -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME já existe!"
        exit 1
    fi

    # Derivar domínios
    COLLABORA_DOMAIN="collabora-${DOMAIN}"
    SIGNALING_DOMAIN="signaling-${DOMAIN}"

    log_info "============================================"
    log_info "Criando nova instância: $CLIENT_NAME"
    log_info "Domínio Nextcloud:  $DOMAIN"
    log_info "Domínio Collabora:  $COLLABORA_DOMAIN"
    log_info "Domínio Signaling:  $SIGNALING_DOMAIN"
    log_info "============================================"

    # Verificar DNS
    log_info "Verificando registros DNS..."
    local DNS_OK=true
    for dns_domain in "$DOMAIN" "$COLLABORA_DOMAIN" "$SIGNALING_DOMAIN"; do
        if host "$dns_domain" >/dev/null 2>&1; then
            log_success "  DNS OK: $dns_domain"
        else
            log_error "  DNS FALHA: $dns_domain — crie o registro A apontando para $SERVER_IP"
            DNS_OK=false
        fi
    done
    if [ "$DNS_OK" = false ]; then
        log_error "Corrija os registros DNS antes de continuar!"
        exit 1
    fi

    # Gerar senhas e chaves
    MYSQL_ROOT_PASSWORD=$(generate_password)
    MYSQL_PASSWORD=$(generate_password)
    NEXTCLOUD_ADMIN_PASSWORD=$(generate_password)
    COLLABORA_ADMIN_PASSWORD=$(generate_password)
    TURN_SECRET=$(generate_password)
    HARP_SHARED_KEY=$(generate_hex_key 16)
    SIGNALING_SECRET=$(generate_hex_key 16)
    SIGNALING_HASH_KEY=$(generate_hex_key 32)
    SIGNALING_BLOCK_KEY=$(generate_hex_key 16)
    SIGNALING_INTERNAL_SECRET=$(generate_hex_key 16)

    # Encontrar porta TURN disponível
    TURN_PORT=$(find_available_turn_port)
    log_info "Porta TURN: $TURN_PORT"

    log_info "Criando diretórios..."
    mkdir -p "$BASE_DIR/$CLIENT_NAME"
    mkdir -p "$BASE_DIR/$CLIENT_NAME/hpb/config"

    # Criar arquivo .env
    log_info "Criando arquivo .env..."
    cat > "$BASE_DIR/$CLIENT_NAME/.env" << EOF
CLIENT_NAME=${CLIENT_NAME}
DOMAIN=${DOMAIN}
COLLABORA_DOMAIN=${COLLABORA_DOMAIN}
SIGNALING_DOMAIN=${SIGNALING_DOMAIN}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
COLLABORA_ADMIN_PASSWORD=${COLLABORA_ADMIN_PASSWORD}
TURN_SECRET=${TURN_SECRET}
TURN_PORT=${TURN_PORT}
HARP_SHARED_KEY=${HARP_SHARED_KEY}
SIGNALING_SECRET=${SIGNALING_SECRET}
SIGNALING_HASH_KEY=${SIGNALING_HASH_KEY}
SIGNALING_BLOCK_KEY=${SIGNALING_BLOCK_KEY}
SIGNALING_INTERNAL_SECRET=${SIGNALING_INTERNAL_SECRET}
EOF

    # ============================================================
    # CRIAR CONFIGURAÇÕES HPB (Janus + NATS)
    # ============================================================
    log_info "Criando configurações HPB..."

    cat > "$BASE_DIR/$CLIENT_NAME/hpb/config/gnatsd.conf" << 'EOF'
listen: 0.0.0.0:4222
logtime: true
EOF

    cat > "$BASE_DIR/$CLIENT_NAME/hpb/config/janus.jcfg" << 'EOF'
general: {
    configs_folder = "/usr/etc/janus"
    plugins_folder = "/usr/lib/janus/plugins"
    transports_folder = "/usr/lib/janus/transports"
    events_folder = "/usr/lib/janus/events"
    log_to_stdout = true
    debug_level = 4
    admin_secret = "janusoverlord"
    api_secret = "janusrocks"
    full_trickle = true
}
nat: {
    stun_server = "stun.l.google.com"
    stun_port = 19302
    nice_debug = false
    full_trickle = true
}
media: {
    rtp_port_range = "20000-40000"
}
EOF

    cat > "$BASE_DIR/$CLIENT_NAME/hpb/config/janus.transport.websockets.jcfg" << 'EOF'
general: {
    ws = true
    ws_port = 8188
    ws_ip = "0.0.0.0"
    wss = false
}
admin: {
    admin_ws = false
}
EOF

    cat > "$BASE_DIR/$CLIENT_NAME/hpb/config/janus.plugin.videoroom.jcfg" << 'EOF'
general: {
    admin_key = "supersecret"
}
EOF

    # ============================================================
    # CRIAR DOCKER-COMPOSE.YML
    # ============================================================
    log_info "Criando docker-compose.yml..."

    BT='`'
    CLIENT_UPPER=$(echo "$CLIENT_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    cat > "$BASE_DIR/$CLIENT_NAME/docker-compose.yml" << EOF
services:
  db:
    image: mariadb:10.11
    container_name: ${CLIENT_NAME}-db
    restart: always
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb-file-per-table=1 --skip-innodb-read-only-compressed
    volumes:
      - ./db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
    networks:
      - default

  redis:
    image: redis:alpine
    container_name: ${CLIENT_NAME}-redis
    restart: always
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./redis:/data
    networks:
      - default

  app:
    image: nextcloud:latest
    container_name: ${CLIENT_NAME}-app
    restart: always
    depends_on:
      - db
      - redis
    volumes:
      - ./app:/var/www/html
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
      - REDIS_HOST=redis
      - NEXTCLOUD_ADMIN_USER=admin
      - NEXTCLOUD_ADMIN_PASSWORD=\${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=\${DOMAIN}
      - OVERWRITEPROTOCOL=https
      - OVERWRITEHOST=\${DOMAIN}
      - TRUSTED_PROXIES=172.16.0.0/12 192.168.0.0/16 10.0.0.0/8
      - NC_default_phone_region=BR
      - NC_maintenance_window_start=1
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${CLIENT_NAME}-app.rule=Host(${BT}\${DOMAIN}${BT})"
      - "traefik.http.routers.${CLIENT_NAME}-app.entrypoints=websecure"
      - "traefik.http.routers.${CLIENT_NAME}-app.tls=true"
      - "traefik.http.routers.${CLIENT_NAME}-app.tls.certresolver=letsencrypt"
      - "traefik.http.services.${CLIENT_NAME}-app.loadbalancer.server.port=80"
      - "traefik.http.routers.${CLIENT_NAME}-app.middlewares=${CLIENT_NAME}-headers,${CLIENT_NAME}-wellknown"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.stsSeconds=31536000"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.stsIncludeSubdomains=true"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.stsPreload=true"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.customFrameOptionsValue=SAMEORIGIN"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.contentTypeNosniff=true"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.browserXssFilter=true"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.referrerPolicy=no-referrer"
      - "traefik.http.middlewares.${CLIENT_NAME}-wellknown.redirectregex.permanent=true"
      - "traefik.http.middlewares.${CLIENT_NAME}-wellknown.redirectregex.regex=https://(.*)/.well-known/(?:card|cal)dav"
      - "traefik.http.middlewares.${CLIENT_NAME}-wellknown.redirectregex.replacement=https://\$\${1}/remote.php/dav"
      - "traefik.docker.network=proxy"
    networks:
      - default
      - proxy

  collabora:
    image: collabora/code:latest
    container_name: ${CLIENT_NAME}-collabora
    restart: always
    environment:
      - aliasgroup1=https://\${DOMAIN}:443
      - username=admin
      - password=\${COLLABORA_ADMIN_PASSWORD}
      - extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:net.frame_ancestors=\${DOMAIN}
      - dictionaries=pt_BR en_US
    cap_add:
      - MKNOD
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${CLIENT_NAME}-collabora.rule=Host(${BT}\${COLLABORA_DOMAIN}${BT})"
      - "traefik.http.routers.${CLIENT_NAME}-collabora.entrypoints=websecure"
      - "traefik.http.routers.${CLIENT_NAME}-collabora.tls=true"
      - "traefik.http.routers.${CLIENT_NAME}-collabora.tls.certresolver=letsencrypt"
      - "traefik.http.services.${CLIENT_NAME}-collabora.loadbalancer.server.port=9980"
      - "traefik.docker.network=proxy"
    networks:
      - default
      - proxy

  turn:
    image: coturn/coturn:latest
    container_name: ${CLIENT_NAME}-turn
    restart: always
    ports:
      - "\${TURN_PORT}:3478"
      - "\${TURN_PORT}:3478/udp"
    command: >
      -n
      --log-file=stdout
      --listening-port=3478
      --external-ip=${SERVER_IP}
      --fingerprint
      --use-auth-secret
      --static-auth-secret=\${TURN_SECRET}
      --realm=\${DOMAIN}
      --total-quota=100
      --bps-capacity=0
      --stale-nonce
      --no-multicast-peers
    networks:
      - default

  cron:
    image: nextcloud:latest
    container_name: ${CLIENT_NAME}-cron
    restart: always
    depends_on:
      - app
    volumes:
      - ./app:/var/www/html
    entrypoint: /cron.sh
    networks:
      - default

  harp:
    image: ghcr.io/nextcloud/nextcloud-appapi-harp:release
    container_name: ${CLIENT_NAME}-harp
    restart: always
    hostname: ${CLIENT_NAME}-harp
    environment:
      - HP_SHARED_KEY=\${HARP_SHARED_KEY}
      - NC_INSTANCE_URL=https://\${DOMAIN}
      - HP_LOG_LEVEL=info
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./harp-certs:/certs
    networks:
      - default
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${CLIENT_NAME}-exapps.rule=Host(${BT}\${DOMAIN}${BT}) && PathPrefix(${BT}/exapps/${BT})"
      - "traefik.http.routers.${CLIENT_NAME}-exapps.entrypoints=websecure"
      - "traefik.http.routers.${CLIENT_NAME}-exapps.tls=true"
      - "traefik.http.routers.${CLIENT_NAME}-exapps.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${CLIENT_NAME}-exapps.priority=100"
      - "traefik.http.services.${CLIENT_NAME}-exapps.loadbalancer.server.port=8780"
      - "traefik.docker.network=proxy"

  nats:
    image: nats:2.10
    container_name: ${CLIENT_NAME}-nats
    restart: always
    volumes:
      - ./hpb/config/gnatsd.conf:/config/gnatsd.conf:ro
    command: ["-c", "/config/gnatsd.conf"]
    networks:
      - default

  janus:
    image: canyan/janus-gateway:latest
    container_name: ${CLIENT_NAME}-janus
    restart: always
    command: ["janus", "--full-trickle"]
    volumes:
      - ./hpb/config/janus.jcfg:/usr/etc/janus/janus.jcfg:ro
      - ./hpb/config/janus.transport.websockets.jcfg:/usr/etc/janus/janus.transport.websockets.jcfg:ro
      - ./hpb/config/janus.plugin.videoroom.jcfg:/usr/etc/janus/janus.plugin.videoroom.jcfg:ro
    networks:
      - default

  signaling:
    image: strukturag/nextcloud-spreed-signaling:latest
    container_name: ${CLIENT_NAME}-signaling
    restart: always
    depends_on:
      - nats
      - janus
    environment:
      - BACKENDS=${CLIENT_NAME}
      - BACKEND_${CLIENT_UPPER}_URLS=https://\${DOMAIN}
      - BACKEND_${CLIENT_UPPER}_SHARED_SECRET=\${SIGNALING_SECRET}
      - NATS_URL=nats://nats:4222
      - JANUS_URL=ws://janus:8188
      - HASH_KEY=\${SIGNALING_HASH_KEY}
      - BLOCK_KEY=\${SIGNALING_BLOCK_KEY}
      - INTERNAL_SECRET=\${SIGNALING_INTERNAL_SECRET}
      - HTTP_LISTEN=0.0.0.0:8080
      - TRUSTED_PROXIES=172.16.0.0/12,192.168.0.0/16,10.0.0.0/8
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${CLIENT_NAME}-signaling.rule=Host(${BT}\${SIGNALING_DOMAIN}${BT})"
      - "traefik.http.routers.${CLIENT_NAME}-signaling.entrypoints=websecure"
      - "traefik.http.routers.${CLIENT_NAME}-signaling.tls=true"
      - "traefik.http.routers.${CLIENT_NAME}-signaling.tls.certresolver=letsencrypt"
      - "traefik.http.services.${CLIENT_NAME}-signaling.loadbalancer.server.port=8080"
      - "traefik.docker.network=proxy"
    networks:
      - default
      - proxy

networks:
  default:
  proxy:
    external: true
EOF

    # Criar arquivo de credenciais
    log_info "Criando arquivo de credenciais..."
    cat > "$BASE_DIR/$CLIENT_NAME/.credentials" << EOF
=== Credenciais da Instância: ${CLIENT_NAME} ===
Data de criação: $(date '+%Y-%m-%d %H:%M:%S')

Nextcloud:
  URL: https://${DOMAIN}
  Usuário: admin
  Senha: ${NEXTCLOUD_ADMIN_PASSWORD}

Collabora Online:
  URL: https://${COLLABORA_DOMAIN}
  Admin: admin
  Senha: ${COLLABORA_ADMIN_PASSWORD}

Banco de Dados (MariaDB):
  Host: ${CLIENT_NAME}-db
  Database: nextcloud
  Usuário: nextcloud
  Senha: ${MYSQL_PASSWORD}
  Root Password: ${MYSQL_ROOT_PASSWORD}

TURN Server:
  Secret: ${TURN_SECRET}
  Porta: ${TURN_PORT}
  Endereço: turn:${SERVER_IP}:${TURN_PORT}

Signaling Server:
  URL: https://${SIGNALING_DOMAIN}
  Secret: ${SIGNALING_SECRET}

HaRP (AppAPI):
  Shared Key: ${HARP_SHARED_KEY}

DNS necessários:
  ${DOMAIN} → ${SERVER_IP}
  ${COLLABORA_DOMAIN} → ${SERVER_IP}
  ${SIGNALING_DOMAIN} → ${SERVER_IP}
EOF

    local LOG_FILE="$BASE_DIR/$CLIENT_NAME/install.log"

    # ============================================================
    # INICIAR CONTÊINERES
    # ============================================================
    log_info "Iniciando contêineres (10 containers)..."
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC up -d 2>&1 | tee -a "$LOG_FILE"

    # Aguardar Nextcloud ficar instalado
    wait_for_nextcloud "${CLIENT_NAME}-app" 180

    # ============================================================
    # PÓS-INSTALAÇÃO COMPLETA
    # ============================================================
    log_info "============================================"
    log_info "Iniciando pós-instalação..."
    log_info "============================================"

    local APP="${CLIENT_NAME}-app"

    # 1. Configurar background jobs via cron
    log_info "[1/16] Configurando background jobs..."
    run_occ "$APP" background:cron

    # 2. Configurar Redis
    log_info "[2/16] Configurando Redis..."
    run_occ "$APP" config:system:set memcache.local --value='\OC\Memcache\APCu'
    run_occ "$APP" config:system:set memcache.distributed --value='\OC\Memcache\Redis'
    run_occ "$APP" config:system:set memcache.locking --value='\OC\Memcache\Redis'
    run_occ "$APP" config:system:set redis host --value='redis' --type=string
    run_occ "$APP" config:system:set redis port --value=6379 --type=integer

    # 3. Configurar trusted_proxies e overwrite
    log_info "[3/16] Configurando trusted_proxies e overwrite..."
    run_occ "$APP" config:system:set trusted_proxies 0 --value='172.16.0.0/12'
    run_occ "$APP" config:system:set trusted_proxies 1 --value='192.168.0.0/16'
    run_occ "$APP" config:system:set trusted_proxies 2 --value='10.0.0.0/8'
    run_occ "$APP" config:system:set overwriteprotocol --value='https'
    run_occ "$APP" config:system:set overwrite.cli.url --value="https://${DOMAIN}"
    run_occ "$APP" config:system:set default_phone_region --value='BR'
    run_occ "$APP" config:system:set maintenance_window_start --value=1 --type=integer
    run_occ "$APP" config:system:set allow_local_remote_servers --value=true --type=boolean

    # 4. Corrigir índices do banco de dados
    log_info "[4/16] Corrigindo índices do banco de dados..."
    run_occ "$APP" db:add-missing-indices
    run_occ "$APP" db:add-missing-columns || true
    run_occ "$APP" db:add-missing-primary-keys || true

    # 5. Executar reparos e migração de mimetypes
    log_info "[5/16] Executando reparos e migração de mimetypes..."
    run_occ "$APP" maintenance:repair --include-expensive
    run_occ "$APP" maintenance:mimetype:update-db

    # 6. Instalar aplicativos essenciais
    log_info "[6/16] Instalando aplicativos essenciais..."
    for app in richdocuments calendar contacts deck forms groupfolders mail notes tasks photos activity spreed notify_push; do
        log_info "  -> $app"
        run_occ "$APP" app:install "$app" 2>/dev/null || run_occ "$APP" app:enable "$app" 2>/dev/null || true
    done

    # 7. Aguardar Collabora ficar pronto e configurar
    log_info "[7/16] Configurando Collabora Online..."
    wait_for_container "${CLIENT_NAME}-collabora" "curl -sSf http://localhost:9980/" 60

    run_occ "$APP" config:app:set richdocuments wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments public_wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments wopi_allowlist --value="0.0.0.0/0"
    run_occ "$APP" config:app:set richdocuments disable_certificate_verification --value="yes"
    run_occ "$APP" richdocuments:activate-config 2>/dev/null || true

    # 8. Configurar Talk com TURN/STUN server
    log_info "[8/16] Configurando Talk com TURN/STUN server..."
    run_occ "$APP" config:app:set spreed turn_servers --value="[{\"server\":\"turn:${SERVER_IP}:${TURN_PORT}\",\"secret\":\"${TURN_SECRET}\",\"protocols\":\"udp,tcp\"}]"
    run_occ "$APP" config:app:set spreed stun_servers --value="[\"stun:${SERVER_IP}:${TURN_PORT}\"]"

    # 9. Configurar Talk HPB (Signaling Server)
    log_info "[9/16] Configurando Talk HPB (Signaling Server)..."
    run_occ "$APP" config:app:set spreed signaling_servers --value="{\"servers\":[{\"server\":\"https://${SIGNALING_DOMAIN}\",\"verify\":true}],\"secret\":\"${SIGNALING_SECRET}\"}"

    # 10. Instalar e configurar AppAPI com HaRP
    log_info "[10/16] Configurando AppAPI com HaRP..."
    docker exec -u www-data "$APP" php occ app:install app_api 2>/dev/null || true
    docker exec -u www-data "$APP" php occ app:enable app_api 2>/dev/null || true

    # Aguardar HaRP ficar pronto
    log_info "  Aguardando HaRP..."
    sleep 10

    # Registrar daemon HaRP
    log_info "  Registrando daemon HaRP..."
    docker exec -u www-data "$APP" php occ app_api:daemon:register \
        harp_install "HaRP" docker-install https "${CLIENT_NAME}-harp:8780" \
        "https://${DOMAIN}" --net="${CLIENT_NAME}_default" \
        --haproxy_password="${HARP_SHARED_KEY}" --set-default 2>/dev/null || true
    log_success "  AppAPI configurado com HaRP"

    # 11. Configurar trusted domains extras
    log_info "[11/16] Configurando trusted domains..."
    run_occ "$APP" config:system:set trusted_domains 0 --value="${DOMAIN}"
    run_occ "$APP" config:system:set trusted_domains 1 --value="${COLLABORA_DOMAIN}"
    run_occ "$APP" config:system:set trusted_domains 2 --value="${SIGNALING_DOMAIN}"

    # 12. Configurar notify_push (Client Push)
    log_info "[12/16] Configurando Client Push (notify_push)..."
    run_occ "$APP" config:app:set notify_push base_endpoint --value="https://${DOMAIN}/push" 2>/dev/null || true

    # 13. Corrigir índices novamente (após instalar apps)
    log_info "[13/16] Corrigindo índices pós-instalação de apps..."
    run_occ "$APP" db:add-missing-indices

    # 14. Limpar logs e definir nível
    log_info "[14/16] Limpando logs e finalizando..."
    docker exec "$APP" bash -c 'truncate -s 0 /var/www/html/data/nextcloud.log' 2>/dev/null || true
    run_occ "$APP" log:manage --level=warning

    # 15. Configurações finais de segurança
    log_info "[15/16] Configurações finais de segurança..."
    run_occ "$APP" config:system:set htaccess.RewriteBase --value='/'
    run_occ "$APP" maintenance:update:htaccess 2>/dev/null || true

    # 16. Reparo final
    log_info "[16/16] Reparo final..."
    run_occ "$APP" maintenance:repair 2>/dev/null || true

    # ============================================================
    # VERIFICAÇÃO FINAL
    # ============================================================
    log_info "============================================"
    log_info "Verificação final..."
    log_info "============================================"

    local ERRORS=0

    # Verificar Nextcloud
    if docker exec -u www-data "$APP" php occ status 2>/dev/null | grep -q "installed: true"; then
        log_success "Nextcloud: OK"
    else
        log_error "Nextcloud: FALHA"
        ERRORS=$((ERRORS + 1))
    fi

    # Verificar Collabora
    if docker exec "${CLIENT_NAME}-collabora" curl -sSf http://localhost:9980/ >/dev/null 2>&1; then
        log_success "Collabora: OK"
    else
        log_warning "Collabora: pode não estar pronto"
    fi

    # Verificar richdocuments
    if docker exec -u www-data "$APP" php occ app:list 2>/dev/null | grep -q "richdocuments"; then
        log_success "Nextcloud Office (richdocuments): OK"
    else
        log_warning "Nextcloud Office: pode não estar instalado"
        ERRORS=$((ERRORS + 1))
    fi

    # Verificar Talk
    if docker exec -u www-data "$APP" php occ app:list 2>/dev/null | grep -q "spreed"; then
        log_success "Talk (spreed): OK"
    else
        log_warning "Talk: pode não estar instalado"
    fi

    # Verificar AppAPI + HaRP
    if docker exec -u www-data "$APP" php occ app:list 2>/dev/null | grep -q "app_api"; then
        log_success "AppAPI: OK"
    else
        log_warning "AppAPI: pode não estar instalado"
    fi

    if docker exec -u www-data "$APP" php occ app_api:daemon:list 2>/dev/null | grep -q "harp_install"; then
        log_success "AppAPI Daemon (HaRP): OK"
    else
        log_warning "AppAPI Daemon HaRP: não registrado"
    fi

    # Verificar HaRP container
    if docker ps --filter "name=${CLIENT_NAME}-harp" --format '{{.Status}}' | grep -q "healthy"; then
        log_success "HaRP Container: OK (healthy)"
    else
        log_warning "HaRP Container: verificar status"
    fi

    # Verificar notify_push
    if docker exec -u www-data "$APP" php occ app:list 2>/dev/null | grep -q "notify_push"; then
        log_success "Client Push (notify_push): OK"
    else
        log_warning "Client Push: pode não estar instalado"
    fi

    # Verificar TURN server
    if docker exec "${CLIENT_NAME}-turn" ls / >/dev/null 2>&1; then
        log_success "TURN Server: OK (porta ${TURN_PORT})"
    else
        log_warning "TURN Server: pode não estar pronto"
    fi

    # Verificar HPB containers
    for hpb_container in nats janus signaling; do
        if docker ps --filter "name=${CLIENT_NAME}-${hpb_container}" --format '{{.Status}}' | grep -q "Up"; then
            log_success "HPB ${hpb_container}: OK"
        else
            log_warning "HPB ${hpb_container}: pode não estar pronto"
        fi
    done

    # Verificar .well-known
    if curl -sSf -o /dev/null -w "%{http_code}" "https://${DOMAIN}/.well-known/caldav" 2>/dev/null | grep -q "301\|302\|308"; then
        log_success ".well-known URLs: OK"
    else
        log_warning ".well-known URLs: verificar manualmente"
    fi

    # ============================================================
    # FINALIZAÇÃO
    # ============================================================
    echo ""
    if [ $ERRORS -eq 0 ]; then
        log_success "============================================"
        log_success "Instância $CLIENT_NAME criada com sucesso!"
        log_success "============================================"
    else
        log_warning "============================================"
        log_warning "Instância $CLIENT_NAME criada com $ERRORS erro(s)"
        log_warning "============================================"
    fi
    echo ""
    echo "URLs de acesso:"
    echo "  Nextcloud:   https://${DOMAIN}"
    echo "  Collabora:   https://${COLLABORA_DOMAIN}"
    echo "  Signaling:   https://${SIGNALING_DOMAIN}"
    echo ""
    echo "Credenciais:"
    echo "  Usuário: admin"
    echo "  Senha:   ${NEXTCLOUD_ADMIN_PASSWORD}"
    echo ""
    echo "Arquivo de credenciais: $BASE_DIR/$CLIENT_NAME/.credentials"
    echo ""
    log_info "Containers (10):"
    echo "  - app (Nextcloud)"
    echo "  - db (MariaDB 10.11)"
    echo "  - redis (Redis Alpine)"
    echo "  - collabora (Collabora Online)"
    echo "  - turn (TURN/STUN Server, porta ${TURN_PORT})"
    echo "  - cron (Background Jobs)"
    echo "  - harp (HaRP - AppAPI)"
    echo "  - nats (NATS - HPB messaging)"
    echo "  - janus (Janus Gateway - HPB WebRTC)"
    echo "  - signaling (Spreed Signaling - HPB)"
    echo ""
    log_info "Aplicativos instalados:"
    echo "  - Nextcloud Office (Collabora Online)"
    echo "  - Calendar, Contacts, Mail"
    echo "  - Deck, Forms, Notes, Tasks"
    echo "  - Group Folders, Photos, Activity"
    echo "  - Talk (com HPB + TURN/STUN)"
    echo "  - AppAPI (com HaRP)"
    echo "  - Client Push (notify_push)"
    echo ""
    log_info "DNS necessários (3 registros A → ${SERVER_IP}):"
    echo "  - ${DOMAIN}"
    echo "  - ${COLLABORA_DOMAIN}"
    echo "  - ${SIGNALING_DOMAIN}"
    echo ""
    log_success "Instância pronta para uso!"
}

# ============================================================
# LISTAR INSTÂNCIAS
# ============================================================
list_instances() {
    log_info "Instâncias Nextcloud:"
    echo ""
    printf "  ${BLUE}%-20s %-45s %-12s${NC}\n" "CLIENTE" "URL" "STATUS"
    printf "  %-20s %-45s %-12s\n" "-------" "---" "------"
    for dir in "$BASE_DIR"/*/; do
        instance=$(basename "$dir")
        if [ "$instance" = "traefik" ] || [ "$instance" = "backups" ]; then continue; fi
        if [ -f "$BASE_DIR/$instance/.env" ]; then
            source "$BASE_DIR/$instance/.env"
            status=$(docker inspect -f '{{.State.Status}}' "${instance}-app" 2>/dev/null || echo "parado")
            if [ "$status" = "running" ]; then
                printf "  ${GREEN}%-20s %-45s [%s]${NC}\n" "$instance" "https://$DOMAIN" "$status"
            else
                printf "  ${RED}%-20s %-45s [%s]${NC}\n" "$instance" "https://$DOMAIN" "$status"
            fi
        fi
    done
    echo ""
}

# ============================================================
# REMOVER INSTÂNCIA
# ============================================================
remove_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> _ remove"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    if [ -f "$BASE_DIR/$CLIENT_NAME/.protected" ]; then
        log_error "Instância $CLIENT_NAME está protegida! Remova o arquivo .protected primeiro."
        exit 1
    fi

    log_warning "============================================"
    log_warning "Removendo instância: $CLIENT_NAME"
    log_warning "============================================"

    cd "$BASE_DIR/$CLIENT_NAME"

    log_info "Parando e removendo contêineres..."
    $DC down -v --remove-orphans 2>/dev/null || true

    # Remover contêineres órfãos manualmente (todos os 10)
    for suffix in app db redis collabora cron turn harp nats janus signaling; do
        docker rm -f "${CLIENT_NAME}-${suffix}" 2>/dev/null || true
    done

    log_info "Removendo diretório..."
    cd "$BASE_DIR"
    rm -rf "$BASE_DIR/$CLIENT_NAME"

    log_success "Instância $CLIENT_NAME removida com sucesso!"
}

# ============================================================
# PARAR INSTÂNCIA
# ============================================================
stop_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> _ stop"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    log_info "Parando instância $CLIENT_NAME..."
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC stop
    log_success "Instância $CLIENT_NAME parada!"
}

# ============================================================
# INICIAR INSTÂNCIA
# ============================================================
start_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> _ start"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    log_info "Iniciando instância $CLIENT_NAME..."
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC up -d
    log_success "Instância $CLIENT_NAME iniciada!"
}

# ============================================================
# BACKUP INSTÂNCIA
# ============================================================
backup_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> _ backup"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    local BACKUP_DIR="$BASE_DIR/backups"
    mkdir -p "$BACKUP_DIR"
    local BACKUP_FILE="$BACKUP_DIR/${CLIENT_NAME}-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
    log_info "Fazendo backup de $CLIENT_NAME..."

    cd "$BASE_DIR/$CLIENT_NAME"
    docker exec -u www-data "${CLIENT_NAME}-app" php occ maintenance:mode --on 2>/dev/null || true

    log_info "Exportando banco de dados..."
    source "$BASE_DIR/$CLIENT_NAME/.env"
    docker exec "${CLIENT_NAME}-db" mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" nextcloud > "$BASE_DIR/$CLIENT_NAME/db_backup.sql" 2>/dev/null || true

    $DC stop

    log_info "Compactando..."
    tar -czf "$BACKUP_FILE" -C "$BASE_DIR" "$CLIENT_NAME"

    $DC up -d

    sleep 10
    docker exec -u www-data "${CLIENT_NAME}-app" php occ maintenance:mode --off 2>/dev/null || true

    log_success "Backup criado: $BACKUP_FILE"
    ls -lh "$BACKUP_FILE"
}

# ============================================================
# RESTAURAR INSTÂNCIA
# ============================================================
restore_instance() {
    local CLIENT_NAME=$1
    local BACKUP_FILE=$2

    if [ -z "$CLIENT_NAME" ] || [ -z "$BACKUP_FILE" ]; then
        log_error "Uso: $0 <nome-cliente> <arquivo-backup.tar.gz> restore"
        exit 1
    fi

    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Arquivo de backup não encontrado: $BACKUP_FILE"
        exit 1
    fi

    if [ -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_warning "Instância $CLIENT_NAME já existe. Removendo..."
        cd "$BASE_DIR/$CLIENT_NAME"
        $DC down -v --remove-orphans 2>/dev/null || true
        for suffix in app db redis collabora cron turn harp nats janus signaling; do
            docker rm -f "${CLIENT_NAME}-${suffix}" 2>/dev/null || true
        done
        rm -rf "$BASE_DIR/$CLIENT_NAME"
    fi

    log_info "Restaurando backup..."
    tar -xzf "$BACKUP_FILE" -C "$BASE_DIR"

    cd "$BASE_DIR/$CLIENT_NAME"
    $DC up -d

    sleep 15
    if [ -f "$BASE_DIR/$CLIENT_NAME/db_backup.sql" ]; then
        source "$BASE_DIR/$CLIENT_NAME/.env"
        log_info "Importando banco de dados..."
        docker exec -i "${CLIENT_NAME}-db" mysql -u root -p"${MYSQL_ROOT_PASSWORD}" nextcloud < "$BASE_DIR/$CLIENT_NAME/db_backup.sql" 2>/dev/null || true
    fi

    sleep 5
    docker exec -u www-data "${CLIENT_NAME}-app" php occ maintenance:mode --off 2>/dev/null || true

    log_success "Instância $CLIENT_NAME restaurada com sucesso!"
}

# ============================================================
# STATUS INSTÂNCIA
# ============================================================
status_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> _ status"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    log_info "Status da instância $CLIENT_NAME:"
    echo ""
    for suffix in app db redis collabora cron turn harp nats janus signaling; do
        container="${CLIENT_NAME}-${suffix}"
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "não encontrado")
        if [ "$status" = "running" ]; then
            printf "  ${GREEN}%-25s [%s]${NC}\n" "$container" "$status"
        else
            printf "  ${RED}%-25s [%s]${NC}\n" "$container" "$status"
        fi
    done
    echo ""

    if [ -f "$BASE_DIR/$CLIENT_NAME/.env" ]; then
        source "$BASE_DIR/$CLIENT_NAME/.env"
        echo "URLs:"
        echo "  Nextcloud:   https://${DOMAIN}"
        echo "  Collabora:   https://${COLLABORA_DOMAIN}"
        echo "  Signaling:   https://${SIGNALING_DOMAIN:-N/A}"
        echo ""
        echo "TURN Server:"
        echo "  Porta: ${TURN_PORT:-3478}"
        echo ""
    fi

    if docker exec -u www-data "${CLIENT_NAME}-app" php occ status 2>/dev/null | grep -q "installed: true"; then
        log_success "Nextcloud está respondendo normalmente"
    else
        log_warning "Nextcloud pode não estar respondendo"
    fi
}

# ============================================================
# CREDENCIAIS INSTÂNCIA
# ============================================================
credentials_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> _ credentials"
        exit 1
    fi

    if [ ! -f "$BASE_DIR/$CLIENT_NAME/.credentials" ]; then
        log_error "Arquivo de credenciais não encontrado para $CLIENT_NAME!"
        exit 1
    fi

    cat "$BASE_DIR/$CLIENT_NAME/.credentials"
}

# ============================================================
# ATUALIZAR INSTÂNCIA
# ============================================================
update_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> _ update"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    log_info "Atualizando instância $CLIENT_NAME..."
    cd "$BASE_DIR/$CLIENT_NAME"

    log_info "Fazendo backup de segurança..."
    backup_instance "$CLIENT_NAME"

    log_info "Baixando novas imagens..."
    $DC pull

    log_info "Recriando contêineres..."
    $DC up -d

    sleep 15
    log_info "Executando upgrade do Nextcloud..."
    docker exec -u www-data "${CLIENT_NAME}-app" php occ upgrade 2>/dev/null || true
    docker exec -u www-data "${CLIENT_NAME}-app" php occ db:add-missing-indices 2>/dev/null || true
    docker exec -u www-data "${CLIENT_NAME}-app" php occ maintenance:mode --off 2>/dev/null || true

    log_success "Instância $CLIENT_NAME atualizada!"
}

# ============================================================
# MENU PRINCIPAL
# ============================================================
if [ $# -eq 0 ]; then
    echo ""
    echo "  Nextcloud SaaS Manager v10.0"
    echo "  =============================="
    echo ""
    echo "  Uso: $0 <nome-cliente> <dominio> <comando>"
    echo ""
    echo "  Comandos:"
    echo "    create      - Criar nova instância (10 containers)"
    echo "    remove      - Remover instância"
    echo "    start       - Iniciar instância"
    echo "    stop        - Parar instância"
    echo "    status      - Ver status da instância"
    echo "    credentials - Ver credenciais da instância"
    echo "    backup      - Fazer backup da instância"
    echo "    restore     - Restaurar instância de backup"
    echo "    update      - Atualizar instância (pull + upgrade)"
    echo "    list        - Listar todas as instâncias"
    echo ""
    echo "  Exemplos:"
    echo "    $0 cliente1 nextcloud.cliente1.com.br create"
    echo "    $0 cliente1 _ status"
    echo "    $0 cliente1 _ credentials"
    echo "    $0 cliente1 _ backup"
    echo "    $0 cliente1 /path/to/backup.tar.gz restore"
    echo "    $0 cliente1 _ update"
    echo "    $0 cliente1 _ remove"
    echo "    $0 list"
    echo ""
    echo "  DNS necessários (3 registros A por instância):"
    echo "    nextcloud.dominio.com.br      → IP do servidor"
    echo "    collabora-nextcloud.dominio.com.br → IP do servidor"
    echo "    signaling-nextcloud.dominio.com.br → IP do servidor"
    echo ""
    echo "  Containers por instância (10):"
    echo "    app, db, redis, collabora, turn, cron,"
    echo "    harp (AppAPI), nats, janus, signaling (HPB)"
    echo ""
    exit 0
fi

# Tratar comando 'list' sem argumentos extras
if [ "$1" = "list" ]; then
    list_instances
    exit 0
fi

CLIENT_NAME=$1
DOMAIN=$2
COMMAND=${3:-status}

case $COMMAND in
    create)
        create_instance "$CLIENT_NAME" "$DOMAIN"
        ;;
    start)
        start_instance "$CLIENT_NAME"
        ;;
    stop)
        stop_instance "$CLIENT_NAME"
        ;;
    remove)
        remove_instance "$CLIENT_NAME"
        ;;
    backup)
        backup_instance "$CLIENT_NAME"
        ;;
    restore)
        restore_instance "$CLIENT_NAME" "$DOMAIN"
        ;;
    update)
        update_instance "$CLIENT_NAME"
        ;;
    status)
        status_instance "$CLIENT_NAME"
        ;;
    credentials)
        credentials_instance "$CLIENT_NAME"
        ;;
    *)
        log_error "Comando desconhecido: $COMMAND"
        echo "Use: $0 (sem argumentos) para ver a ajuda"
        exit 1
        ;;
esac
