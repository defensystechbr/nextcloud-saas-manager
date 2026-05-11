#!/bin/bash
# scripts/lib/backup_offsite.sh — Feature E: backup off-site com restic
# Source guard
[ "${BACKUP_OFFSITE_SH_SOURCED:-0}" = "1" ] && return 0
readonly BACKUP_OFFSITE_SH_SOURCED=1

set -euo pipefail

BACKUP_OFFSITE_SECRETS_DIR="${BACKUP_OFFSITE_SECRETS_DIR:-/opt/shared-services/secrets}"

# backup_offsite_read_secrets
# Lê /opt/shared-services/secrets/backup-{repo-url,repo-password,...}
# Exporta: RESTIC_REPOSITORY, RESTIC_PASSWORD + provider creds
# Exit 12 se backup-repo-url ou backup-repo-password ausentes
backup_offsite_read_secrets() {
  local secrets_dir="${BACKUP_OFFSITE_SECRETS_DIR}"
  local repo_url_file="${secrets_dir}/backup-repo-url"
  local repo_pass_file="${secrets_dir}/backup-repo-password"

  if [[ ! -f "$repo_url_file" ]] || [[ ! -s "$repo_url_file" ]]; then
    emit_error "backup_secrets_missing" "arquivo de secret nao encontrado: ${repo_url_file}" >&2
    return 12
  fi
  if [[ ! -f "$repo_pass_file" ]] || [[ ! -s "$repo_pass_file" ]]; then
    emit_error "backup_secrets_missing" "arquivo de secret nao encontrado: ${repo_pass_file}" >&2
    return 12
  fi

  export RESTIC_REPOSITORY
  RESTIC_REPOSITORY="$(cat "${repo_url_file}")"
  export RESTIC_PASSWORD
  RESTIC_PASSWORD="$(cat "${repo_pass_file}")"

  # AWS S3 (opcional)
  local aws_key_file="${secrets_dir}/backup-aws-key-id"
  local aws_secret_file="${secrets_dir}/backup-aws-secret-key"
  if [[ -f "$aws_key_file" && -s "$aws_key_file" ]]; then
    export AWS_ACCESS_KEY_ID
    AWS_ACCESS_KEY_ID="$(cat "${aws_key_file}")"
  fi
  if [[ -f "$aws_secret_file" && -s "$aws_secret_file" ]]; then
    export AWS_SECRET_ACCESS_KEY
    AWS_SECRET_ACCESS_KEY="$(cat "${aws_secret_file}")"
  fi

  # Backblaze B2 (opcional)
  local b2_account_file="${secrets_dir}/backup-b2-account-id"
  local b2_key_file="${secrets_dir}/backup-b2-account-key"
  if [[ -f "$b2_account_file" && -s "$b2_account_file" ]]; then
    export B2_ACCOUNT_ID
    B2_ACCOUNT_ID="$(cat "${b2_account_file}")"
  fi
  if [[ -f "$b2_key_file" && -s "$b2_key_file" ]]; then
    export B2_ACCOUNT_KEY
    B2_ACCOUNT_KEY="$(cat "${b2_key_file}")"
  fi
}

# backup_offsite_redact_url <url>
# Remove credenciais inline da URL para log seguro
backup_offsite_redact_url() {
  local url="${1:-${RESTIC_REPOSITORY:-}}"
  # s3://user:pass@host/path → s3://host/path
  # b2://id:key@bucket/path → b2://bucket/path
  echo "$url" | sed -E 's#^(s3://|b2://)[^:@/]+:[^@/]+@#\1#'
}

# backup_offsite_init_repo
# Inicializa repositório restic se ainda não existir (idempotente)
backup_offsite_init_repo() {
  if restic cat config --repo "${RESTIC_REPOSITORY}" >/dev/null 2>&1; then
    return 0  # já inicializado
  fi
  restic init --repo "${RESTIC_REPOSITORY}" >/dev/null 2>&1
}

# _backup_offsite_source_paths <client> <exclude_path>
# Coleta os paths de backup do cliente; popula array global BACKUP_SOURCE_PATHS.
# Retorna exit 12 se nenhum path existir (CQ-004: evita duplicação entre dry-run e backup real).
_backup_offsite_source_paths() {
  local client="${1:?_backup_offsite_source_paths: client obrigatorio}"
  local exclude_path="${2:?_backup_offsite_source_paths: exclude_path obrigatorio}"
  local base_dir="${BASE_DIR:-/opt/nextcloud-customers}"

  BACKUP_SOURCE_PATHS=()
  [[ -d "${base_dir}/${client}/data" ]]   && BACKUP_SOURCE_PATHS+=("${base_dir}/${client}/data")
  [[ -d "${base_dir}/${client}/config" ]] && BACKUP_SOURCE_PATHS+=("${base_dir}/${client}/config")

  if [[ ${#BACKUP_SOURCE_PATHS[@]} -eq 0 ]]; then
    emit_error "backup_no_paths" "nenhum path de backup encontrado para cliente '${client}'" >&2
    return 12
  fi
}

# backup_offsite_do_backup <client> <dry_run:0|1>
# Executa restic backup para os paths do cliente.
# stdout: JSON com snapshot_id, files_new, files_changed, data_added_bytes
backup_offsite_do_backup() {
  local client="${1:?backup_offsite_do_backup: client obrigatorio}"
  local dry_run="${2:-0}"
  local base_dir="${BASE_DIR:-/opt/nextcloud-customers}"
  local exclude_path="${base_dir}/${client}/backups"

  # CQ-004: caminho único para coleta de paths — sem duplicação entre dry-run e backup real
  local BACKUP_SOURCE_PATHS=()
  _backup_offsite_source_paths "$client" "$exclude_path" || return 12

  local restic_base_args=(backup --json --exclude "${exclude_path}" "${BACKUP_SOURCE_PATHS[@]}")

  if [[ "$dry_run" == "1" ]]; then
    # CQ-003: propagar exit code do restic no dry-run em vez de engolir com || true
    local dry_output dry_exit=0
    dry_output="$(restic "${restic_base_args[@]}" --dry-run 2>&1)" || dry_exit=$?
    if [[ $dry_exit -ne 0 ]]; then
      emit_error "backup_restic_failed" "restic dry-run falhou (exit ${dry_exit})" >&2
      return $dry_exit
    fi
    local files_would_add=0
    files_would_add="$(echo "$dry_output" | jq -r 'select(.message_type=="summary") | .files_new // 0' 2>/dev/null || echo 0)"
    emit_json result "dry_run" client "$client" \
      snapshot_id "" \
      files_new "@number:${files_would_add}" files_changed "@number:0" \
      data_added_bytes "@number:0" \
      repo_url_redacted "$(backup_offsite_redact_url "${RESTIC_REPOSITORY}")" \
      timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
  fi

  # Backup real — captura output JSON do restic
  local backup_output
  backup_output="$(restic "${restic_base_args[@]}" 2>/dev/null)"

  local snapshot_id files_new files_changed data_added_bytes
  snapshot_id="$(echo "$backup_output" | jq -r 'select(.message_type=="summary") | .snapshot_id // ""' 2>/dev/null || true)"
  files_new="$(echo "$backup_output" | jq -r 'select(.message_type=="summary") | .files_new // 0' 2>/dev/null || echo 0)"
  files_changed="$(echo "$backup_output" | jq -r 'select(.message_type=="summary") | .files_changed // 0' 2>/dev/null || echo 0)"
  data_added_bytes="$(echo "$backup_output" | jq -r 'select(.message_type=="summary") | .data_added // 0' 2>/dev/null || echo 0)"

  emit_json result "success" client "$client" \
    snapshot_id "${snapshot_id}" \
    files_new "@number:${files_new}" files_changed "@number:${files_changed}" \
    data_added_bytes "@number:${data_added_bytes}" \
    repo_url_redacted "$(backup_offsite_redact_url "${RESTIC_REPOSITORY}")" \
    timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# backup_offsite_prune
# Aplica política de retenção no repositório restic
backup_offsite_prune() {
  restic forget \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
    --prune --json >/dev/null 2>&1
}

# backup_offsite_verify
# Verifica integridade de amostra do repositório restic
backup_offsite_verify() {
  restic check --read-data-subset=10% >/dev/null 2>&1
}
