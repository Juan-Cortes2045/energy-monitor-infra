#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Otorga el rol global ADMIN a una cuenta ya registrada.
# =============================================================================
# Uso:  ./make-admin.sh correo@ejemplo.com
#
# Requisitos: la pila debe estar levantada y la cuenta debe existir (haberla creado
# desde la web: registro con correo o "Iniciar sesion con Google"). No crea cuentas.
#
# Lee la contrasena de root de MySQL desde infra/.env (MYSQL_ROOT_PASSWORD).
# Es idempotente: si la cuenta ya es ADMIN no falla ni duplica.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
email="${1:-}"
if [[ -z "$email" ]]; then
  echo "Uso: ./make-admin.sh correo@ejemplo.com" >&2
  exit 2
fi

root_pass="$(grep -E '^MYSQL_ROOT_PASSWORD=' "$here/.env" | cut -d= -f2-)"
if [[ -z "$root_pass" ]]; then
  echo "No encontre MYSQL_ROOT_PASSWORD en $here/.env" >&2
  exit 1
fi

run_sql() { docker exec -i -e MYSQL_PWD="$root_pass" energy-monitor-mysql mysql -uroot energy_monitor "$@"; }

exists="$(run_sql -N -e "SELECT COUNT(*) FROM user WHERE email='$email' AND deleted_at IS NULL;")"
if [[ "$exists" = "0" ]]; then
  echo "No existe una cuenta activa con el correo '$email'." >&2
  echo "Crea la cuenta primero en http://localhost (registro o Google) y repite." >&2
  exit 1
fi

run_sql -e "
INSERT IGNORE INTO user_system_role (user_id, system_role_id, assigned_at)
SELECT u.id_user, sr.id_system_role, NOW()
FROM user u
JOIN system_role sr ON sr.name = 'ADMIN' AND sr.deleted_at IS NULL
WHERE u.email = '$email' AND u.deleted_at IS NULL;"

echo "Roles de '$email' ahora:"
run_sql -e "
SELECT u.email, sr.name AS rol
FROM user_system_role usr
JOIN user u ON u.id_user = usr.user_id
JOIN system_role sr ON sr.id_system_role = usr.system_role_id
WHERE u.email = '$email';"

echo
echo "Cierra sesion y vuelve a entrar en la web para ver la pantalla de Administracion."
