#!/bin/bash
# scripts/lib/feature_o_ext.sh — Feature O extended: create/remove com flags avancadas
#
# D3.5 — cmd_create_post_extended: --apps, --full-apps, --staging-id (branding)
# D3.6 — remove extended: --force, --backup-first, --confirm=<client>
#
# Source guard
[ "${FEATURE_O_EXT_SH_SOURCED:-0}" = "1" ] && return 0
readonly FEATURE_O_EXT_SH_SOURCED=1

set -euo pipefail

FEATURE_O_EXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dispatch.sh
source "${FEATURE_O_EXT_LIB_DIR}/dispatch.sh"
# shellcheck source=scripts/lib/job_queue.sh
source "${FEATURE_O_EXT_LIB_DIR}/job_queue.sh"
# shellcheck source=scripts/lib/output_json.sh
source "${FEATURE_O_EXT_LIB_DIR}/output_json.sh"

# ─────────────────────────────────────────────────────────────────────────────
# D3.5 — cmd_create_post_extended <client>
# Chamado INTERNAMENTE por cmd_create apos a criacao base quando ha flags extras.
# Processa: --apps, --full-apps, --staging-id (branding via SCP staging).
# ─────────────────────────────────────────────────────────────────────────────
cmd_create_post_extended() {
  local client="${1:?cmd_create_post_extended: client obrigatorio}"
  local container="${client}-app"

  local _container_running=false
  if docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q "^true$"; then
    _container_running=true
  fi

  # --apps=a,b,c: habilitar apps extras alem dos padrao
  local extra_apps="${PARSED_FLAGS[apps]:-}"
  if [[ -n "$extra_apps" ]]; then
    local app
    IFS=',' read -ra _extra_app_list <<< "$extra_apps"
    for app in "${_extra_app_list[@]}"; do
      app="${app// /}"
      [[ -z "$app" ]] && continue
      if [[ "$_container_running" == true ]]; then
        docker exec -u www-data "$container" php occ app:install "$app" 2>/dev/null || true
        docker exec -u www-data "$container" php occ app:enable  "$app" 2>/dev/null || true
      fi
    done
  fi

  # --full-apps: instalar conjunto completo de apps adicionais
  if [[ "${PARSED_FLAGS[full_apps]:-}" == "1" ]]; then
    local _full_list=(groupfolders deck forms notes tasks photos activity spreed app_api notify_push)
    local app
    for app in "${_full_list[@]}"; do
      if [[ "$_container_running" == true ]]; then
        docker exec -u www-data "$container" php occ app:install "$app" 2>/dev/null || true
        docker exec -u www-data "$container" php occ app:enable  "$app" 2>/dev/null || true
      fi
    done
  fi

  # --staging-id: aplicar branding do staging dir (logo, background)
  local staging_id="${PARSED_FLAGS[staging_id]:-}"
  if [[ -n "$staging_id" ]]; then
    local inbox_dir="${INBOX_BASE_DIR:-/opt/nextcloud-customers/inbox}"
    local staging_dir="${inbox_dir}/${staging_id}"
    if [[ -d "$staging_dir" ]]; then
      local logo_file bg_file
      logo_file="$(find "$staging_dir" -maxdepth 1 \( -name 'logo.*' \) -type f 2>/dev/null | head -1 || true)"
      bg_file="$(find  "$staging_dir" -maxdepth 1 \( -name 'background.*' \) -type f 2>/dev/null | head -1 || true)"
      if [[ -n "$logo_file" && "$_container_running" == true ]]; then
        docker cp "$logo_file" "${container}:/tmp/_branding_logo" 2>/dev/null || true
        docker exec -u www-data "$container" php occ theming:config logo /tmp/_branding_logo 2>/dev/null || true
      fi
      if [[ -n "$bg_file" && "$_container_running" == true ]]; then
        docker cp "$bg_file" "${container}:/tmp/_branding_bg" 2>/dev/null || true
        docker exec -u www-data "$container" php occ theming:config background /tmp/_branding_bg 2>/dev/null || true
      fi
      # Consumir staging: mover para jobs/<job_id>/staging/
      local job_id="${CURRENT_JOB_ID:-}"
      if [[ -n "$job_id" ]]; then
        inbox_staging_consume "$staging_id" "$job_id" "$inbox_dir" \
          "${WORKER_JOBS_DIR:-/opt/nextcloud-customers/jobs}" 2>/dev/null || true
      fi
    else
      echo "[WARN] staging dir nao encontrado: ${staging_dir}" >&2
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# D3.6 — _cmd_remove_validate_confirm <client>
# Valida --confirm=<client> ou --force para remocao assincrona.
# Retorna: 0=ok, 5=validacao falhou
# ─────────────────────────────────────────────────────────────────────────────
_cmd_remove_validate_confirm() {
  local client="$1"
  local confirm_val="${PARSED_FLAGS[confirm]:-}"
  local force="${PARSED_FLAGS[force]:-}"
  local is_async="${PARSED_FLAGS[async]:-}"
  local no_async_pickup="${PARSED_FLAGS[no_async_pickup]:-}"

  # No fluxo async ou worker (--no-async-pickup), confirmacao e obrigatoria
  if [[ "$is_async" == "1" || "$no_async_pickup" == "1" ]]; then
    if [[ -z "$force" && "$confirm_val" != "$client" ]]; then
      emit_error "confirm_required" \
        "remove async requer --confirm=${client} (ou --force) para confirmar remocao permanente"
      return 5
    fi
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# D3.6 — cmd_backup_then_remove_enqueue <client> <domain>
# Enfileira job composto: cmd=backup-then-remove (backup primeiro, depois remove).
# ─────────────────────────────────────────────────────────────────────────────
cmd_backup_then_remove_enqueue() {
  local client="$1"
  local domain="${2:-_}"

  local args_json
  args_json="$(printf '%s\n' \
    "nextcloud-manage" "$client" "$domain" "backup-then-remove" \
    | jq -Rc '[.,inputs]')"

  dispatch_enqueue "$client" "backup-then-remove" "$args_json"
}
