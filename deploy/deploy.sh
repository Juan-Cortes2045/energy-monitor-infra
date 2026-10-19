#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Despliegue de un componente en el servidor (lo llama GitHub Actions)
# =============================================================================
# Uso:   deploy.sh backend|frontend|infra
#
# GitHub Actions entra por SSH con una llave restringida en authorized_keys a este script:
#   command="/opt/energy-monitor/infra/deploy/deploy.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... github-actions
# El argumento llega en SSH_ORIGINAL_COMMAND y solo se aceptan los tres nombres de arriba:
# esa llave no sirve para abrir una consola ni para ejecutar otra cosa.
#
# Pasos: respaldo de MySQL, git pull de DEPLOY_BRANCH (main) en el repositorio del
# componente, reconstruccion solo de su servicio y prueba de salud. Si la prueba falla,
# vuelve a la version anterior y termina con error (el job de GitHub queda en rojo).
set -euo pipefail

EM="${EM:-/opt/energy-monitor}"
BRANCH="${DEPLOY_BRANCH:-main}"
HEALTH_TIMEOUT_S="${HEALTH_TIMEOUT_S:-300}"

# Con la llave restringida el argumento llega en SSH_ORIGINAL_COMMAND; a mano, como $1.
target="${1:-${SSH_ORIGINAL_COMMAND:-}}"
case "$target" in
  backend)  repo="$EM/backend/energy-monitor-backend"; service=backend ;;
  frontend) repo="$EM/frontend/energy-monitor-web";    service=frontend ;;
  infra)    repo="$EM/infra";                          service="" ;;
  *) echo "Uso: deploy.sh backend|frontend|infra (recibido: '$target')" >&2; exit 2 ;;
esac

compose=(docker compose --project-directory "$EM/infra" -f "$EM/infra/docker-compose.prod.yml"
         --env-file "$EM/infra/.env.prod")

# Un despliegue a la vez, aunque lleguen de dos repositorios al mismo tiempo.
exec 9>/var/lock/energy-monitor-deploy.lock
flock -w 900 9 || { echo "Otro despliegue sigue en curso" >&2; exit 1; }

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_S))
  while ((SECONDS < deadline)); do
    if curl -fsS http://127.0.0.1:8080/actuator/health 2>/dev/null | grep -q '"status":"UP"' &&
       [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/)" == 200 ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

apply() {
  if [[ -n "$service" ]]; then
    "${compose[@]}" up -d --build "$service"
  else
    # Cambios de infra (compose, mosquitto.conf): recrea lo que cambio de configuracion.
    "${compose[@]}" up -d --remove-orphans
    "${compose[@]}" up -d --force-recreate mosquitto
  fi
}

before="$(git -C "$repo" rev-parse HEAD)"
log "$target: version actual ${before:0:7}"

log "respaldo de MySQL"
"$EM/infra/deploy/backup-mysql.sh"

log "git pull de $BRANCH"
git -C "$repo" fetch --quiet origin "$BRANCH"
git -C "$repo" checkout --quiet "$BRANCH"
git -C "$repo" merge --ff-only --quiet "origin/$BRANCH"
after="$(git -C "$repo" rev-parse HEAD)"
log "$target: version nueva ${after:0:7}"

log "construyendo y arrancando"
apply

log "esperando la prueba de salud (hasta ${HEALTH_TIMEOUT_S}s)"
if healthy; then
  log "OK: $target desplegado en ${after:0:7}"
  exit 0
fi

log "FALLO la prueba de salud: volviendo a ${before:0:7}"
"${compose[@]}" logs --tail 80 "${service:-backend}" || true
git -C "$repo" checkout --quiet "$before"
apply
if healthy; then
  log "reversion completada: $target sigue en ${before:0:7} (el repositorio queda en esa version; el proximo despliegue vuelve a $BRANCH)"
else
  log "la reversion tampoco paso la prueba de salud: revisar a mano (emc ps, emc logs)"
fi
exit 1
