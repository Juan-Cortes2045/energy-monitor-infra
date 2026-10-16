#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Otorga el rol global ADMIN a una cuenta ya registrada.
# =============================================================================
# Uso:  ./make-admin.sh correo@ejemplo.com           pila local (.env)
#       ./make-admin.sh --prod correo@ejemplo.com    servidor (.env.prod, docker-compose.prod.yml)
#
# Requisitos: la pila debe estar levantada y la cuenta debe existir (haberla creado
# desde la web: registro con correo o "Iniciar sesion con Google"). No crea cuentas.
#
# Lee la contrasena de root de MySQL desde infra/.env o infra/.env.prod (MYSQL_ROOT_PASSWORD).
# Es idempotente: si la cuenta ya es ADMIN no falla ni duplica, y si el rol se le
# habia revocado desde la web (fila con deleted_at) lo reactiva.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
env_file="$here/.env"
compose=(docker compose --project-directory "$here" -f "$here/docker-compose.yml" --env-file "$env_file")
if [[ "${1:-}" == "--prod" ]]; then
  shift
  env_file="$here/.env.prod"
  compose=(docker compose --project-directory "$here" -f "$here/docker-compose.prod.yml" --env-file "$env_file")
fi
# El backend guarda los correos sin espacios y en minusculas.
email="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ -z "$email" ]]; then
  echo "Uso: ./make-admin.sh [--prod] correo@ejemplo.com" >&2
  exit 2
fi
# El correo va dentro del SQL: solo se aceptan los caracteres de una direccion normal.
if [[ ! "$email" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]+$ ]]; then
  echo "Correo no valido: '$email'" >&2
  exit 2
fi

root_pass="$(grep -E '^MYSQL_ROOT_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
if [[ -z "$root_pass" ]]; then
  echo "No encontre MYSQL_ROOT_PASSWORD en $env_file" >&2
  exit 1
fi

# Por nombre de servicio, no de contenedor: en el servidor el contenedor se llama distinto.
run_sql() { "${compose[@]}" exec -T -e MYSQL_PWD="$root_pass" mysql mysql -uroot energy_monitor "$@"; }

exists="$(run_sql -N -e "SELECT COUNT(*) FROM user WHERE email='$email' AND deleted_at IS NULL;")"
if [[ "$exists" = "0" ]]; then
  echo "No existe una cuenta activa con el correo '$email'." >&2
  echo "Crea la cuenta primero desde la web (registro o Google) y repite." >&2
  exit 1
fi

# Revocar el rol desde la web marca deleted_at en lugar de borrar la fila, asi que un
# INSERT IGNORE no lo devolveria: el duplicado se reactiva con ON DUPLICATE KEY.
run_sql -e "
INSERT INTO user_system_role (user_id, system_role_id, assigned_at)
SELECT u.id_user, sr.id_system_role, NOW()
FROM user u
JOIN system_role sr ON sr.name = 'ADMIN' AND sr.deleted_at IS NULL
WHERE u.email = '$email' AND u.deleted_at IS NULL
ON DUPLICATE KEY UPDATE
  assigned_at = IF(user_system_role.deleted_at IS NULL, user_system_role.assigned_at, NOW()),
  deleted_at = NULL;"

echo "Roles activos de '$email':"
run_sql -e "
SELECT u.email, sr.name AS rol
FROM user_system_role usr
JOIN user u ON u.id_user = usr.user_id
JOIN system_role sr ON sr.id_system_role = usr.system_role_id
WHERE u.email = '$email' AND usr.deleted_at IS NULL AND sr.deleted_at IS NULL;"

echo
echo "Cierra sesion y vuelve a entrar en la web para ver la pantalla de Administracion."
