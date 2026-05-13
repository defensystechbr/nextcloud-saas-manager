#!/usr/bin/env bash
# tests/helpers/fake_restic.sh — Simula restic para testes unitários
# Variáveis de controle:
#   FAKE_RESTIC_FAIL=1    → qualquer subcomando retorna exit 1
#   FAKE_RESTIC_INIT_FAIL=1 → init retorna exit 1
#   FAKE_RESTIC_NO_CONFIG=1 → cat config retorna exit 1 (repo não inicializado)

set -euo pipefail

SUBCMD="${1:-}"
shift || true

if [[ "${FAKE_RESTIC_FAIL:-0}" == "1" ]]; then
  echo "Fatal: fake_restic forçado a falhar" >&2
  exit 1
fi

case "$SUBCMD" in
  init)
    if [[ "${FAKE_RESTIC_INIT_FAIL:-0}" == "1" ]]; then
      echo "Fatal: failed to create repository" >&2
      exit 1
    fi
    echo "created restic repository abc123 at ${RESTIC_REPOSITORY:-/tmp/fake-repo}"
    exit 0
    ;;
  cat)
    if [[ "${FAKE_RESTIC_NO_CONFIG:-0}" == "1" ]]; then
      echo "Fatal: unable to open config file" >&2
      exit 1
    fi
    echo '{"version":2}'
    exit 0
    ;;
  backup)
    # Verificar --dry-run
    if printf '%s\n' "$@" | grep -q -- '--dry-run'; then
      printf '{"message_type":"status","files_done":3,"bytes_done":1024}\n'
      printf '{"message_type":"summary","files_new":3,"files_changed":0,"data_added":1024}\n'
    else
      printf '{"message_type":"status","files_done":5,"bytes_done":4096}\n'
      printf '{"message_type":"summary","snapshot_id":"abc123fake","files_new":5,"files_changed":2,"data_added":4096,"data_added_packed":2048}\n'
    fi
    exit 0
    ;;
  forget)
    printf '{"keep":[{"id":"abc123fake"}],"remove":[]}\n'
    exit 0
    ;;
  check)
    echo "no errors were found"
    exit 0
    ;;
  *)
    echo "Fatal: unknown command ${SUBCMD}" >&2
    exit 1
    ;;
esac
