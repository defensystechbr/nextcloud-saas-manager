#!/bin/bash
# ============================================================
# Nextcloud SaaS Manager v12.0-dev
# Dispatcher fino — invoca lib/*.sh para lógica especializada.
# Compatibilidade legada: manage.sh <cliente> <dom|_> <cmd>
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# LIBS
# ============================================================
# shellcheck source=scripts/lib/validators.sh
source "${SCRIPT_DIR}/lib/validators.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${SCRIPT_DIR}/lib/output_json.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${SCRIPT_DIR}/lib/job_queue.sh"
# shellcheck source=scripts/lib/job_runner.sh
source "${SCRIPT_DIR}/lib/job_runner.sh"
# shellcheck source=scripts/lib/ssh_audit.sh
source "${SCRIPT_DIR}/lib/ssh_audit.sh"
# shellcheck source=scripts/lib/legacy_helpers.sh
source "${SCRIPT_DIR}/lib/legacy_helpers.sh"

# ============================================================
# CONFIGURAÇÃO GLOBAL
# ============================================================
BASE_DIR="${BASE_DIR:-/opt/nextcloud-customers}"
SHARED_DIR="${SHARED_DIR:-/opt/shared-services}"

SERVER_IP="200.50.151.21"
COLLABORA_DOMAIN="collabora-01.defensys.seg.br"
SIGNALING_DOMAIN="signaling-01.defensys.seg.br"
TURN_DOMAIN="turn-01.defensys.seg.br"

# Carregar valores reais do .env compartilhado
if [ -f "${SHARED_DIR}/.env" ]; then
    while IFS='=' read -r k v; do
        case "$k" in
            SERVER_IP)         [ -n "$v" ] && SERVER_IP="$v" ;;
            COLLABORA_DOMAIN)  [ -n "$v" ] && COLLABORA_DOMAIN="$v" ;;
            SIGNALING_DOMAIN)  [ -n "$v" ] && SIGNALING_DOMAIN="$v" ;;
            TURN_DOMAIN)       [ -n "$v" ] && TURN_DOMAIN="$v" ;;
        esac
    done < "${SHARED_DIR}/.env"
fi

# Auto-detectar Docker Compose
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo -e "\033[0;31m[ERROR]\033[0m Nem 'docker compose' (v2) nem 'docker-compose' (v1) encontrados." >&2
    exit 1
fi
export DC

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

    if [ -d "${BASE_DIR}/${CLIENT_NAME}" ]; then
        log_error "Instância '${CLIENT_NAME}' já existe!"
        exit 1
    fi

    load_shared_config

    log_info "Verificando DNS..."
    local resolved_ip
    resolved_ip=$(dig +short "$DOMAIN" 2>/dev/null | tail -1)
    if [ "$resolved_ip" != "$SERVER_IP" ]; then
        log_warning "DNS de $DOMAIN resolve para '$resolved_ip' (esperado: $SERVER_IP)"
    else
        log_success "DNS OK: $DOMAIN → $SERVER_IP"
    fi

    local NEXTCLOUD_ADMIN_PASSWORD MYSQL_PASSWORD MYSQL_DATABASE MYSQL_USER REDIS_DB
    NEXTCLOUD_ADMIN_PASSWORD=$(generate_password)
    MYSQL_PASSWORD=$(generate_password)
    MYSQL_DATABASE="nextcloud_${CLIENT_NAME//-/_}"
    MYSQL_USER="nc_${CLIENT_NAME//-/_}"
    REDIS_DB=$(get_next_redis_db)

    log_info "Criando diretórios..."
    mkdir -p "${BASE_DIR}/${CLIENT_NAME}/app"

    log_info "Criando database no MariaDB compartilhado..."
    docker exec shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" -e "
        CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
        CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
        GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
        FLUSH PRIVILEGES;
    "
    log_success "Database '${MYSQL_DATABASE}' criado"

    local BT='`'
    cat > "${BASE_DIR}/${CLIENT_NAME}/.env" << ENV_EOF
# Instância: ${CLIENT_NAME}
# Criado em: $(date '+%Y-%m-%d %H:%M:%S')
CLIENT_NAME=${CLIENT_NAME}
DOMAIN=${DOMAIN}
REDIS_DB=${REDIS_DB}
ENV_EOF
    chmod 600 "${BASE_DIR}/${CLIENT_NAME}/.env"

    cat > "${BASE_DIR}/${CLIENT_NAME}/docker-compose.yml" << YML_EOF
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
      - NEXTCLOUD_ADMIN_USER=admin
      - NEXTCLOUD_TRUSTED_DOMAINS=${DOMAIN}
      - REDIS_HOST=shared-redis
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
      - "traefik.http.services.${CLIENT_NAME}-app.loadbalancer.server.port=80"
      - "traefik.docker.network=proxy"
    networks:
      - shared
      - proxy

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
    volumes:
      - ./harp-certs:/certs
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - shared

networks:
  shared:
    external: true
  proxy:
    external: true
YML_EOF

    mkdir -p "${BASE_DIR}/${CLIENT_NAME}/harp-certs"

    log_info "Iniciando contêineres..."
    cd "${BASE_DIR}/${CLIENT_NAME}" || exit 1
    $DC up -d 2>&1

    wait_for_nextcloud "${CLIENT_NAME}-app" 180

    local APP="${CLIENT_NAME}-app"

    local retries=0
    while ! docker exec "$APP" bash -c "curl -sf --max-time 5 https://apps.nextcloud.com > /dev/null 2>&1" && [ $retries -lt 30 ]; do
        retries=$((retries + 1))
        log_warning "Sem conectividade... tentativa $retries/30"
        sleep 5
    done

    run_occ "$APP" config:system:set redis host --value="shared-redis"
    run_occ "$APP" config:system:set redis port --value="6379" --type=integer
    run_occ "$APP" config:system:set redis dbindex --value="${REDIS_DB}" --type=integer
    run_occ "$APP" config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
    run_occ "$APP" config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis"
    run_occ "$APP" config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"

    run_occ "$APP" config:system:set trusted_proxies 0 --value="172.16.0.0/12"
    run_occ "$APP" config:system:set trusted_proxies 1 --value="192.168.0.0/16"
    run_occ "$APP" config:system:set trusted_proxies 2 --value="10.0.0.0/8"
    run_occ "$APP" config:system:set overwriteprotocol --value="https"
    run_occ "$APP" config:system:set overwrite.cli.url --value="https://${DOMAIN}"
    run_occ "$APP" config:system:set default_phone_region --value="BR"

    local APPS="richdocuments calendar contacts mail deck forms notes tasks groupfolders photos activity spreed app_api notify_push"
    for app in $APPS; do
        local install_attempts=0
        while ! run_occ "$APP" app:install "$app" 2>/dev/null && [ $install_attempts -lt 3 ]; do
            install_attempts=$((install_attempts + 1))
            sleep 5
        done
        run_occ "$APP" app:enable "$app" 2>/dev/null || true
    done

    run_occ "$APP" config:app:set richdocuments wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments public_wopi_url --value="https://${COLLABORA_DOMAIN}"
    run_occ "$APP" config:app:set richdocuments wopi_allowlist --value="0.0.0.0/0"
    run_occ "$APP" config:app:set richdocuments disable_certificate_verification --value="no"
    run_occ "$APP" richdocuments:activate-config 2>/dev/null || true

    run_occ "$APP" config:app:set spreed turn_servers --value="[{\"server\":\"${TURN_DOMAIN}:3478\",\"secret\":\"${TURN_SECRET}\",\"protocols\":\"udp,tcp\"}]"
    run_occ "$APP" config:app:set spreed stun_servers --value="[\"${TURN_DOMAIN}:3478\"]"

    run_occ "$APP" config:app:set spreed signaling_servers --value="{\"servers\":[{\"server\":\"https://${SIGNALING_DOMAIN}/\",\"verify\":true}],\"secret\":\"${SIGNALING_SECRET}\"}"

    run_occ "$APP" config:app:set spreed recording_servers --value="{\"secret\":\"${RECORDING_SECRET}\",\"servers\":[{\"server\":\"http://shared-recording:1234/\",\"verify\":false}]}"

    run_occ "$APP" app_api:daemon:register \
        harp_install "HaRP" docker-install http "${CLIENT_NAME}-harp:8780" \
        "https://${DOMAIN}" --net="shared" \
        --harp --harp_frp_address "${CLIENT_NAME}-harp:8782" \
        --harp_shared_key "${HARP_SHARED_KEY}" --set-default 2>/dev/null || true

    run_occ "$APP" config:system:set trusted_domains 0 --value="${DOMAIN}"
    run_occ "$APP" config:app:set notify_push base_endpoint --value="https://${DOMAIN}/push" 2>/dev/null || true
    run_occ "$APP" db:add-missing-indices
    run_occ "$APP" db:add-missing-columns 2>/dev/null || true
    run_occ "$APP" db:add-missing-primary-keys 2>/dev/null || true
    run_occ "$APP" background:cron
    run_occ "$APP" config:system:set htaccess.RewriteBase --value='/'
    run_occ "$APP" maintenance:update:htaccess 2>/dev/null || true
    docker exec "$APP" bash -c 'truncate -s 0 /var/www/html/data/nextcloud.log' 2>/dev/null || true
    run_occ "$APP" log:manage --level=warning
    run_occ "$APP" maintenance:repair 2>/dev/null || true

    update_collabora_allowlist
    update_signaling_backends
    update_recording_backends

    if docker exec -u www-data "$APP" php occ status 2>/dev/null | grep -q "installed: true"; then
        log_success "Nextcloud: OK"
    else
        log_error "Nextcloud: FALHA"
    fi

    echo ""
    log_success "Instância '${CLIENT_NAME}' criada com sucesso!"
    echo ""
    echo "  URL:      https://${DOMAIN}"
    echo "  Usuário:  admin"
    echo ""
}

# ============================================================
# COMANDO: STATUS
# ============================================================
cmd_status() {
    local CLIENT_NAME="$1"

    if [ ! -d "${BASE_DIR}/${CLIENT_NAME}" ]; then
        log_error "Instância '${CLIENT_NAME}' não encontrada!"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${BASE_DIR}/${CLIENT_NAME}/.env"
    echo ""
    echo "=== Status da Instância: ${CLIENT_NAME} ==="
    echo "  Domínio: ${DOMAIN}"
    echo ""

    echo "--- Containers do Cliente ---"
    local container status
    for container in "${CLIENT_NAME}-app" "${CLIENT_NAME}-cron"; do
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        if [ "$status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} $container: $status"
        else
            echo -e "  ${RED}●${NC} $container: $status"
        fi
    done

    echo ""
    echo "--- Serviços Compartilhados ---"
    for container in shared-db shared-redis shared-collabora shared-turn shared-nats shared-janus shared-signaling shared-recording; do
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
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

    if [ ! -f "${BASE_DIR}/${CLIENT_NAME}/.credentials" ]; then
        log_error "Arquivo de credenciais não encontrado!"
        exit 1
    fi

    cat "${BASE_DIR}/${CLIENT_NAME}/.credentials"
}

# ============================================================
# COMANDO: BACKUP
# ============================================================
cmd_backup() {
    local CLIENT_NAME="$1"

    if [ ! -d "${BASE_DIR}/${CLIENT_NAME}" ]; then
        log_error "Instância '${CLIENT_NAME}' não encontrada!"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${BASE_DIR}/${CLIENT_NAME}/.env"
    load_shared_config

    local BACKUP_DIR="${BASE_DIR}/backups"
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    local BACKUP_FILE="${BACKUP_DIR}/${CLIENT_NAME}_${TIMESTAMP}.tar.gz"
    mkdir -p "$BACKUP_DIR"

    log_info "Iniciando backup de '${CLIENT_NAME}'..."
    docker exec shared-db mariadb-dump -uroot -p"${DB_ROOT_PASSWORD}" "${MYSQL_DATABASE}" > "${BASE_DIR}/${CLIENT_NAME}/database.sql"
    log_success "Database exportado"

    cd "${BASE_DIR}" || exit 1
    tar -czf "$BACKUP_FILE" "${CLIENT_NAME}/"
    rm -f "${BASE_DIR}/${CLIENT_NAME}/database.sql"

    local SIZE
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log_success "Backup concluído: ${BACKUP_FILE} (${SIZE})"
}

# ============================================================
# COMANDO: RESTORE
# ============================================================
cmd_restore() {
    local CLIENT_NAME="$1"
    local BACKUP_FILE="$2"

    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Arquivo de backup não encontrado: ${BACKUP_FILE}"
        exit 1
    fi

    load_shared_config

    log_info "Restaurando '${CLIENT_NAME}' de ${BACKUP_FILE}..."
    cd "${BASE_DIR}" || exit 1
    tar -xzf "$BACKUP_FILE"

    # shellcheck disable=SC1090
    source "${BASE_DIR}/${CLIENT_NAME}/.env"

    docker exec shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" -e "
        DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`;
        CREATE DATABASE \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
        CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
        GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
        FLUSH PRIVILEGES;
    "

    if [ -f "${BASE_DIR}/${CLIENT_NAME}/database.sql" ]; then
        docker exec -i shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < "${BASE_DIR}/${CLIENT_NAME}/database.sql"
        rm -f "${BASE_DIR}/${CLIENT_NAME}/database.sql"
        log_success "Database restaurado"
    fi

    cd "${BASE_DIR}/${CLIENT_NAME}" || exit 1
    $DC up -d

    update_collabora_allowlist
    update_signaling_backends
    update_recording_backends

    log_success "Instância '${CLIENT_NAME}' restaurada com sucesso!"
}

# ============================================================
# COMANDO: STOP
# ============================================================
cmd_stop() {
    local CLIENT_NAME="$1"
    log_info "Parando instância '${CLIENT_NAME}'..."
    cd "${BASE_DIR}/${CLIENT_NAME}" || exit 1
    $DC stop
    log_success "Instância parada"
}

# ============================================================
# COMANDO: START
# ============================================================
cmd_start() {
    local CLIENT_NAME="$1"
    log_info "Iniciando instância '${CLIENT_NAME}'..."
    cd "${BASE_DIR}/${CLIENT_NAME}" || exit 1
    $DC up -d
    log_success "Instância iniciada"
}

# ============================================================
# COMANDO: UPDATE
# ============================================================
cmd_update() {
    local CLIENT_NAME="$1"
    log_info "Atualizando instância '${CLIENT_NAME}'..."

    cmd_backup "$CLIENT_NAME"

    cd "${BASE_DIR}/${CLIENT_NAME}" || exit 1
    $DC pull
    $DC up -d

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

    if [ ! -d "${BASE_DIR}/${CLIENT_NAME}" ]; then
        log_error "Instância '${CLIENT_NAME}' não encontrada!"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${BASE_DIR}/${CLIENT_NAME}/.env"
    load_shared_config

    echo ""
    log_warning "ATENÇÃO: Isso vai REMOVER PERMANENTEMENTE a instância '${CLIENT_NAME}'!"
    log_warning "Domínio: ${DOMAIN}"
    log_warning "Database: ${MYSQL_DATABASE}"
    echo ""
    read -r -p "Digite 'CONFIRMAR' para prosseguir: " confirm
    if [ "$confirm" != "CONFIRMAR" ]; then
        log_info "Operação cancelada."
        exit 0
    fi

    cd "${BASE_DIR}/${CLIENT_NAME}" || { log_error "Diretório não encontrado"; exit 1; }
    $DC down -v 2>/dev/null || true

    docker exec shared-db mariadb -uroot -p"${DB_ROOT_PASSWORD}" -e "
        DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`;
        DROP USER IF EXISTS '${MYSQL_USER}'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null || true

    if [ -z "${BASE_DIR:-}" ] || [ -z "${CLIENT_NAME:-}" ]; then
        log_error "BASE_DIR ou CLIENT_NAME vazios; abortando rm para evitar dano."
        exit 1
    fi
    rm -rf "${BASE_DIR:?BASE_DIR não definido}/${CLIENT_NAME:?CLIENT_NAME não definido}"

    update_collabora_allowlist
    update_signaling_backends
    update_recording_backends

    log_success "Instância '${CLIENT_NAME}' removida completamente!"
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

    local dir name domain container status
    for dir in "${BASE_DIR}"/*/; do
        if [ -f "${dir}/.env" ] && [ -f "${dir}/docker-compose.yml" ]; then
            name=$(basename "$dir")
            domain=$(grep "^DOMAIN=" "${dir}/.env" 2>/dev/null | cut -d= -f2)
            container="${name}-app"
            status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "stopped")
            printf "%-20s %-35s %-10s\n" "$name" "$domain" "$status"
        fi
    done
    echo ""

    echo "=== Serviços Compartilhados ==="
    echo ""
    for container in shared-db shared-redis shared-collabora shared-turn shared-nats shared-janus shared-signaling shared-recording; do
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
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
    local container status uptime
    for container in shared-db shared-redis shared-collabora shared-turn shared-nats shared-janus shared-signaling shared-recording; do
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not found")
        uptime=$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null | cut -dT -f1)
        if [ "$status" = "running" ]; then
            echo -e "  ${GREEN}●${NC} $container (since $uptime)"
        else
            echo -e "  ${RED}●${NC} $container: $status"
        fi
    done
    echo ""
    echo "  Collabora:  https://${COLLABORA_DOMAIN}"
    echo "  Signaling:  https://${SIGNALING_DOMAIN}"
    echo "  TURN:       turn:${TURN_DOMAIN}:3478"
    echo ""
}

# ============================================================
# USAGE
# ============================================================
usage() {
    echo ""
    echo "Nextcloud SaaS Manager v12.0-dev (Arquitetura Compartilhada)"
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
    echo "Flags globais (D2+): --async --json --dry-run --idempotency-key --callback"
    echo ""
}

# ============================================================
# MAIN
# ============================================================

# Verificar root (exceto em modo de teste)
if [ "${MANAGE_SKIP_ROOT_CHECK:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    log_error "Execute como root: sudo $0 $*"
    exit 1
fi

# Parsear flags globais (D1: apenas registra; D2 irá atuar)
parse_global_flags "$@" || true

# Parse posicional legado
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

        # Remover flags globais dos args para não confundir o parser posicional
        # (flags sempre começam com --, então são ignoradas no posicional)

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
            "")
                log_error "Comando não especificado para cliente '${CLIENT_NAME}'"
                usage
                exit 1
                ;;
            *)
                log_error "Comando desconhecido: '${COMMAND}'"
                usage
                exit 1
                ;;
        esac
        ;;
esac
