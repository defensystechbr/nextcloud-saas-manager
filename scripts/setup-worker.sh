#!/bin/bash
# scripts/setup-worker.sh — Instala o worker daemon e habilita AOF no Redis (D2.4)
# Invocado por deploy-server.sh ou manualmente após deploy inicial.
# Idempotente: pode ser executado múltiplas vezes sem efeitos adversos.
#
# Uso: sudo ./scripts/setup-worker.sh [--repo-dir=<path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
WORKER_JOBS_DIR="${WORKER_JOBS_DIR:-/opt/nextcloud-saas/jobs}"

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
# 1. Instalar worker.sh
# ============================================================
if [ -f "${REPO_DIR}/scripts/worker.sh" ]; then
    install -m 0750 -o root -g root \
        "${REPO_DIR}/scripts/worker.sh" \
        /usr/local/bin/nextcloud-saas-worker
    log_success "worker.sh instalado: /usr/local/bin/nextcloud-saas-worker"
else
    log_error "${REPO_DIR}/scripts/worker.sh não encontrado"
    exit 1
fi

# ============================================================
# 2. Instalar systemd service unit
# ============================================================
if [ -f "${REPO_DIR}/systemd/nextcloud-saas-worker.service" ]; then
    install -m 0644 -o root -g root \
        "${REPO_DIR}/systemd/nextcloud-saas-worker.service" \
        /etc/systemd/system/nextcloud-saas-worker.service
    log_success "nextcloud-saas-worker.service instalado"
fi

# ============================================================
# 3. Instalar env (apenas se não existir — preservar customizações)
# ============================================================
if [ -f "${REPO_DIR}/systemd/nextcloud-saas-worker.env.example" ]; then
    if [ ! -f "/etc/nextcloud-saas/worker.env" ]; then
        mkdir -p /etc/nextcloud-saas
        install -m 0640 -o root -g root \
            "${REPO_DIR}/systemd/nextcloud-saas-worker.env.example" \
            /etc/nextcloud-saas/worker.env
        log_success "worker.env criado em /etc/nextcloud-saas/worker.env"
        log_warning "EDITE /etc/nextcloud-saas/worker.env antes de iniciar o worker"
    else
        log_warning "worker.env já existe — preservando customizações"
    fi
fi

# ============================================================
# 4. Instalar jobs GC timer + service
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
# 5. Criar diretório de jobs
# ============================================================
mkdir -p "${WORKER_JOBS_DIR}"
chmod 0750 "${WORKER_JOBS_DIR}"
log_success "Diretório de jobs: ${WORKER_JOBS_DIR}"

# ============================================================
# 6. Habilitar AOF no shared-redis (idempotente)
# ============================================================
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q shared-redis; then
    log_info "Habilitando AOF no shared-redis..."
    if docker exec shared-redis redis-cli CONFIG SET appendonly yes >/dev/null 2>&1 && \
       docker exec shared-redis redis-cli CONFIG SET appendfsync everysec >/dev/null 2>&1; then
        docker exec shared-redis redis-cli CONFIG REWRITE >/dev/null 2>&1 || true
        log_success "AOF habilitado (appendonly yes, appendfsync everysec)"
    else
        log_warning "CONFIG SET AOF falhou — shared-redis pode não expor redis-cli"
    fi
else
    log_warning "shared-redis não está em execução — AOF será habilitado quando o Redis iniciar"
fi

# ============================================================
# 7. Habilitar e recarregar units
# ============================================================
systemctl daemon-reload
systemctl enable nextcloud-saas-worker.service 2>/dev/null || true
systemctl enable nextcloud-saas-jobs-gc.timer 2>/dev/null || true
log_success "Units habilitadas via systemctl"

echo ""
log_success "Worker daemon configurado com sucesso!"
echo ""
echo "  Para iniciar: systemctl start nextcloud-saas-worker"
echo "  Para status:  systemctl status nextcloud-saas-worker"
echo "  Env file:     /etc/nextcloud-saas/worker.env"
echo "  Jobs dir:     ${WORKER_JOBS_DIR}"
echo ""
