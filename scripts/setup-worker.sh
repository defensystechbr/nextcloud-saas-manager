#!/bin/bash
# scripts/setup-worker.sh — Instala o worker daemon e habilita AOF no Redis (D2.4)
# Invocado por deploy-server.sh ou manualmente após deploy inicial.
# Idempotente: pode ser executado múltiplas vezes sem efeitos adversos.
#
# Uso: sudo ./scripts/setup-worker.sh [--repo-dir=<path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
WORKER_DIR="/opt/nextcloud-saas-worker"
WORKER_JOBS_DIR="${WORKER_JOBS_DIR:-/opt/nextcloud-customers/jobs}"
SCRIPTS_INSTALL_DIR="/opt/nextcloud-customers/scripts"
SHARED_DIR="/opt/shared-services"

# Parse args
for _arg in "$@"; do
    case "$_arg" in
        --repo-dir=*) REPO_DIR="${_arg#--repo-dir=}" ;;
    esac
done

# ============================================================
# Helpers de log
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# Verificar root
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
    log_error "Execute como root: sudo $0"
    exit 1
fi

log_info "Configurando worker daemon nextcloud-saas..."

# ============================================================
# 1. Criar diretórios necessários
# ============================================================
mkdir -p "${WORKER_DIR}"
chmod 0750 "${WORKER_DIR}"
mkdir -p "${WORKER_JOBS_DIR}"
chmod 0750 "${WORKER_JOBS_DIR}"
mkdir -p "${SCRIPTS_INSTALL_DIR}/lib"
log_success "Diretórios criados: ${WORKER_DIR}, ${WORKER_JOBS_DIR}, ${SCRIPTS_INSTALL_DIR}/lib"

# ============================================================
# 2. Instalar worker.sh + manage.sh + libs em /opt/nextcloud-customers/scripts/
#    (ExecStart no service aponta para este caminho; symlink resolve via readlink -f)
# ============================================================
if [ -f "${REPO_DIR}/scripts/worker.sh" ]; then
    install -m 0750 -o root -g root \
        "${REPO_DIR}/scripts/worker.sh" \
        "${SCRIPTS_INSTALL_DIR}/worker.sh"
    log_success "worker.sh instalado: ${SCRIPTS_INSTALL_DIR}/worker.sh"
else
    log_error "${REPO_DIR}/scripts/worker.sh não encontrado"
    exit 1
fi

if [ -f "${REPO_DIR}/scripts/manage.sh" ]; then
    install -m 0755 -o root -g root \
        "${REPO_DIR}/scripts/manage.sh" \
        "${SCRIPTS_INSTALL_DIR}/manage.sh"
    # Symlink: nextcloud-manage → scripts/manage.sh (readlink -f resolve correto)
    ln -sf "${SCRIPTS_INSTALL_DIR}/manage.sh" /usr/local/bin/nextcloud-manage
    log_success "manage.sh instalado: ${SCRIPTS_INSTALL_DIR}/manage.sh"
    log_success "symlink /usr/local/bin/nextcloud-manage → ${SCRIPTS_INSTALL_DIR}/manage.sh"
else
    log_warning "${REPO_DIR}/scripts/manage.sh não encontrado — symlink não atualizado"
fi

if [ -d "${REPO_DIR}/scripts/lib" ]; then
    for _lib in "${REPO_DIR}/scripts/lib"/*.sh; do
        install -m 0640 -o root -g root "$_lib" "${SCRIPTS_INSTALL_DIR}/lib/"
    done
    log_success "Libs instaladas em ${SCRIPTS_INSTALL_DIR}/lib/"
else
    log_error "${REPO_DIR}/scripts/lib/ não encontrado"
    exit 1
fi

# ============================================================
# 3. Instalar systemd service unit
# ============================================================
if [ -f "${REPO_DIR}/systemd/nextcloud-saas-worker.service" ]; then
    install -m 0644 -o root -g root \
        "${REPO_DIR}/systemd/nextcloud-saas-worker.service" \
        /etc/systemd/system/nextcloud-saas-worker.service
    log_success "nextcloud-saas-worker.service instalado"
fi

# ============================================================
# 4. Criar worker.env em /opt/nextcloud-saas-worker/.env
#    (EnvironmentFile no service aponta para este caminho)
# ============================================================
WORKER_ENV="${WORKER_DIR}/.env"
if [ ! -f "${WORKER_ENV}" ]; then
    if [ -f "${REPO_DIR}/systemd/nextcloud-saas-worker.env.example" ]; then
        install -m 0600 -o root -g root \
            "${REPO_DIR}/systemd/nextcloud-saas-worker.env.example" \
            "${WORKER_ENV}"
        log_success "worker.env criado: ${WORKER_ENV}"
    fi
else
    log_warning "worker.env já existe — preservando customizações"
fi

# Injetar WORKER_REDIS_PASS do shared-services/.env (fonte única da senha)
if [ -f "${SHARED_DIR}/.env" ]; then
    _redis_pass="$(grep -m1 '^REDIS_PASSWORD=' "${SHARED_DIR}/.env" | cut -d= -f2- | tr -d '"')"
    if [ -n "${_redis_pass}" ]; then
        if grep -q '^WORKER_REDIS_PASS=' "${WORKER_ENV}" 2>/dev/null; then
            sed -i "s|^WORKER_REDIS_PASS=.*|WORKER_REDIS_PASS=${_redis_pass}|" "${WORKER_ENV}"
        else
            echo "WORKER_REDIS_PASS=${_redis_pass}" >> "${WORKER_ENV}"
        fi
        log_success "WORKER_REDIS_PASS injetado no worker.env"
    fi
fi

# ============================================================
# 5. Gerar worker_callback_secret se não existir
# ============================================================
mkdir -p "${SHARED_DIR}/secrets"
CALLBACK_SECRET_FILE="${SHARED_DIR}/secrets/worker_callback_secret"
if [ ! -f "${CALLBACK_SECRET_FILE}" ]; then
    openssl rand -hex 32 > "${CALLBACK_SECRET_FILE}"
    chmod 0600 "${CALLBACK_SECRET_FILE}"
    log_success "worker_callback_secret gerado: ${CALLBACK_SECRET_FILE}"
else
    log_warning "worker_callback_secret já existe — preservando"
fi

# ============================================================
# 6. Instalar jobs GC timer + service
# ============================================================
if [ -f "${REPO_DIR}/systemd/nextcloud-saas-jobs-gc.timer" ]; then
    install -m 0644 -o root -g root \
        "${REPO_DIR}/systemd/nextcloud-saas-jobs-gc.timer" \
        /etc/systemd/system/nextcloud-saas-jobs-gc.timer
    install -m 0644 -o root -g root \
        "${REPO_DIR}/systemd/nextcloud-saas-jobs-gc.service" \
        /etc/systemd/system/nextcloud-saas-jobs-gc.service
    log_success "jobs-gc.timer instalado"
fi

# ============================================================
# 7. Habilitar AOF no shared-redis (idempotente)
# ============================================================
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q shared-redis; then
    log_info "Habilitando AOF no shared-redis..."
    if docker exec -e REDISCLI_AUTH="${_redis_pass:-}" shared-redis \
           redis-cli CONFIG SET appendonly yes >/dev/null 2>&1 && \
       docker exec -e REDISCLI_AUTH="${_redis_pass:-}" shared-redis \
           redis-cli CONFIG SET appendfsync everysec >/dev/null 2>&1; then
        docker exec -e REDISCLI_AUTH="${_redis_pass:-}" shared-redis \
            redis-cli CONFIG REWRITE >/dev/null 2>&1 || true
        log_success "AOF habilitado"
    else
        log_warning "CONFIG SET AOF falhou — verificar manualmente"
    fi
else
    log_warning "shared-redis não está em execução"
fi

# ============================================================
# 8. Habilitar e recarregar units
# ============================================================
systemctl daemon-reload
systemctl enable nextcloud-saas-worker.service 2>/dev/null || true
systemctl enable nextcloud-saas-jobs-gc.timer 2>/dev/null || true
log_success "Units habilitadas via systemctl"

echo ""
log_success "Worker daemon configurado com sucesso!"
echo ""
echo "  Para iniciar:  systemctl start nextcloud-saas-worker"
echo "  Para status:   systemctl status nextcloud-saas-worker"
echo "  Para logs:     journalctl -fu nextcloud-saas-worker"
echo "  Env file:      ${WORKER_ENV}"
echo "  Jobs dir:      ${WORKER_JOBS_DIR}"
echo "  Callback sec:  ${CALLBACK_SECRET_FILE}"
echo ""
