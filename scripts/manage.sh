#!/bin/bash
# ============================================================
# Nextcloud SaaS Manager v11.0
# Script para gerenciar instâncias Nextcloud com serviços compartilhados
# Autor: Defensys
# ============================================================
# Arquitetura v11.0 (Compartilhada):
#   - 8 containers globais (db, redis, collabora, turn, nats, janus, signaling, recording)
#   - 3 containers por cliente (app, cron, harp)
#   - 1 registro DNS por cliente (apenas o domínio do Nextcloud)
#   - Domínios fixos: collabora-01.defensys.seg.br, signaling-01.defensys.seg.br
# ============================================================

set -uo pipefail

# ============================================================
# CONFIGURAÇÃO GLOBAL
# ============================================================
BASE_DIR="/opt/nextcloud-customers"
SHARED_DIR="/opt/shared-services"
SERVER_IP="200.50.151.21"
COLLABORA_DOMAIN="collabora-01.defensys.seg.br"
SIGNALING_DOMAIN="signaling-01.defensys.seg.br"
DC="docker-compose"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# FUNÇÕES AUXILIARES
# ============================================================
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

generate_password() { openssl rand -hex 16; }

run_occ() {
    local container="$1"
    shift
    docker exec -u www-data "$container" php occ "$@"
}

wait_for_nextcloud() {
    local container="$1"
    local timeout="${2:-180}"
    log_info "Aguardando Nextcloud inicializar (timeout: ${timeout}s)..."
    for i in $(seq 1 "$timeout"); do
        if docker exec -u www-data "$container" php occ status 2>/dev/null | grep -q "installed: true"; then
            log_success "Nextcloud pronto! (${i}s)"
            return 0
        fi
        sleep 1
    done
    log_error "Timeout aguardando Nextcloud!"
    return 1
}

get_next_redis_db() {
    # Encontrar o próximo dbindex disponível (0 é reservado)
    local max_db=0
    local env_files
    env_files=$(find "$BASE_DIR" -maxdepth 2 -name ".env" 2>/dev/null)
    for env_file in $env_files; do
        if [ -f "$env_file" ]; then
            local db_idx
            db_idx=$(grep "^REDIS_DB=" "$env_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$db_idx" ] && [ "$db_idx" -gt "$max_db" ]; then
                max_db=$db_idx
            fi
        fi
    done
    echo $((max_db + 1))
}

# ============================================================
# CARREGAR CONFIGURAÇÃO DOS SERVIÇOS COMPARTILHADOS
# ============================================================
load_shared_config() {
    if [ ! -f "$SHARED_DIR/.env" ]; then
        log_error "Serviços compartilhados não configurados!"
        log_error "Execute: sudo setup-shared.sh"
        exit 1
    fi
    source "$SHARED_DIR/.env"
}

# ============================================================
# ATUALIZAR COLLABORA ALLOWLIST
# ============================================================
update_collabora_allowlist() {
    log_info "Atualizando Collabora allowlist..."
    local domains=""
    for env_file in "$BASE_DIR"/*/.env; do
        if [ -f "$env_file" ]; then
            local domain=$(grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$domain" ]; then
                if [ -n "$domains" ]; then
                    domains="${domains}|https://${domain}"
                else
                    domains="https://${domain}"
                fi
            fi
        fi
    done

    if [ -n "$domains" ]; then
        # Atualizar .env dos shared-services
        sed -i "s|^COLLABORA_ALLOWLIST=.*|COLLABORA_ALLOWLIST=${domains}|" "$SHARED_DIR/.env"
        # Reiniciar Collabora para aplicar
        cd "$SHARED_DIR"
        $DC up -d collabora
        log_success "Collabora allowlist atualizado: $domains"
    fi
}

# ============================================================
# ATUALIZAR SIGNALING BACKENDS
# ============================================================
update_signaling_backends() {
    log_info "Atualizando Signaling backends..."
    source "$SHARED_DIR/.env"

    local backend_list=""
    local backend_sections=""
    local count=0

    for env_file in "$BASE_DIR"/*/.env; do
        if [ -f "$env_file" ]; then
            local domain=$(grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$domain" ]; then
                count=$((count + 1))
                local backend_name="backend${count}"
                if [ -n "$backend_list" ]; then
                    backend_list="${backend_list}, ${backend_name}"
                else
                    backend_list="${backend_name}"
                fi
                backend_sections="${backend_sections}
[${backend_name}]
url = https://${domain}
secret = ${SIGNALING_SECRET}
"
            fi
        fi
    done

    # Reescrever signaling.conf
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
backends = ${backend_list}
allowall = false
secret = ${SIGNALING_SECRET}
${backend_sections}
[turn]
apikey = static
secret = ${TURN_SECRET}
servers = turn:${SERVER_IP}:3478?transport=udp,turn:${SERVER_IP}:3478?transport=tcp
EOF

    # Reiniciar signaling
    cd "$SHARED_DIR"
    $DC restart signaling
    log_success "Signaling backends atualizado (${count} backends)"
}

update_recording_backends() {
    log_info "Atualizando Recording Server backends..."
    source "$SHARED_DIR/.env"

    local backend_list=""
    local backend_sections=""
    local count=0

    for env_file in "$BASE_DIR"/*/.env; do
        if [ -f "$env_file" ]; then
            local domain=$(grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$domain" ]; then
                count=$((count + 1))
                local bname="backend-${count}"
                if [ -n "$backend_list" ]; then
                    backend_list="${backend_list}, ${bname}"
                else
                    backend_list="${bname}"
                fi
                backend_sections="${backend_sections}
[${bname}]
url = https://${domain}
secret = ${RECORDING_SECRET}
skipverify = false
"
            fi
        fi
    done

    # Reescrever recording/recording.conf (formato imagem oficial)
    cat > "$SHARED_DIR/recording/recording.conf" << EOF
[logs]
level = 30

[http]
listen = 0.0.0.0:1234

[backend]
allowall = false
secret = ${RECORDING_SECRET}
backends = ${backend_list}
skipverify = false
maxmessagesize = 1024
videowidth = 1920
videoheight = 1080
directory = /tmp
${backend_sections}
[signaling]
signalings = signaling-1

[signaling-1]
url = ws://shared-signaling:8080
internalsecret = ${SIGNALING_INTERNAL_SECRET}

[ffmpeg]
extensionaudio = .ogg
extensionvideo = .webm

[recording]
browser = firefox
driverPath = /usr/bin/geckodriver
browserPath = /usr/bin/firefox
EOF

    # Reiniciar recording
    cd "$SHARED_DIR"
    $DC restart recording 2>/dev/null || true
    log_success "Recording backends atualizado (${count} backends)"
}

# ============================================================
# COMANDO: CREATE
# ============================================================
cmd_create() {
    local CLIENT_NAME="$1"
    local DOMAIN="$2"

    log_info "============================================"
    log_info "Criando instância: $CLIENT_NAME"
    log_info "Domínio: $DOMAIN"
    log_info "============================================"

    # Verificações
    if [ -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância '$CLIENT_NAME' já existe!"
        exit 1
    fi

    load_shared_config

    # Verificar DNS
    log_info "Verificando DNS..."
    local resolved_ip=$(dig +short "$DOMAIN" 2>/dev/null | tail -1)
    if [ "$resolved_ip" != "$SERVER_IP" ]; then
        log_warning "DNS de $DOMAIN resolve para '$resolved_ip' (esperado: $SERVER_IP)"
        log_warning "Continuando mesmo assim... Certifique-se de que o DNS esteja correto."
    else
        log_success "DNS OK: $DOMAIN → $SERVER_IP"
    fi

    # Gerar credenciais do cliente
    local NEXTCLOUD_ADMIN_PASSWORD=$(generate_password)
    local MYSQL_PASSWORD=$(generate_password)
    local MYSQL_DATABASE="nextcloud_${CLIENT_NAME//-/_}"
    local MYSQL_USER="nc_${CLIENT_NAME//-/_}"
    local REDIS_DB=$(get_next_redis_db)

    # Criar estrutura
    log_info "Criando diretórios..."
    mkdir -p "$BASE_DIR/$CLIENT_NAME/app"

    # Criar database no MariaDB compartilhado
    log_info "Criando database no MariaDB compartilhado..."
    docker exec shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" -e "
        CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
        CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
        GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
        FLUSH PRIVILEGES;
    "
    log_success "Database '${MYSQL_DATABASE}' criado"

    # Criar .env do cliente
    cat > "$BASE_DIR/$CLIENT_NAME/.env" << EOF
# Instância: ${CLIENT_NAME}
# Criado em: $(date '+%Y-%m-%d %H:%M:%S')
CLIENT_NAME=${CLIENT_NAME}
DOMAIN=${DOMAIN}
NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
REDIS_DB=${REDIS_DB}
EOF
    chmod 600 "$BASE_DIR/$CLIENT_NAME/.env"

    # Criar docker-compose.yml (apenas app + cron)
    local BT='`'
    cat > "$BASE_DIR/$CLIENT_NAME/docker-compose.yml" << EOF
name: '${CLIENT_NAME}'
services:
  app:
    image: nextcloud:latest
    container_name: ${CLIENT_NAME}-app
    restart: always
    environment:
      - MYSQL_HOST=shared-db
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - NEXTCLOUD_ADMIN_USER=admin
      - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=${DOMAIN}
      - REDIS_HOST=shared-redis
      - REDIS_HOST_PASSWORD=${REDIS_PASSWORD}
      - REDIS_HOST_PORT=6379
      - OVERWRITEPROTOCOL=https
      - OVERWRITECLIURL=https://${DOMAIN}
      - TRUSTED_PROXIES=172.16.0.0/12 192.168.0.0/16 10.0.0.0/8
    volumes:
      - ./app:/var/www/html
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${CLIENT_NAME}-app.rule=Host(${BT}${DOMAIN}${BT})"
      - "traefik.http.routers.${CLIENT_NAME}-app.entrypoints=websecure"
      - "traefik.http.routers.${CLIENT_NAME}-app.tls=true"
      - "traefik.http.routers.${CLIENT_NAME}-app.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${CLIENT_NAME}-app.middlewares=${CLIENT_NAME}-headers"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.stsSeconds=31536000"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.stsIncludeSubdomains=true"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.stsPreload=true"
      - "traefik.http.middlewares.${CLIENT_NAME}-headers.headers.customFrameOptionsValue=SAMEORIGIN"
      - "traefik.http.services.${CLIENT_NAME}-app.loadbalancer.server.port=80"
      - "traefik.docker.network=proxy"
    networks:
      - shared
      - proxy
    depends_on: []

  cron:
    image: nextcloud:latest
    container_name: ${CLIENT_NAME}-cron
    restart: always
    entrypoint: /cron.sh
    volumes:
      - ./app:/var/www/html
    networks:
      - shared

  harp:
    image: ghcr.io/nextcloud/nextcloud-appapi-harp:release
    container_name: ${CLIENT_NAME}-harp
    restart: always
    environment:
      - HP_SHARED_KEY=${HARP_SHARED_KEY}
      - NC_INSTANCE_URL=https://${DOMAIN}
    volumes:
      - ./harp-certs:/certs
    networks:
      - shared

networks:
  shared:
    external: true
  proxy:
    external: true
EOF

    # Criar diretório harp-certs
    mkdir -p "$BASE_DIR/$CLIENT_NAME/harp-certs"

    # Criar arquivo de credenciais legível
    cat > "$BASE_DIR/$CLIENT_NAME/.credentials" << EOF
=== Credenciais da Instância: ${CLIENT_NAME} ===
Data de criação: $(date '+%Y-%m-%d %H:%M:%S')

Nextcloud:
  URL: https://${DOMAIN}
  Usuário: admin
  Senha: ${NEXTCLOUD_ADMIN_PASSWORD}

Collabora Online (compartilhado):
  URL: https://${COLLABORA_DOMAIN}

Banco de Dados (MariaDB compartilhado):
  Host: shared-db
  Database: ${MYSQL_DATABASE}
  Usuário: ${MYSQL_USER}
  Senha: ${MYSQL_PASSWORD}

Redis (compartilhado):
  Host: shared-redis
  DB Index: ${REDIS_DB}

TURN Server (compartilhado):
  Endereço: turn:${SERVER_IP}:3478
  Secret: ${TURN_SECRET}

Signaling Server (compartilhado):
  URL: https://${SIGNALING_DOMAIN}
  Secret: ${SIGNALING_SECRET}

DNS necessário:
  ${DOMAIN} → ${SERVER_IP}
EOF

    # ============================================================
    # INICIAR CONTÊINERES
    # ============================================================
    log_info "Iniciando contêineres (app + cron)..."
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC up -d 2>&1

    # Aguardar Nextcloud ficar instalado
    wait_for_nextcloud "${CLIENT_NAME}-app" 180

    # ============================================================
    # PÓS-INSTALAÇÃO
    # ============================================================
    local APP="${CLIENT_NAME}-app"
    log_info "============================================"
    log_info "Iniciando pós-instalação..."
    log_info "============================================"

    # Verificar conectividade à internet (necessário para baixar apps)
    log_info "Verificando conectividade à internet..."
    local retries=0
    while ! docker exec "$APP" bash -c "curl -sf --max-time 5 https://apps.nextcloud.com > /dev/null 2>&1" && [ $retries -lt 30 ]; do
        retries=$((retries + 1))
        log_warning "Sem conectividade... tentativa $retries/30"
        sleep 5
    done
    if [ $retries -ge 30 ]; then
        log_error "Container sem acesso à internet! Verifique NAT/MASQUERADE."
        log_error "Execute: iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
        return 1
    fi
    log_success "Conectividade OK"

    # 1. Configurar Redis com dbindex separado
    log_info "[1/12] Configurando Redis..."
    run_occ "$APP" config:system:set redis host --value="shared-redis"
    run_occ "$APP" config:system:set redis port --value="6379" --type=integer
    run_occ "$APP" config:system:set redis password --value="${REDIS_PASSWORD}"
    run_occ "$APP" config:system:set redis dbindex --value="${REDIS_DB}" --type=integer
    run_occ "$APP" config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
    run_occ "$APP" config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis"
    run_occ "$APP" config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"
    log_success "Redis configurado (dbindex: ${REDIS_DB})"

    # 2. Configurar trusted_proxies
    log_info "[2/12] Configurando trusted_proxies..."
    run_occ "$APP" config:system:set trusted_proxies 0 --value="172.16.0.0/12"
    run_occ "$APP" config:system:set trusted_proxies 1 --value="192.168.0.0/16"
    run_occ "$APP" config:system:set trusted_proxies 2 --value="10.0.0.0/8"
    run_occ "$APP" config:system:set overwriteprotocol --value="https"
    run_occ "$APP" config:system:set overwrite.cli.url --value="https://${DOMAIN}"
    run_occ "$APP" config:system:set default_phone_region --value="BR"

    # 3. Instalar apps essenciais
    log_info "[3/12] Instalando aplicativos..."
    local APPS="richdocuments calendar contacts mail deck forms notes tasks groupfolders photos activity spreed app_api notify_push"
    for app in $APPS; do
        local install_attempts=0
        while ! run_occ "$APP" app:install "$app" 2>/dev/null && [ $install_attempts -lt 3 ]; do
            install_attempts=$((install_attempts + 1))
            log_warning "Retry instalação $app ($install_attempts/3)..."
            sleep 5
        done
        run_occ "$APP" app:enable "$app" 2>/dev/null || true
    done
    log_success "Aplicativos instalados"

    # 4. Configurar Collabora Online (compartilhado)
    log_info "[4/12] Configurando Collabora Online..."
    run_occ "$APP" config:app:set richdocuments wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments public_wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments wopi_allowlist --value="0.0.0.0/0"
    run_occ "$APP" config:app:set richdocuments disable_certificate_verification --value="no"
    run_occ "$APP" richdocuments:activate-config 2>/dev/null || true
    log_success "Collabora configurado → https://${COLLABORA_DOMAIN}"

    # 5. Configurar Talk com TURN/STUN (compartilhado)
    log_info "[5/12] Configurando Talk com TURN/STUN..."
    run_occ "$APP" config:app:set spreed turn_servers --value="[{\"server\":\"turn:${SERVER_IP}:3478\",\"secret\":\"${TURN_SECRET}\",\"protocols\":\"udp,tcp\"}]"
    run_occ "$APP" config:app:set spreed stun_servers --value="[\"${SERVER_IP}:3478\"]"
    log_success "Talk TURN/STUN configurado"

    # 6. Configurar Talk HPB (Signaling compartilhado)
    log_info "[6/13] Configurando Talk HPB (Signaling)..."
    run_occ "$APP" config:app:set spreed signaling_servers --value="{\"servers\":[{\"server\":\"https://${SIGNALING_DOMAIN}/\",\"verify\":true}],\"secret\":\"${SIGNALING_SECRET}\"}"
    log_success "Talk HPB configurado → https://${SIGNALING_DOMAIN}"

    # 7. Configurar Talk Recording Server (compartilhado)
    log_info "[7/13] Configurando Talk Recording Server..."
    run_occ "$APP" config:app:set spreed recording_servers --value="{\"secret\":\"${RECORDING_SECRET}\",\"servers\":[{\"server\":\"http://shared-recording:1234/\",\"verify\":false}]}"
    log_success "Talk Recording Server configurado"

    # 8. Configurar AppAPI com HaRP (por instância)
    log_info "[8/13] Configurando AppAPI com HaRP..."
    run_occ "$APP" app_api:daemon:register \
        harp_install "HaRP" docker-install http "${CLIENT_NAME}-harp:8780" \
        "https://${DOMAIN}" --net="shared" \
        --harp --harp_frp_address "${CLIENT_NAME}-harp:8782" \
        --harp_shared_key "${HARP_SHARED_KEY}" --set-default 2>/dev/null || true
    log_success "AppAPI + HaRP configurado"

    # 9. Configurar trusted domains
    log_info "[9/13] Configurando trusted domains..."
    run_occ "$APP" config:system:set trusted_domains 0 --value="${DOMAIN}"

    # 10. Configurar notify_push (Client Push)
    log_info "[10/13] Configurando Client Push..."
    run_occ "$APP" config:app:set notify_push base_endpoint --value="https://${DOMAIN}/push" 2>/dev/null || true

    # 11. Corrigir índices
    log_info "[11/13] Corrigindo índices do banco..."
    run_occ "$APP" db:add-missing-indices
    run_occ "$APP" db:add-missing-columns 2>/dev/null || true
    run_occ "$APP" db:add-missing-primary-keys 2>/dev/null || true

    # 12. Configurações finais
    log_info "[12/13] Configurações finais..."
    run_occ "$APP" background:cron
    run_occ "$APP" config:system:set htaccess.RewriteBase --value='/'
    run_occ "$APP" maintenance:update:htaccess 2>/dev/null || true
    docker exec "$APP" bash -c 'truncate -s 0 /var/www/html/data/nextcloud.log' 2>/dev/null || true
    run_occ "$APP" log:manage --level=warning

    # 13. Reparo final
    log_info "[13/13] Reparo final..."
    run_occ "$APP" maintenance:repair 2>/dev/null || true

    # ============================================================
    # ATUALIZAR SERVIÇOS COMPARTILHADOS
    # ============================================================
    log_info "Atualizando serviços compartilhados..."
    update_collabora_allowlist
    update_signaling_backends
    update_recording_backends

    # ============================================================
    # VERIFICAÇÃO FINAL
    # ============================================================
    log_info "============================================"
    log_info "Verificação final..."
    log_info "============================================"

    if docker exec -u www-data "$APP" php occ status 2>/dev/null | grep -q "installed: true"; then
        log_success "Nextcloud: OK"
    else
        log_error "Nextcloud: FALHA"
    fi

    echo ""
    log_success "============================================"
    log_success "Instância '$CLIENT_NAME' criada com sucesso!"
    log_success "============================================"
    echo ""
    echo "  URL:      https://${DOMAIN}"
    echo "  Usuário:  admin"
    echo "  Senha:    ${NEXTCLOUD_ADMIN_PASSWORD}"
    echo ""
    echo "  Collabora:  https://${COLLABORA_DOMAIN} (compartilhado)"
    echo "  Signaling:  https://${SIGNALING_DOMAIN} (compartilhado)"
    echo "  TURN:       turn:${SERVER_IP}:3478 (compartilhado)"
    echo ""
    echo "  Credenciais salvas em: $BASE_DIR/$CLIENT_NAME/.credentials"
    echo ""
}

# ============================================================
# COMANDO: STATUS
# ============================================================
cmd_status() {
    local CLIENT_NAME="$1"

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância '$CLIENT_NAME' não encontrada!"
        exit 1
    fi

    source "$BASE_DIR/$CLIENT_NAME/.env"
    echo ""
    echo "=== Status da Instância: $CLIENT_NAME ==="
    echo "  Domínio: $DOMAIN"
    echo ""

    echo "--- Containers do Cliente ---"
    for container in "${CLIENT_NAME}-app" "${CLIENT_NAME}-cron"; do
        local status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        if [ "$status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} $container: $status"
        else
            echo -e "  ${RED}●${NC} $container: $status"
        fi
    done

    echo ""
    echo "--- Serviços Compartilhados ---"
    for container in shared-db shared-redis shared-collabora shared-turn shared-nats shared-janus shared-signaling shared-harp; do
        local status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        if [ "$status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} $container: $status"
        else
            echo -e "  ${RED}●${NC} $container: $status"
        fi
    done
    echo ""
}

# ============================================================
# COMANDO: CREDENTIALS
# ============================================================
cmd_credentials() {
    local CLIENT_NAME="$1"

    if [ ! -f "$BASE_DIR/$CLIENT_NAME/.credentials" ]; then
        log_error "Arquivo de credenciais não encontrado!"
        exit 1
    fi

    cat "$BASE_DIR/$CLIENT_NAME/.credentials"
}

# ============================================================
# COMANDO: BACKUP
# ============================================================
cmd_backup() {
    local CLIENT_NAME="$1"

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância '$CLIENT_NAME' não encontrada!"
        exit 1
    fi

    source "$BASE_DIR/$CLIENT_NAME/.env"
    load_shared_config

    local BACKUP_DIR="$BASE_DIR/backups"
    local TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    local BACKUP_FILE="$BACKUP_DIR/${CLIENT_NAME}_${TIMESTAMP}.tar.gz"
    mkdir -p "$BACKUP_DIR"

    log_info "Iniciando backup de '$CLIENT_NAME'..."

    # Dump do banco de dados
    log_info "Exportando banco de dados..."
    docker exec shared-db mariadb-dump -uroot -p"${DB_ROOT_PASSWORD}" "${MYSQL_DATABASE}" > "$BASE_DIR/$CLIENT_NAME/database.sql"
    log_success "Database exportado"

    # Compactar tudo
    log_info "Compactando..."
    cd "$BASE_DIR"
    tar -czf "$BACKUP_FILE" "$CLIENT_NAME/"
    rm -f "$BASE_DIR/$CLIENT_NAME/database.sql"

    local SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log_success "Backup concluído: $BACKUP_FILE ($SIZE)"
}

# ============================================================
# COMANDO: RESTORE
# ============================================================
cmd_restore() {
    local CLIENT_NAME="$1"
    local BACKUP_FILE="$2"

    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Arquivo de backup não encontrado: $BACKUP_FILE"
        exit 1
    fi

    load_shared_config

    log_info "Restaurando '$CLIENT_NAME' de $BACKUP_FILE..."

    # Extrair backup
    cd "$BASE_DIR"
    tar -xzf "$BACKUP_FILE"

    # Carregar variáveis do cliente
    source "$BASE_DIR/$CLIENT_NAME/.env"

    # Recriar database
    log_info "Restaurando banco de dados..."
    docker exec shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" -e "
        DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`;
        CREATE DATABASE \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
        CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
        GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
        FLUSH PRIVILEGES;
    "

    if [ -f "$BASE_DIR/$CLIENT_NAME/database.sql" ]; then
        docker exec -i shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < "$BASE_DIR/$CLIENT_NAME/database.sql"
        rm -f "$BASE_DIR/$CLIENT_NAME/database.sql"
        log_success "Database restaurado"
    fi

    # Subir containers
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC up -d

    # Atualizar serviços compartilhados
    update_collabora_allowlist
    update_signaling_backends
    update_recording_backends

    log_success "Instância '$CLIENT_NAME' restaurada com sucesso!"
}

# ============================================================
# COMANDO: STOP
# ============================================================
cmd_stop() {
    local CLIENT_NAME="$1"
    log_info "Parando instância '$CLIENT_NAME'..."
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC stop
    log_success "Instância parada"
}

# ============================================================
# COMANDO: START
# ============================================================
cmd_start() {
    local CLIENT_NAME="$1"
    log_info "Iniciando instância '$CLIENT_NAME'..."
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC up -d
    log_success "Instância iniciada"
}

# ============================================================
# COMANDO: UPDATE
# ============================================================
cmd_update() {
    local CLIENT_NAME="$1"
    log_info "Atualizando instância '$CLIENT_NAME'..."

    # Backup primeiro
    cmd_backup "$CLIENT_NAME"

    cd "$BASE_DIR/$CLIENT_NAME"
    $DC pull
    $DC up -d

    # Aguardar e executar upgrade
    sleep 10
    local APP="${CLIENT_NAME}-app"
    run_occ "$APP" upgrade 2>/dev/null || true
    run_occ "$APP" db:add-missing-indices 2>/dev/null || true
    run_occ "$APP" db:add-missing-columns 2>/dev/null || true
    run_occ "$APP" maintenance:mode --off 2>/dev/null || true

    log_success "Instância atualizada"
}

# ============================================================
# COMANDO: REMOVE
# ============================================================
cmd_remove() {
    local CLIENT_NAME="$1"

    if [ ! -d "$BASE_DIR/$CLIENT_NAME" ]; then
        log_error "Instância '$CLIENT_NAME' não encontrada!"
        exit 1
    fi

    source "$BASE_DIR/$CLIENT_NAME/.env"
    load_shared_config

    echo ""
    log_warning "ATENÇÃO: Isso vai REMOVER PERMANENTEMENTE a instância '$CLIENT_NAME'!"
    log_warning "Domínio: $DOMAIN"
    log_warning "Database: $MYSQL_DATABASE"
    echo ""
    read -p "Digite 'CONFIRMAR' para prosseguir: " confirm
    if [ "$confirm" != "CONFIRMAR" ]; then
        log_info "Operação cancelada."
        exit 0
    fi

    # Parar e remover containers
    log_info "Removendo containers..."
    cd "$BASE_DIR/$CLIENT_NAME"
    $DC down -v 2>/dev/null || true

    # Remover database
    log_info "Removendo database..."
    docker exec shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" -e "
        DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`;
        DROP USER IF EXISTS '${MYSQL_USER}'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null || true

    # Remover diretório
    log_info "Removendo arquivos..."
    rm -rf "$BASE_DIR/$CLIENT_NAME"

    # Atualizar serviços compartilhados
    update_collabora_allowlist
    update_signaling_backends
    update_recording_backends

    log_success "Instância '$CLIENT_NAME' removida completamente!"
}

# ============================================================
# COMANDO: LIST
# ============================================================
cmd_list() {
    echo ""
    echo "=== Instâncias Nextcloud ==="
    echo ""
    printf "%-20s %-35s %-10s\n" "NOME" "DOMÍNIO" "STATUS"
    printf "%-20s %-35s %-10s\n" "----" "-------" "------"

    for dir in "$BASE_DIR"/*/; do
        if [ -f "$dir/.env" ] && [ -f "$dir/docker-compose.yml" ]; then
            local name=$(basename "$dir")
            local domain=$(grep "^DOMAIN=" "$dir/.env" 2>/dev/null | cut -d= -f2)
            local container="${name}-app"
            local status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "stopped")
            printf "%-20s %-35s %-10s\n" "$name" "$domain" "$status"
        fi
    done
    echo ""

    # Mostrar serviços compartilhados
    echo "=== Serviços Compartilhados ==="
    echo ""
    for container in shared-db shared-redis shared-collabora shared-turn shared-nats shared-janus shared-signaling shared-harp; do
        local status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        if [ "$status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} $container"
        else
            echo -e "  ${RED}●${NC} $container ($status)"
        fi
    done
    echo ""
}

# ============================================================
# COMANDO: SHARED-STATUS
# ============================================================
cmd_shared_status() {
    echo ""
    echo "=== Serviços Compartilhados ==="
    echo ""
    for container in shared-db shared-redis shared-collabora shared-turn shared-nats shared-janus shared-signaling shared-harp; do
        local status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        local uptime=$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null | cut -dT -f1)
        if [ "$status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} $container (since $uptime)"
        else
            echo -e "  ${RED}●${NC} $container: $status"
        fi
    done
    echo ""
    echo "  Collabora:  https://${COLLABORA_DOMAIN}"
    echo "  Signaling:  https://${SIGNALING_DOMAIN}"
    echo "  TURN:       turn:${SERVER_IP}:3478"
    echo ""
}

# ============================================================
# MAIN — PARSE DE ARGUMENTOS
# ============================================================
usage() {
    echo ""
    echo "Nextcloud SaaS Manager v11.0 (Arquitetura Compartilhada)"
    echo ""
    echo "Uso:"
    echo "  $(basename "$0") <cliente> <domínio> create     Criar nova instância"
    echo "  $(basename "$0") <cliente> _ status             Status da instância"
    echo "  $(basename "$0") <cliente> _ credentials        Exibir credenciais"
    echo "  $(basename "$0") <cliente> _ backup             Backup completo"
    echo "  $(basename "$0") <cliente> <backup.tar.gz> restore  Restaurar instância"
    echo "  $(basename "$0") <cliente> _ stop               Parar instância"
    echo "  $(basename "$0") <cliente> _ start              Iniciar instância"
    echo "  $(basename "$0") <cliente> _ update             Atualizar instância"
    echo "  $(basename "$0") <cliente> _ remove             Remover instância"
    echo "  $(basename "$0") list                           Listar todas as instâncias"
    echo "  $(basename "$0") shared-status                  Status dos serviços compartilhados"
    echo ""
}

# Verificar root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Execute como root: sudo $0 $*"
    exit 1
fi

# Parse de argumentos
case "${1:-}" in
    list)
        cmd_list
        ;;
    shared-status)
        cmd_shared_status
        ;;
    ""|help|-h|--help)
        usage
        ;;
    *)
        CLIENT_NAME="$1"
        DOMAIN_OR_PLACEHOLDER="${2:-_}"
        COMMAND="${3:-}"

        case "$COMMAND" in
            create)
                if [ "$DOMAIN_OR_PLACEHOLDER" = "_" ]; then
                    log_error "Domínio obrigatório para 'create'. Uso: $0 <cliente> <domínio> create"
                    exit 1
                fi
                cmd_create "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER"
                ;;
            status)
                cmd_status "$CLIENT_NAME"
                ;;
            credentials)
                cmd_credentials "$CLIENT_NAME"
                ;;
            backup)
                cmd_backup "$CLIENT_NAME"
                ;;
            restore)
                cmd_restore "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER"
                ;;
            stop)
                cmd_stop "$CLIENT_NAME"
                ;;
            start)
                cmd_start "$CLIENT_NAME"
                ;;
            update)
                cmd_update "$CLIENT_NAME"
                ;;
            remove)
                cmd_remove "$CLIENT_NAME"
                ;;
            *)
                log_error "Comando desconhecido: '$COMMAND'"
                usage
                exit 1
                ;;
        esac
        ;;
esac
