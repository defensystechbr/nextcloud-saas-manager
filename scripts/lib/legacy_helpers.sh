#!/bin/bash
# scripts/lib/legacy_helpers.sh — Funções utilitárias migradas de scripts/manage.sh
# Preserva comportamento legado; será refatorado em sprints D2+.
# Source guard
[ "${LEGACY_HELPERS_SH_SOURCED:-0}" = "1" ] && return 0
readonly LEGACY_HELPERS_SH_SOURCED=1
set -euo pipefail

# ============================================================
# Cores e helpers de log
# ============================================================
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
# generate_password
# Gera senha aleatória de 32 chars hex.
# ============================================================
generate_password() { openssl rand -hex 16; }

# ============================================================
# run_occ <container> [occ args...]
# Executa php occ como www-data no container.
# ============================================================
run_occ() {
    local container="$1"
    shift
    docker exec -u www-data "$container" php occ "$@"
}

# ============================================================
# wait_for_nextcloud <container> [timeout_sec]
# Aguarda até Nextcloud reportar installed:true.
# ============================================================
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

# ============================================================
# get_next_redis_db
# Retorna próximo dbindex Redis disponível (>0).
# ============================================================
get_next_redis_db() {
    local max_db=0
    local env_files
    env_files=$(find "${BASE_DIR:-/opt/nextcloud-customers}" -maxdepth 2 -name ".env" 2>/dev/null)
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
# load_shared_config
# Carrega /opt/shared-services/.env; encerra se não existir.
# ============================================================
load_shared_config() {
    local shared_dir="${SHARED_DIR:-/opt/shared-services}"
    if [ ! -f "${shared_dir}/.env" ]; then
        log_error "Serviços compartilhados não configurados!"
        log_error "Execute: sudo setup-shared.sh"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${shared_dir}/.env"

    # Older client .env files only persist CLIENT_NAME/DOMAIN/REDIS_DB.
    # Derive non-secret DB metadata so backup/remove can run in a new process.
    if [ -n "${CLIENT_NAME:-}" ]; then
        MYSQL_DATABASE="${MYSQL_DATABASE:-nextcloud_${CLIENT_NAME//-/_}}"
        MYSQL_USER="${MYSQL_USER:-nc_${CLIENT_NAME//-/_}}"
        export MYSQL_DATABASE MYSQL_USER
    fi
}

# ============================================================
# update_collabora_allowlist
# Atualiza COLLABORA_ALLOWLIST no .env e reinicia Collabora.
# ============================================================
update_collabora_allowlist() {
    log_info "Atualizando Collabora allowlist..."
    local base_dir="${BASE_DIR:-/opt/nextcloud-customers}"
    local shared_dir="${SHARED_DIR:-/opt/shared-services}"
    local domains=""
    for env_file in "${base_dir}"/*/.env; do
        if [ -f "$env_file" ]; then
            local domain
            domain=$(grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d= -f2)
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
        sed -i "s|^COLLABORA_ALLOWLIST=.*|COLLABORA_ALLOWLIST=${domains}|" "${shared_dir}/.env"
        cd "${shared_dir}" || exit 1
        $DC up -d collabora
        log_success "Collabora allowlist atualizado: $domains"
    fi
}

# ============================================================
# update_signaling_backends
# Reescreve signaling.conf e reinicia signaling.
# ============================================================
update_signaling_backends() {
    log_info "Atualizando Signaling backends..."
    local shared_dir="${SHARED_DIR:-/opt/shared-services}"
    # shellcheck disable=SC1090
    source "${shared_dir}/.env"

    local backend_list="" backend_sections="" count=0

    for env_file in "${BASE_DIR:-/opt/nextcloud-customers}"/*/.env; do
        if [ -f "$env_file" ]; then
            local domain
            domain=$(grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d= -f2)
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

    if [ -z "$backend_list" ]; then
        backend_list="backend1"
        backend_sections="
[backend1]
url = https://placeholder.invalid
secret = ${SIGNALING_SECRET}
"
    fi

    cat > "${shared_dir}/hpb/signaling.conf" << SIGCONF_EOF
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
servers = turn:${TURN_DOMAIN}:3478?transport=udp,turn:${TURN_DOMAIN}:3478?transport=tcp
SIGCONF_EOF

    cd "${shared_dir}" || exit 1
    $DC restart signaling
    log_success "Signaling backends atualizado (${count} backends)"
}

# ============================================================
# update_recording_backends
# Reescreve recording/server.conf e reinicia recording.
# ============================================================
update_recording_backends() {
    log_info "Atualizando Recording Server backends..."
    local shared_dir="${SHARED_DIR:-/opt/shared-services}"
    # shellcheck disable=SC1090
    source "${shared_dir}/.env"

    local backend_list="" backend_sections="" count=0

    for env_file in "${BASE_DIR:-/opt/nextcloud-customers}"/*/.env; do
        if [ -f "$env_file" ]; then
            local domain
            domain=$(grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$domain" ]; then
                count=$((count + 1))
                local bname="backend${count}"
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

    if [ -z "$backend_list" ]; then
        backend_list="backend1"
        backend_sections="
[backend1]
url = https://placeholder.invalid
secret = ${RECORDING_SECRET}
skipverify = false
"
    fi

    cat > "${shared_dir}/recording/server.conf" << RECCONF_EOF
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
signalings = signaling1, signaling2

[signaling1]
url = ws://shared-signaling:8080
internalsecret = ${SIGNALING_INTERNAL_SECRET}

[signaling2]
url = https://${SIGNALING_DOMAIN}
internalsecret = ${SIGNALING_INTERNAL_SECRET}

[ffmpeg]
extensionaudio = .ogg
extensionvideo = .webm

[recording]
browser = firefox
driverPath = /usr/bin/geckodriver
browserPath = /usr/bin/firefox
RECCONF_EOF

    cd "${shared_dir}" || exit 1
    $DC restart recording 2>/dev/null || true
    log_success "Recording backends atualizado (${count} backends)"
}
