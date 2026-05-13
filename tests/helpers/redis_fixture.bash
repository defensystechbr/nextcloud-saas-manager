#!/usr/bin/env bash
# tests/helpers/redis_fixture.bash — Sobe/derruba Redis 7-alpine para testes integration
# Carregado via: load 'helpers/redis_fixture'

# ============================================================
# start_redis_fixture
# Sobe redis:7-alpine em porta aleatória; espera PONG.
# Exporta: REDIS_HOST, REDIS_PORT, _REDIS_FIXTURE_CID
# ============================================================
start_redis_fixture() {
  # Reutilizar Redis do ambiente CI se já disponível
  if [[ -n "${WORKER_REDIS_HOST:-}" && "${WORKER_REDIS_HOST}" != "127.0.0.1" ]] || \
     { redis-cli -h "${WORKER_REDIS_HOST:-127.0.0.1}" -p "${WORKER_REDIS_PORT:-6379}" ping 2>/dev/null | grep -q PONG; }; then
    export REDIS_HOST="${WORKER_REDIS_HOST:-127.0.0.1}"
    export REDIS_PORT="${WORKER_REDIS_PORT:-6379}"
    export _REDIS_FIXTURE_CID=""
    # Limpar DB de teste
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "${WORKER_REDIS_DB:-16}" flushdb >/dev/null 2>&1 || true
    return 0
  fi

  # Subir container redis efêmero
  local cid
  cid=$(docker run -d --rm -p "0:6379" redis:7-alpine 2>/dev/null)
  if [[ -z "$cid" ]]; then
    echo "redis_fixture: falha ao subir redis:7-alpine" >&2
    return 1
  fi
  export _REDIS_FIXTURE_CID="$cid"

  # Descobrir porta alocada
  local port
  port=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "6379/tcp") 0).HostPort}}' "$cid" 2>/dev/null)
  if [[ -z "$port" ]]; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
    echo "redis_fixture: nao conseguiu descobrir porta do container" >&2
    return 1
  fi

  export REDIS_HOST="127.0.0.1"
  export REDIS_PORT="$port"

  # Aguardar PONG (até 15s)
  local i=0
  while ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG; do
    i=$((i + 1))
    if [[ $i -ge 30 ]]; then
      docker rm -f "$cid" >/dev/null 2>&1 || true
      echo "redis_fixture: timeout aguardando Redis PONG" >&2
      return 1
    fi
    sleep 0.5
  done
}

# ============================================================
# stop_redis_fixture
# Para o container iniciado por start_redis_fixture (se houver).
# ============================================================
stop_redis_fixture() {
  if [[ -n "${_REDIS_FIXTURE_CID:-}" ]]; then
    docker rm -f "${_REDIS_FIXTURE_CID}" >/dev/null 2>&1 || true
    unset _REDIS_FIXTURE_CID
  fi
  unset REDIS_HOST REDIS_PORT
}
