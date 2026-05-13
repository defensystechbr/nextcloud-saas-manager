#!/bin/bash
# scripts/setup-ssh-gateway.sh — Instala o gateway SSH ncsaas-api (D2.5)
# Cria usuário ncsaas-api, instala shim, sshd configs e sudoers.
# Idempotente: pode ser executado múltiplas vezes.
#
# Uso: sudo ./scripts/setup-ssh-gateway.sh [--repo-dir=<path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

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

log_info "Configurando SSH gateway ncsaas-api..."

# ============================================================
# 1. Criar usuário ncsaas-api (idempotente)
# ============================================================
if ! getent passwd ncsaas-api >/dev/null 2>&1; then
    useradd -r -m -d /home/ncsaas-api -s /usr/sbin/nologin ncsaas-api
    log_success "Usuário ncsaas-api criado"
else
    log_warning "Usuário ncsaas-api já existe — preservando"
fi

# ============================================================
# 2. Configurar .ssh/
# ============================================================
mkdir -p /home/ncsaas-api/.ssh
chown ncsaas-api:ncsaas-api /home/ncsaas-api/.ssh
chmod 0700 /home/ncsaas-api/.ssh

if [ ! -f /home/ncsaas-api/.ssh/authorized_keys ]; then
    touch /home/ncsaas-api/.ssh/authorized_keys
    chown ncsaas-api:ncsaas-api /home/ncsaas-api/.ssh/authorized_keys
    chmod 0600 /home/ncsaas-api/.ssh/authorized_keys
    log_success "authorized_keys criado (vazio — adicione a chave pública)"
else
    log_warning "authorized_keys já existe — preservando"
fi

log_info "Formato da authorized_keys:"
log_info "  command=\"/usr/local/bin/ncsaas-api-shim\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-user-rc <ssh-ed25519 KEY> api-prod-$(date +%Y)"

# ============================================================
# 3. Instalar shim
# ============================================================
if [ -f "${REPO_DIR}/scripts/ncsaas-api-shim" ]; then
    install -m 0755 -o root -g root \
        "${REPO_DIR}/scripts/ncsaas-api-shim" \
        /usr/local/bin/ncsaas-api-shim
    log_success "ncsaas-api-shim instalado: /usr/local/bin/ncsaas-api-shim"
else
    log_error "${REPO_DIR}/scripts/ncsaas-api-shim não encontrado"
    exit 1
fi

# ============================================================
# 4. Instalar configurações sshd
# ============================================================
mkdir -p /etc/ssh/sshd_config.d

if [ -f "${REPO_DIR}/ssh/50-ncsaas-api.sshd.conf" ]; then
    install -m 0644 -o root -g root \
        "${REPO_DIR}/ssh/50-ncsaas-api.sshd.conf" \
        /etc/ssh/sshd_config.d/50-ncsaas-api.conf
    log_success "sshd_config.d/50-ncsaas-api.conf instalado"
fi

if [ -f "${REPO_DIR}/ssh/51-ncsaas-api-sftp.conf" ]; then
    install -m 0644 -o root -g root \
        "${REPO_DIR}/ssh/51-ncsaas-api-sftp.conf" \
        /etc/ssh/sshd_config.d/51-ncsaas-api-sftp.conf
    log_success "sshd_config.d/51-ncsaas-api-sftp.conf instalado (SFTP jail — ativo em D3)"
fi

# ============================================================
# 5. Instalar sudoers
# ============================================================
if [ -f "${REPO_DIR}/ssh/ncsaas-api.sudoers" ]; then
    if visudo -c -f "${REPO_DIR}/ssh/ncsaas-api.sudoers" >/dev/null 2>&1; then
        install -m 0440 -o root -g root \
            "${REPO_DIR}/ssh/ncsaas-api.sudoers" \
            /etc/sudoers.d/ncsaas-api
        log_success "sudoers ncsaas-api instalado"
    else
        log_error "sudoers inválido — não instalado"
        exit 1
    fi
fi

# ============================================================
# 6. Criar diretório inbox (D3 usa via SFTP staging)
# ============================================================
mkdir -p /opt/nextcloud-customers/inbox
chown ncsaas-api:ncsaas-api /opt/nextcloud-customers/inbox
chmod 0700 /opt/nextcloud-customers/inbox
log_success "Diretório inbox criado: /opt/nextcloud-customers/inbox"

# ============================================================
# 7. Instalar journald retention config (D2.6)
# ============================================================
mkdir -p /etc/systemd/journald.conf.d
if [ -f "${REPO_DIR}/journald.conf.d/50-nextcloud-saas.conf" ]; then
    install -m 0644 -o root -g root \
        "${REPO_DIR}/journald.conf.d/50-nextcloud-saas.conf" \
        /etc/systemd/journald.conf.d/50-nextcloud-saas.conf
    systemctl kill --signal=SIGUSR2 systemd-journald 2>/dev/null || true
    log_success "journald retention configurado (30d, 2G max)"
fi

# ============================================================
# 8. Validar e recarregar sshd
# ============================================================
if sshd -t >/dev/null 2>&1; then
    if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
        log_success "sshd recarregado com nova configuração"
    else
        log_warning "sshd reload falhou — reinicie manualmente: systemctl restart sshd"
    fi
else
    log_error "Configuração sshd inválida — NÃO recarregado"
    log_error "Verifique: /etc/ssh/sshd_config.d/50-ncsaas-api.conf"
    exit 1
fi

echo ""
log_success "SSH gateway ncsaas-api configurado com sucesso!"
echo ""
echo "  Próximos passos:"
echo "  1. Adicione a chave pública da API REST em:"
echo "     /home/ncsaas-api/.ssh/authorized_keys"
echo "  2. Teste: ssh -i <key> ncsaas-api@localhost nextcloud-manage list"
echo "  3. Kill-switch: usermod -L ncsaas-api"
echo ""
