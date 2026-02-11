#!/bin/bash
# ============================================================
# Nextcloud SaaS Manager v9.0
# Script para gerenciar instâncias Nextcloud com Collabora Online
# Autor: Defensys
# Data: 2026-02-10
# ============================================================
# Changelog v9.0:
#   - Docker Socket Proxy para AppAPI
#   - Registro automático do daemon AppAPI via DSP
#   - Middleware .well-known para CalDAV/CardDAV
#   - Instalação automática do notify_push (Client Push)
#   - Configuração do public_wopi_url para Collabora
#   - Portas TURN dinâmicas (evitar conflito entre instâncias)
#   - Melhorias no status, remoção e backup
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
SERVER_IP="200.50.151.10"

# Função para exibir mensagens
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[AVISO]${NC} $1"; }

# Função para gerar senha aleatória
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
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
            # Aguardar mais 10s para autoconfig terminar
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

    # Verificar se a instância já existe
    if [ -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME já existe!"
        exit 1
    fi

    log_info "============================================"
    log_info "Criando nova instância: $CLIENT_NAME"
    log_info "Domínio: $DOMAIN"
    log_info "============================================"

    # Gerar senhas
    MYSQL_ROOT_PASSWORD=$(generate_password)
    MYSQL_PASSWORD=$(generate_password)
    NEXTCLOUD_ADMIN_PASSWORD=$(generate_password)
    COLLABORA_ADMIN_PASSWORD=$(generate_password)
    TURN_SECRET=$(generate_password)

    # Derivar domínio do collabora
    COLLABORA_DOMAIN="collabora-${DOMAIN}"

    # Encontrar porta TURN disponível
    TURN_PORT=$(find_available_turn_port)
    log_info "Porta TURN: $TURN_PORT"

    log_info "Criando diretórios..."
    mkdir -p "$BASE_DIR/$CLIENT_NAME"

    # Criar arquivo .env
    log_info "Criando arquivo .env..."
    cat > "$BASE_DIR/$CLIENT_NAME/.env" << EOF
CLIENT_NAME=${CLIENT_NAME}
DOMAIN=${DOMAIN}
COLLABORA_DOMAIN=${COLLABORA_DOMAIN}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
COLLABORA_ADMIN_PASSWORD=${COLLABORA_ADMIN_PASSWORD}
TURN_SECRET=${TURN_SECRET}
TURN_PORT=${TURN_PORT}
EOF

    # ============================================================
    # CRIAR DOCKER-COMPOSE.YML
    # ============================================================
    log_info "Criando docker-compose.yml..."

    # Usar variável para backtick
    BT='`'

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
      - "traefik.http.routers.${CLIENT_NAME}-app.rule=Host(${BT}${DOMAIN}${BT})"
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
      - "traefik.http.routers.${CLIENT_NAME}-collabora.rule=Host(${BT}${COLLABORA_DOMAIN}${BT})"
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
      - "${TURN_PORT}:3478"
      - "${TURN_PORT}:3478/udp"
    command: >
      -n
      --log-file=stdout
      --listening-port=3478
      --external-ip=${SERVER_IP}
      --fingerprint
      --use-auth-secret
      --static-auth-secret=\${TURN_SECRET}
      --realm=${DOMAIN}
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

  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: ${CLIENT_NAME}-dsp
    restart: always
    privileged: true
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - AUTH=1
      - POST=1
      - NETWORKS=1
      - VOLUMES=1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - default

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
EOF

    # Salvar log da instalação
    local LOG_FILE="$BASE_DIR/$CLIENT_NAME/install.log"

    # ============================================================
    # INICIAR CONTÊINERES
    # ============================================================
    log_info "Iniciando contêineres..."
    cd "$BASE_DIR/$CLIENT_NAME"
    docker compose up -d 2>&1 | tee -a "$LOG_FILE"

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
    log_info "[1/14] Configurando background jobs..."
    run_occ "$APP" background:cron

    # 2. Configurar Redis
    log_info "[2/14] Configurando Redis..."
    run_occ "$APP" config:system:set memcache.local --value='\OC\Memcache\APCu'
    run_occ "$APP" config:system:set memcache.distributed --value='\OC\Memcache\Redis'
    run_occ "$APP" config:system:set memcache.locking --value='\OC\Memcache\Redis'
    run_occ "$APP" config:system:set redis host --value='redis' --type=string
    run_occ "$APP" config:system:set redis port --value=6379 --type=integer

    # 3. Configurar trusted_proxies e overwrite
    log_info "[3/14] Configurando trusted_proxies e overwrite..."
    run_occ "$APP" config:system:set trusted_proxies 0 --value='172.16.0.0/12'
    run_occ "$APP" config:system:set trusted_proxies 1 --value='192.168.0.0/16'
    run_occ "$APP" config:system:set trusted_proxies 2 --value='10.0.0.0/8'
    run_occ "$APP" config:system:set overwriteprotocol --value='https'
    run_occ "$APP" config:system:set overwrite.cli.url --value="https://${DOMAIN}"
    run_occ "$APP" config:system:set default_phone_region --value='BR'
    run_occ "$APP" config:system:set maintenance_window_start --value=1 --type=integer
    run_occ "$APP" config:system:set allow_local_remote_servers --value=true --type=boolean

    # 4. Corrigir índices do banco de dados
    log_info "[4/14] Corrigindo índices do banco de dados..."
    run_occ "$APP" db:add-missing-indices
    run_occ "$APP" db:add-missing-columns || true
    run_occ "$APP" db:add-missing-primary-keys || true

    # 5. Executar reparos e migração de mimetypes
    log_info "[5/14] Executando reparos e migração de mimetypes..."
    run_occ "$APP" maintenance:repair --include-expensive
    run_occ "$APP" maintenance:mimetype:update-db

    # 6. Instalar aplicativos essenciais
    log_info "[6/14] Instalando aplicativos essenciais..."
    for app in richdocuments calendar contacts deck forms groupfolders mail notes tasks photos activity spreed notify_push; do
        log_info "  -> $app"
        run_occ "$APP" app:install "$app" 2>/dev/null || run_occ "$APP" app:enable "$app" 2>/dev/null || true
    done

    # 7. Aguardar Collabora ficar pronto e configurar
    log_info "[7/14] Configurando Collabora Online..."
    log_info "  Aguardando Collabora ficar pronto..."
    wait_for_container "${CLIENT_NAME}-collabora" "curl -sSf http://localhost:9980/" 60

    run_occ "$APP" config:app:set richdocuments wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments public_wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments wopi_allowlist --value="0.0.0.0/0"
    run_occ "$APP" config:app:set richdocuments disable_certificate_verification --value="yes"
    # Forçar refresh das capabilities do Collabora
    run_occ "$APP" richdocuments:activate-config 2>/dev/null || true
    # Atualizar capabilities cache
    run_occ "$APP" maintenance:repair 2>/dev/null || true

    # 8. Configurar Talk com TURN/STUN server
    log_info "[8/14] Configurando Talk com TURN/STUN server..."
    run_occ "$APP" config:app:set spreed turn_servers --value="[{\"server\":\"turn:${SERVER_IP}:${TURN_PORT}\",\"secret\":\"${TURN_SECRET}\",\"protocols\":\"udp,tcp\"}]"
    run_occ "$APP" config:app:set spreed stun_servers --value="[{\"server\":\"stun:${SERVER_IP}:${TURN_PORT}\"}]"

    # 9. Instalar e configurar AppAPI com Docker Socket Proxy
    log_info "[9/14] Configurando AppAPI com Docker Socket Proxy..."
    docker exec -u www-data "$APP" php occ app:install app_api 2>/dev/null || true
    docker exec -u www-data "$APP" php occ app:enable app_api 2>/dev/null || true

    # Aguardar Docker Socket Proxy ficar pronto
    log_info "  Aguardando Docker Socket Proxy..."
    wait_for_container "${CLIENT_NAME}-dsp" "ls /" 30

    # Registrar daemon com Docker Socket Proxy
    log_info "  Registrando daemon AppAPI..."
    docker exec -u www-data "$APP" php occ app_api:daemon:register \
        docker_install "Docker Socket Proxy" docker-install http "${CLIENT_NAME}-dsp:2375" \
        "https://${DOMAIN}" --net="${CLIENT_NAME}_default" --set-default 2>/dev/null || true
    log_success "  AppAPI configurado com Docker Socket Proxy"

    # 10. Configurar trusted domains extras
    log_info "[10/14] Configurando trusted domains..."
    run_occ "$APP" config:system:set trusted_domains 0 --value="${DOMAIN}"
    run_occ "$APP" config:system:set trusted_domains 1 --value="${COLLABORA_DOMAIN}"

    # 11. Configurar notify_push (Client Push)
    log_info "[11/14] Configurando Client Push (notify_push)..."
    run_occ "$APP" config:app:set notify_push base_endpoint --value="https://${DOMAIN}/push" 2>/dev/null || true
    log_success "  Client Push configurado"

    # 12. Corrigir índices novamente (após instalar apps)
    log_info "[12/14] Corrigindo índices pós-instalação de apps..."
    run_occ "$APP" db:add-missing-indices

    # 13. Limpar logs e definir nível
    log_info "[13/14] Limpando logs e finalizando..."
    docker exec "$APP" bash -c 'truncate -s 0 /var/www/html/data/nextcloud.log' 2>/dev/null || true
    run_occ "$APP" log:manage --level=warning

    # 14. Verificação final de segurança
    log_info "[14/14] Configurações finais de segurança..."
    run_occ "$APP" config:system:set htaccess.RewriteBase --value='/'
    run_occ "$APP" maintenance:update:htaccess 2>/dev/null || true

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

    # Verificar AppAPI
    if docker exec -u www-data "$APP" php occ app:list 2>/dev/null | grep -q "app_api"; then
        log_success "AppAPI: OK"
    else
        log_warning "AppAPI: pode não estar instalado"
    fi

    # Verificar AppAPI daemon
    if docker exec -u www-data "$APP" php occ app_api:daemon:list 2>/dev/null | grep -q "docker_install"; then
        log_success "AppAPI Daemon (DSP): OK"
    else
        log_warning "AppAPI Daemon: não registrado"
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

    # Verificar Docker Socket Proxy
    if docker exec "$APP" curl -s http://${CLIENT_NAME}-dsp:2375/version >/dev/null 2>&1; then
        log_success "Docker Socket Proxy: OK"
    else
        log_warning "Docker Socket Proxy: pode não estar acessível"
    fi

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
    echo "  Nextcloud:  https://${DOMAIN}"
    echo "  Collabora:  https://${COLLABORA_DOMAIN}"
    echo ""
    echo "Credenciais:"
    echo "  Usuário: admin"
    echo "  Senha:   ${NEXTCLOUD_ADMIN_PASSWORD}"
    echo ""
    echo "Arquivo de credenciais: $BASE_DIR/$CLIENT_NAME/.credentials"
    echo ""
    log_info "Aplicativos instalados:"
    echo "  - Nextcloud Office (Collabora Online)"
    echo "  - Calendar, Contacts, Mail"
    echo "  - Deck, Forms, Notes, Tasks"
    echo "  - Group Folders, Photos, Activity"
    echo "  - Talk (com TURN/STUN server na porta ${TURN_PORT})"
    echo "  - AppAPI (com Docker Socket Proxy)"
    echo "  - Client Push (notify_push)"
    echo ""
    log_info "Configurações aplicadas:"
    echo "  - Redis cache (local + distributed + locking)"
    echo "  - Background jobs via cron"
    echo "  - Trusted proxies configurados"
    echo "  - HTTPS forçado com HSTS"
    echo "  - Collabora Online configurado e conectado"
    echo "  - Talk com TURN/STUN server"
    echo "  - AppAPI com Docker Socket Proxy"
    echo "  - Client Push (notify_push)"
    echo "  - .well-known URLs (CalDAV/CardDAV)"
    echo "  - Índices do banco corrigidos"
    echo "  - Mimetypes atualizados"
    echo "  - Logs limpos"
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
        if [ "$instance" = "traefik" ]; then continue; fi
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
        log_error "Uso: $0 <nome-cliente> <dominio> remove"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    # Proteção contra remoção acidental de instâncias em produção
    if [ -f "$BASE_DIR/$CLIENT_NAME/.protected" ]; then
        log_error "Instância $CLIENT_NAME está protegida! Remova o arquivo .protected primeiro."
        exit 1
    fi

    log_warning "============================================"
    log_warning "Removendo instância: $CLIENT_NAME"
    log_warning "============================================"

    cd "$BASE_DIR/$CLIENT_NAME"

    # Parar e remover contêineres e volumes
    log_info "Parando e removendo contêineres..."
    docker compose down -v --remove-orphans 2>/dev/null || true

    # Remover contêineres órfãos manualmente
    for suffix in app db redis collabora cron turn dsp; do
        docker rm -f "${CLIENT_NAME}-${suffix}" 2>/dev/null || true
    done

    # Remover diretório
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
        log_error "Uso: $0 <nome-cliente> <dominio> stop"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    log_info "Parando instância $CLIENT_NAME..."
    cd "$BASE_DIR/$CLIENT_NAME"
    docker compose stop
    log_success "Instância $CLIENT_NAME parada!"
}

# ============================================================
# INICIAR INSTÂNCIA
# ============================================================
start_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> <dominio> start"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    log_info "Iniciando instância $CLIENT_NAME..."
    cd "$BASE_DIR/$CLIENT_NAME"
    docker compose up -d
    log_success "Instância $CLIENT_NAME iniciada!"
}

# ============================================================
# BACKUP INSTÂNCIA
# ============================================================
backup_instance() {
    local CLIENT_NAME=$1

    if [ -z "$CLIENT_NAME" ]; then
        log_error "Uso: $0 <nome-cliente> <dominio> backup"
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

    # Colocar em modo de manutenção
    cd "$BASE_DIR/$CLIENT_NAME"
    docker exec -u www-data "${CLIENT_NAME}-app" php occ maintenance:mode --on 2>/dev/null || true

    # Fazer backup do banco
    log_info "Exportando banco de dados..."
    source "$BASE_DIR/$CLIENT_NAME/.env"
    docker exec "${CLIENT_NAME}-db" mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" nextcloud > "$BASE_DIR/$CLIENT_NAME/db_backup.sql" 2>/dev/null || true

    # Parar contêineres
    docker compose stop

    # Criar arquivo tar
    log_info "Compactando..."
    tar -czf "$BACKUP_FILE" -C "$BASE_DIR" "$CLIENT_NAME"

    # Reiniciar
    docker compose up -d

    # Desativar modo de manutenção
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
        docker compose down -v --remove-orphans 2>/dev/null || true
        for suffix in app db redis collabora cron turn dsp; do
            docker rm -f "${CLIENT_NAME}-${suffix}" 2>/dev/null || true
        done
        rm -rf "$BASE_DIR/$CLIENT_NAME"
    fi

    log_info "Restaurando backup..."
    tar -xzf "$BACKUP_FILE" -C "$BASE_DIR"

    cd "$BASE_DIR/$CLIENT_NAME"
    docker compose up -d

    # Aguardar e importar banco
    sleep 15
    if [ -f "$BASE_DIR/$CLIENT_NAME/db_backup.sql" ]; then
        source "$BASE_DIR/$CLIENT_NAME/.env"
        log_info "Importando banco de dados..."
        docker exec -i "${CLIENT_NAME}-db" mysql -u root -p"${MYSQL_ROOT_PASSWORD}" nextcloud < "$BASE_DIR/$CLIENT_NAME/db_backup.sql" 2>/dev/null || true
    fi

    # Desativar modo de manutenção
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
        log_error "Uso: $0 <nome-cliente> <dominio> status"
        exit 1
    fi

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância $CLIENT_NAME não encontrada!"
        exit 1
    fi

    log_info "Status da instância $CLIENT_NAME:"
    echo ""
    for suffix in app db redis collabora cron turn dsp; do
        container="${CLIENT_NAME}-${suffix}"
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "não encontrado")
        if [ "$status" = "running" ]; then
            printf "  ${GREEN}%-25s [%s]${NC}\n" "$container" "$status"
        else
            printf "  ${RED}%-25s [%s]${NC}\n" "$container" "$status"
        fi
    done
    echo ""

    # Verificar URLs
    if [ -f "$BASE_DIR/$CLIENT_NAME/.env" ]; then
        source "$BASE_DIR/$CLIENT_NAME/.env"
        echo "URLs:"
        echo "  Nextcloud:  https://${DOMAIN}"
        echo "  Collabora:  https://${COLLABORA_DOMAIN}"
        echo ""
        echo "TURN Server:"
        echo "  Porta: ${TURN_PORT:-3478}"
        echo ""
    fi

    # Verificar se Nextcloud está respondendo
    if docker exec -u www-data "${CLIENT_NAME}-app" php occ status 2>/dev/null | grep -q "installed: true"; then
        log_success "Nextcloud está respondendo normalmente"
    else
        log_warning "Nextcloud pode não estar respondendo"
    fi
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

    # Fazer backup antes de atualizar
    log_info "Fazendo backup de segurança..."
    backup_instance "$CLIENT_NAME"

    # Puxar novas imagens
    log_info "Baixando novas imagens..."
    docker compose pull

    # Recriar contêineres
    log_info "Recriando contêineres..."
    docker compose up -d

    # Aguardar e executar upgrade
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
    echo "  Nextcloud SaaS Manager v9.0"
    echo "  =============================="
    echo ""
    echo "  Uso: $0 <nome-cliente> <dominio> <comando>"
    echo ""
    echo "  Comandos:"
    echo "    create   - Criar nova instância"
    echo "    remove   - Remover instância"
    echo "    start    - Iniciar instância"
    echo "    stop     - Parar instância"
    echo "    status   - Ver status da instância"
    echo "    backup   - Fazer backup da instância"
    echo "    restore  - Restaurar instância de backup"
    echo "    update   - Atualizar instância (pull + upgrade)"
    echo "    list     - Listar todas as instâncias"
    echo ""
    echo "  Exemplos:"
    echo "    $0 cliente1 nextcloud.cliente1.com.br create"
    echo "    $0 cliente1 _ remove"
    echo "    $0 cliente1 _ status"
    echo "    $0 cliente1 _ backup"
    echo "    $0 cliente1 /path/to/backup.tar.gz restore"
    echo "    $0 cliente1 _ update"
    echo "    $0 list"
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
    *)
        log_error "Comando desconhecido: $COMMAND"
        echo "Use: $0 (sem argumentos) para ver a ajuda"
        exit 1
        ;;
esac
