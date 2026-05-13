#!/usr/bin/env bash
# tests/install-deps.sh — Instala bats-support e bats-assert em tests/lib/
# Idempotente: skip se já existir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

install_lib() {
  local name="$1"
  local url="$2"
  local dest="${LIB_DIR}/${name}"

  if [[ -d "$dest" ]]; then
    echo "[skip] ${name} já instalado em ${dest}"
    return 0
  fi

  echo "[install] Clonando ${name}..."
  git clone --depth=1 "$url" "$dest"
  echo "[ok] ${name} instalado"
}

mkdir -p "$LIB_DIR"

install_lib "bats-support" "https://github.com/bats-core/bats-support.git"
install_lib "bats-assert"  "https://github.com/bats-core/bats-assert.git"

echo "Dependências instaladas em ${LIB_DIR}"
