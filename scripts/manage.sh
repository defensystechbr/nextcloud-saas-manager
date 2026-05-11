#!/bin/bash
# ============================================================
# Nextcloud SaaS Manager v12.0-dev
# Dispatcher híbrido — parser legado posicional + namespaces hierárquicos.
# Compatibilidade: manage.sh <cliente> <dom|_> <cmd> [flags]
# Novo:            manage.sh <cliente> <namespace> <verb> [flags]
#                  manage.sh worker {status|stats} [flags]
#                  manage.sh job <id> {status|logs|cancel} [flags]
#                  manage.sh job list [filters] [flags]
# ============================================================

set -euo pipefail

MANAGE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# LIBS
# ============================================================
# shellcheck source=scripts/lib/validators.sh
source "${MANAGE_SCRIPT_DIR}/lib/validators.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${MANAGE_SCRIPT_DIR}/lib/output_json.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${MANAGE_SCRIPT_DIR}/lib/job_queue.sh"
# shellcheck source=scripts/lib/job_runner.sh
source "${MANAGE_SCRIPT_DIR}/lib/job_runner.sh"
# shellcheck source=scripts/lib/ssh_audit.sh
source "${MANAGE_SCRIPT_DIR}/lib/ssh_audit.sh"
# shellcheck source=scripts/lib/legacy_helpers.sh
source "${MANAGE_SCRIPT_DIR}/lib/legacy_helpers.sh"
# shellcheck source=scripts/lib/dispatch.sh
source "${MANAGE_SCRIPT_DIR}/lib/dispatch.sh"
# shellcheck source=scripts/lib/feature_o.sh
source "${MANAGE_SCRIPT_DIR}/lib/feature_o.sh"
# shellcheck source=scripts/lib/feature_o_ext.sh
source "${MANAGE_SCRIPT_DIR}/lib/feature_o_ext.sh"
# shellcheck source=scripts/lib/occ_bridge.sh
source "${MANAGE_SCRIPT_DIR}/lib/occ_bridge.sh"
# shellcheck source=scripts/lib/health_checks.sh
source "${MANAGE_SCRIPT_DIR}/lib/health_checks.sh"
# shellcheck source=scripts/lib/backup_offsite.sh
source "${MANAGE_SCRIPT_DIR}/lib/backup_offsite.sh"

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
      - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
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
    environment:
      - DOCKER_HOST=tcp://shared-socket-proxy:2375
    volumes:
      - ./harp-certs:/certs
    networks:
      - shared

networks:
  shared:
    external: true
  proxy:
    external: true
YML_EOF
    cat > "${BASE_DIR}/${CLIENT_NAME}/.credentials" << CRED_EOF
=== Credenciais da Instância: ${CLIENT_NAME} ===
URL: https://${DOMAIN}
Usuário: admin
Senha: ${NEXTCLOUD_ADMIN_PASSWORD}
Database: ${MYSQL_DATABASE}
Database user: ${MYSQL_USER}
Database password: ${MYSQL_PASSWORD}
Redis DB: ${REDIS_DB}
CRED_EOF
    chmod 600 "${BASE_DIR}/${CLIENT_NAME}/.credentials"

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
    docker exec "$APP" bash -c 'mkdir -p /var/www/html/data/tmp && chown -R www-data:www-data /var/www/html/data/tmp && chmod 0770 /var/www/html/data/tmp'
    run_occ "$APP" config:system:set tempdirectory --value="/var/www/html/data/tmp"

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

    # D3.5 — Extended setup: --apps, --full-apps, --staging-id
    if [[ -n "${PARSED_FLAGS[apps]:-}" || "${PARSED_FLAGS[full_apps]:-}" == "1" || -n "${PARSED_FLAGS[staging_id]:-}" ]]; then
        cmd_create_post_extended "$CLIENT_NAME"
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

    # D3.6 — --backup-first: enqueue backup antes de remover (job composto)
    if [[ "${PARSED_FLAGS[backup_first]:-}" == "1" && "${PARSED_FLAGS[async]:-}" == "1" ]]; then
        cmd_backup_then_remove_enqueue "$CLIENT_NAME"
        return 0
    fi

    # D3.6 — Validar confirmação em modo async/worker
    _cmd_remove_validate_confirm "$CLIENT_NAME" || exit 5

    # shellcheck disable=SC1090
    source "${BASE_DIR}/${CLIENT_NAME}/.env"
    load_shared_config

    local _force="${PARSED_FLAGS[force]:-}"
    local _is_worker="${PARSED_FLAGS[no_async_pickup]:-}"

    # Prompt de confirmação apenas em modo sync sem --force e sem worker
    if [[ -z "$_force" && -z "$_is_worker" ]]; then
        echo ""
        log_warning "ATENÇÃO: Isso vai REMOVER PERMANENTEMENTE a instância '${CLIENT_NAME}'!"
        log_warning "Domínio: ${DOMAIN}"
        log_warning "Database: ${MYSQL_DATABASE}"
        echo ""
        read -r -p "Digite 'CONFIRMAR' para prosseguir: " _confirm_input
        if [ "$_confirm_input" != "CONFIRMAR" ]; then
            log_info "Operação cancelada."
            exit 0
        fi
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
# COMANDO: BACKUP-THEN-REMOVE (D3.6 — job composto)
# Executado pelo worker quando cmd=backup-then-remove.
# ============================================================
cmd_backup_then_remove() {
    local CLIENT_NAME="$1"
    log_info "backup-then-remove: fazendo backup de '${CLIENT_NAME}' antes de remover..."
    # Force confirm for the remove step (worker mode)
    PARSED_FLAGS[force]="1"
    PARSED_FLAGS[no_async_pickup]="1"
    cmd_backup "$CLIENT_NAME" 2>&1 || {
        log_error "backup-then-remove: backup falhou para '${CLIENT_NAME}'; abortando remocao."
        return 1
    }
    log_info "backup-then-remove: backup concluido; removendo instancia..."
    cmd_remove "$CLIENT_NAME"
}

# ============================================================
# COMANDO: OCC-EXEC (Feature P)
# ============================================================
cmd_occ_exec() {
    local CLIENT_NAME="$1"
    local SUBCMD="$2"
    shift 2
    local -a OCC_ARGS=("$@")

    if [[ "${PARSED_FLAGS[async]:-}" == "1" ]]; then
        emit_error "async_not_supported" "occ-exec e sempre sincronico" >&2
        return 5
    fi

    case "$SUBCMD" in
        user:add|user:resetpassword)
            if [[ "${PARSED_FLAGS[payload_stdin]:-}" != "1" ]]; then
                emit_error "payload_stdin_required" "occ-exec ${SUBCMD} requer --payload-stdin com password" >&2
                return 5
            fi
            local payload password
            payload="$(cat)"
            password="$(printf '%s' "$payload" | jq -r '.password // empty' 2>/dev/null || true)"
            if [[ -z "$password" ]]; then
                emit_error "payload_password_required" "payload JSON deve conter password" >&2
                return 5
            fi
            export NEXTCLOUD_USER_PASSWORD="$password"
            ;;
    esac

    local rc=0
    if occ_run "$CLIENT_NAME" "$SUBCMD" "${OCC_ARGS[@]+"${OCC_ARGS[@]}"}"; then
        rc=0
    else
        rc=$?
    fi
    unset NEXTCLOUD_USER_PASSWORD
    return "$rc"
}

# ============================================================
# COMANDO: BACKUP-OFFSITE (Feature E — Sprint N2)
# ============================================================
cmd_backup_offsite() {
    local CLIENT_NAME="$1"

    if [ ! -d "${BASE_DIR}/${CLIENT_NAME}" ]; then
        if [[ "${PARSED_FLAGS[json]:-}" == "1" ]]; then
            emit_error "client_not_found" "instancia '${CLIENT_NAME}' nao encontrada"
        else
            log_error "Instância '${CLIENT_NAME}' não encontrada!"
        fi
        return 1
    fi

    local is_dry_run="${PARSED_FLAGS[dry_run]:-}"
    local is_json="${PARSED_FLAGS[json]:-}"

    # Carregar secrets — exit 12 se ausentes
    if ! backup_offsite_read_secrets; then
        return 12
    fi

    if [[ "$is_dry_run" == "1" ]]; then
        if [[ "$is_json" != "1" ]]; then
            log_info "Dry-run: verificando repositório restic sem fazer backup..."
        fi
        backup_offsite_do_backup "$CLIENT_NAME" "1"
        return $?
    fi

    # Backup real
    if [[ "$is_json" != "1" ]]; then
        log_info "Iniciando backup off-site de '${CLIENT_NAME}'..."
    fi

    # Inicializar repositório se necessário
    if ! backup_offsite_init_repo; then
        if [[ "$is_json" == "1" ]]; then
            emit_error "backup_init_failed" "falha ao inicializar repositório restic"
        else
            log_error "Falha ao inicializar repositório restic"
        fi
        return 1
    fi

    backup_offsite_do_backup "$CLIENT_NAME" "0"
    local exit_code=$?

    if [[ $exit_code -eq 0 && "$is_json" != "1" ]]; then
        log_success "Backup off-site de '${CLIENT_NAME}' concluído"
    fi

    return $exit_code
}

# ============================================================
# COMANDO: HEALTH (Feature C/D4)
# ============================================================
cmd_health() {
    local result
    result="$(run_health_checks_json)"
    if [[ "${PARSED_FLAGS[json]:-}" == "1" ]]; then
        echo "$result"
    else
        echo ""
        echo "=== Nextcloud SaaS Health ==="
        echo "$result" | jq -r '.checks[] | "  [" + .status + "] " + .name + ": " + .message + " (" + (.duration_ms|tostring) + "ms)"'
        echo "$result" | jq -r '"Summary: ok=\(.summary.ok) warn=\(.summary.warn) fail=\(.summary.fail)"'
        echo ""
    fi
    local fail_count warn_count
    fail_count="$(echo "$result" | jq -r '.summary.fail')"
    warn_count="$(echo "$result" | jq -r '.summary.warn')"
    (( fail_count > 0 )) && return 2
    (( warn_count > 0 )) && return 1
    return 0
}

# ============================================================
# COMANDO: UPGRADE-HARP (Feature M/D4)
# ============================================================
cmd_upgrade_harp() {
    local CLIENT_NAME="$1"
    local client_dir="${BASE_DIR}/${CLIENT_NAME}"
    local compose_file="${client_dir}/docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        emit_error "client_not_found" "docker-compose.yml nao encontrado para '${CLIENT_NAME}'" >&2
        return 1
    fi

    python3 - "$compose_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("      - /var/run/docker.sock:/var/run/docker.sock\n", "")
marker = "    restart: always\n"
replacement = "    restart: always\n    environment:\n      - DOCKER_HOST=tcp://shared-socket-proxy:2375\n"
if "container_name:" in text and "DOCKER_HOST=tcp://shared-socket-proxy:2375" not in text:
    # Apply only to the harp service block by splitting around its service key.
    before, sep, after = text.partition("  harp:\n")
    if sep:
        block, tail_sep, tail = after.partition("\n\nnetworks:")
        block = block.replace(marker, replacement, 1)
        text = before + sep + block + tail_sep + tail
path.write_text(text)
PY

    if [[ "${PARSED_FLAGS[dry_run]:-}" == "1" ]]; then
        emit_json operation "upgrade-harp" client "$CLIENT_NAME" dry_run "@bool:true" status "planned"
        return 0
    fi

    (cd "$client_dir" && $DC up -d harp) >/dev/null
    emit_json operation "upgrade-harp" client "$CLIENT_NAME" status "updated"
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
    echo "Nextcloud SaaS Manager v12.0 (Arquitetura Compartilhada)"
    echo ""
    echo "Uso:"
    echo ""
    echo "Uso (legado posicional):"
    echo "  $(basename "$0") <cliente> <domínio> create     Criar nova instância (async-capable)"
    echo "  $(basename "$0") <cliente> _ status             Status da instância (sync)"
    echo "  $(basename "$0") <cliente> _ credentials        Exibir credenciais (sync)"
    echo "  $(basename "$0") <cliente> _ backup             Backup (async-capable)"
    echo "  $(basename "$0") <cliente> <backup.gz> restore  Restaurar instância (async-capable)"
    echo "  $(basename "$0") <cliente> _ stop               Parar (async-capable)"
    echo "  $(basename "$0") <cliente> _ start              Iniciar (async-capable)"
    echo "  $(basename "$0") <cliente> _ update             Atualizar (async-capable)"
    echo "  $(basename "$0") <cliente> _ remove             Remover (async-capable)"
    echo ""
    echo "Uso (namespaces hierárquicos — implementação D3/D4):"
    echo "  $(basename "$0") <cliente> user   create|remove|modify [--async] [--payload-stdin]"
    echo "  $(basename "$0") <cliente> group  create|remove|modify [--async]"
    echo "  $(basename "$0") <cliente> apps   enable|disable [--async]"
    echo "  $(basename "$0") <cliente> occ-exec <subcmd> [args]"
    echo ""
    echo "Introspection (D2):"
    echo "  $(basename "$0") list                           Listar todas as instâncias"
    echo "  $(basename "$0") shared-status                  Status dos serviços compartilhados"
    echo "  $(basename "$0") worker status [--json]         Status do worker daemon"
    echo "  $(basename "$0") worker stats [--by-cmd] [--by-client] [--json]"
    echo "  $(basename "$0") job <id> status [--json]       Status de um job"
    echo "  $(basename "$0") job <id> logs                  Logs de um job"
    echo "  $(basename "$0") job <id> cancel                Cancelar job em fila"
    echo "  $(basename "$0") job list [--state=...] [--client=...] [--cmd=...] [--limit=N] [--offset=N]"
    echo "  $(basename "$0") health [--json]                 Health consolidado"
    echo "  $(basename "$0") upgrade-harp <cliente>          Migrar HaRP para socket-proxy"
    echo ""
    echo "Flags globais: --async --json --dry-run --idempotency-key=<uuid> --callback=<url>"
    echo "               --confirm=<client> --payload-stdin --strict --staging-id=<uuid>"
    echo ""
}

# ============================================================
# WORKER SUBCOMMANDS (D2.7, D2.9)
# ============================================================
cmd_worker_status() {
    local is_json="${PARSED_FLAGS[json]:-}"
    local result
    result="$(worker_status)"

    if [[ "$is_json" == "1" ]]; then
        echo "$result"
    else
        local queue_depth current_job
        queue_depth="$(echo "$result" | jq -r '.queue_depth // 0')"
        current_job="$(echo "$result" | jq -r '.current_job // "none"')"
        echo ""
        echo "=== Worker Status ==="
        echo "  Queue depth:  ${queue_depth}"
        echo "  Current job:  ${current_job}"
        echo ""
    fi
}

cmd_worker_stats() {
    local is_json="${PARSED_FLAGS[json]:-}"
    local by_cmd="" by_client=""

    local arg
    for arg in "$@"; do
        case "$arg" in
            --by-cmd)    by_cmd=1 ;;
            --by-client) by_client=1 ;;
        esac
    done

    local result
    if ! result="$(worker_stats "$by_cmd" "$by_client")"; then
        if [[ "$is_json" == "1" ]]; then
            emit_error "redis_unavailable" "nao foi possivel consultar estatisticas da fila Redis"
        else
            log_error "Não foi possível consultar estatísticas da fila Redis"
        fi
        exit 1
    fi

    if [[ "$is_json" == "1" ]]; then
        echo "$result"
    else
        echo ""
        echo "=== Worker Stats ==="
        echo "$result" | jq -r '
          "  By state:",
          (.by_state | to_entries[] | "    " + .key + ": " + (.value|tostring)),
          if .by_cmd then "  By cmd:", (.by_cmd | to_entries[] | "    " + .key + ": " + (.value|tostring)) else "" end,
          if .by_client then "  By client:", (.by_client | to_entries[] | "    " + .key + ": " + (.value|tostring)) else "" end
        ' 2>/dev/null || echo "$result"
        echo ""
    fi
}

# ============================================================
# JOB SUBCOMMANDS (D2.8)
# ============================================================
cmd_job_status() {
    local job_id="${1:?cmd_job_status: job_id obrigatorio}"
    local is_json="${PARSED_FLAGS[json]:-}"
    local result
    result="$(get_state "$job_id")"

    if [[ "$result" == "{}" ]]; then
        if [[ "$is_json" == "1" ]]; then
            emit_error "job_not_found" "job '${job_id}' nao encontrado"
        else
            log_error "Job não encontrado: ${job_id}"
        fi
        exit 1
    fi

    if [[ "$is_json" == "1" ]]; then
        echo "$result"
    else
        echo ""
        echo "=== Job ${job_id} ==="
        echo "$result" | jq -r 'to_entries[] | "  " + .key + ": " + (.value|tostring)'
        echo ""
    fi
}

cmd_job_logs() {
    local job_id="${1:?cmd_job_logs: job_id obrigatorio}"
    local log_dir="${WORKER_JOBS_DIR:-/opt/nextcloud-saas/jobs}"
    local log_file="${log_dir}/${job_id}/output.log"

    if [[ ! -f "$log_file" ]]; then
        log_error "Log não encontrado para job: ${job_id}"
        exit 1
    fi
    cat "$log_file"
}

cmd_job_cancel() {
    local job_id="${1:?cmd_job_cancel: job_id obrigatorio}"
    local is_json="${PARSED_FLAGS[json]:-}"

    if ! job_cancel "$job_id"; then
        if [[ "$is_json" == "1" ]]; then
            emit_error "job_not_cancellable" "job '${job_id}' nao esta em estado queued"
        else
            log_error "Job '${job_id}' não pode ser cancelado (não está em estado queued)"
        fi
        exit 5
    fi

    if [[ "$is_json" == "1" ]]; then
        emit_json job_id "$job_id" state "cancelled"
    else
        log_success "Job '${job_id}' cancelado"
    fi
}

cmd_job_list() {
    local state_filter="" client_filter="" cmd_filter="" limit=20 offset=0
    local is_json="${PARSED_FLAGS[json]:-}"

    local arg
    for arg in "$@"; do
        case "$arg" in
            --state=*)   state_filter="${arg#--state=}" ;;
            --client=*)  client_filter="${arg#--client=}" ;;
            --cmd=*)     cmd_filter="${arg#--cmd=}" ;;
            --limit=*)   limit="${arg#--limit=}" ;;
            --offset=*)  offset="${arg#--offset=}" ;;
            --after=*)   offset="${arg#--after=}" ;;  # cursor-style (simplified)
        esac
    done

    local result
    if ! result="$(job_list "$state_filter" "$client_filter" "$cmd_filter" "$limit" "$offset")"; then
        if [[ "$is_json" == "1" ]]; then
            emit_error "redis_unavailable" "nao foi possivel listar jobs na fila Redis"
        else
            log_error "Não foi possível listar jobs na fila Redis"
        fi
        exit 1
    fi

    if [[ "$is_json" == "1" ]]; then
        echo "$result"
    else
        echo ""
        echo "=== Job List ==="
        echo "$result" | jq -r '.[] | "\(.job_id // "?") [\(.state // "?")] \(.cmd // "?") @ \(.client // "?")"' 2>/dev/null || echo "$result"
        echo ""
    fi
}

# ============================================================
# MAIN
# ============================================================

# Verificar root (exceto em modo de teste)
if [ "${MANAGE_SKIP_ROOT_CHECK:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    if [[ "${PARSED_FLAGS[json]:-}" == "1" ]] 2>/dev/null; then
        emit_error "requires_root" "execute como root: sudo $0"
    else
        log_error "Execute como root: sudo $0 $*"
    fi
    exit 1
fi

# Parsear flags globais — D2: atua; exit 5 em flags inválidas
if ! parse_global_flags "$@"; then
    exit 5
fi

# ============================================================
# Extrair args posicionais (sem flags --)
# ============================================================
POSITIONAL=()
_skip_next=0
for _arg in "$@"; do
    if [[ $_skip_next -eq 1 ]]; then
        _skip_next=0
        continue
    fi
    case "$_arg" in
        --idempotency-key|--callback|--staging-id|--confirm)
            _skip_next=1
            ;;
        --*)
            ;;
        *)
            POSITIONAL+=("$_arg")
            ;;
    esac
done

TOKEN0="${POSITIONAL[0]:-}"
TOKEN1="${POSITIONAL[1]:-}"
TOKEN2="${POSITIONAL[2]:-}"

# ============================================================
# Dispatch raiz
# ============================================================
case "$TOKEN0" in
    list)
        cmd_list
        ;;
    shared-status)
        cmd_shared_status
        ;;
    health)
        cmd_health
        ;;
    upgrade-harp)
        if [[ -z "$TOKEN1" ]]; then
            emit_error "missing_client" "upgrade-harp requer cliente" >&2
            exit 5
        fi
        cmd_upgrade_harp "$TOKEN1"
        ;;
    ""|help|-h|--help)
        usage
        ;;

    # ─── worker subcommands ─────────────────────────────────
    worker)
        case "$TOKEN1" in
            status)
                cmd_worker_status
                ;;
            stats)
                cmd_worker_stats "${POSITIONAL[@]:2}"
                ;;
            "")
                cmd_worker_status
                ;;
            *)
                log_error "worker: subcomando desconhecido '${TOKEN1}'"
                usage
                exit 1
                ;;
        esac
        ;;

    # ─── job subcommands ────────────────────────────────────
    job)
        case "$TOKEN1" in
            list)
                cmd_job_list "${POSITIONAL[@]:2}" "$@"
                ;;
            "")
                log_error "job: id ou 'list' obrigatório"
                usage
                exit 1
                ;;
            *)
                # job <id> {status|logs|cancel}
                local_job_id="$TOKEN1"
                case "$TOKEN2" in
                    status|"")
                        cmd_job_status "$local_job_id"
                        ;;
                    logs)
                        cmd_job_logs "$local_job_id"
                        ;;
                    cancel)
                        cmd_job_cancel "$local_job_id"
                        ;;
                    *)
                        log_error "job: ação desconhecida '${TOKEN2}'"
                        usage
                        exit 1
                        ;;
                esac
                ;;
        esac
        ;;

    # ─── client dispatch ────────────────────────────────────
    *)
        CLIENT_NAME="$TOKEN0"

        # Validar client name
        if ! is_valid_client_name "$CLIENT_NAME"; then
            if [[ "${PARSED_FLAGS[json]:-}" == "1" ]]; then
                emit_error "invalid_client_name" "nome de cliente invalido: '${CLIENT_NAME}'"
            else
                log_error "Nome de cliente inválido: '${CLIENT_NAME}'"
            fi
            exit 5
        fi

        # Verificar se TOKEN1 é namespace reservado
        _is_namespace=0
        _ns=""
        for _ns in "${RESERVED_NAMESPACES[@]}"; do
            if [[ "$TOKEN1" == "$_ns" ]]; then
                _is_namespace=1
                break
            fi
        done

        if [[ $_is_namespace -eq 1 ]]; then
            # Namespace path: manage.sh <client> <ns> <verb> [args...]
            dispatch_namespace_cmd "$CLIENT_NAME" "$TOKEN1" "${POSITIONAL[@]:2}"
        else
            # Legacy path: manage.sh <client> <dom|_> <cmd> [args...]
            DOMAIN_OR_PLACEHOLDER="${TOKEN1:-_}"
            COMMAND="${TOKEN2:-}"

            case "$COMMAND" in
                create)
                    if [ "$DOMAIN_OR_PLACEHOLDER" = "_" ]; then
                        log_error "Domínio obrigatório para 'create'. Uso: $0 <cliente> <domínio> create"
                        exit 1
                    fi
                    dispatch_legacy_cmd "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER" "create" "${POSITIONAL[@]:3}"
                    ;;
                status|credentials|backup|backup-offsite|restore|stop|start|update)
                    dispatch_legacy_cmd "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER" "$COMMAND" "${POSITIONAL[@]:3}"
                    ;;
                backup-then-remove)
                    dispatch_legacy_cmd "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER" "backup-then-remove" "${POSITIONAL[@]:3}"
                    ;;
                remove)
                    # D3.6 — pre-validate confirm before async enqueue
                    if [[ "${PARSED_FLAGS[async]:-}" == "1" ]]; then
                        _cmd_remove_validate_confirm "$CLIENT_NAME" || exit 5
                        if [[ "${PARSED_FLAGS[backup_first]:-}" == "1" ]]; then
                            cmd_backup_then_remove_enqueue "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER"
                        else
                            dispatch_legacy_cmd "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER" "remove" "${POSITIONAL[@]:3}"
                        fi
                    else
                        dispatch_legacy_cmd "$CLIENT_NAME" "$DOMAIN_OR_PLACEHOLDER" "remove" "${POSITIONAL[@]:3}"
                    fi
                    ;;
                "")
                    log_error "Comando não especificado para cliente '${CLIENT_NAME}'"
                    usage
                    exit 1
                    ;;
                *)
                    if [[ "${PARSED_FLAGS[json]:-}" == "1" ]]; then
                        emit_error "unknown_command" "comando '${COMMAND}' desconhecido"
                    else
                        log_error "Comando desconhecido: '${COMMAND}'"
                        usage
                    fi
                    exit 1
                    ;;
            esac
        fi
        ;;
esac
