#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Prueba de punta a punta del borrado de una cuenta creada con Google
# =============================================================================
# Uso, con la pila arriba (docker compose up -d --build), todo (healthy) y
# SECURITY_ACCOUNT_DELETION_CODE_MAIL_ENABLED=true en .env:
#   ./e2e/account-deletion-flow.sh
#
# Recorre: cuenta (security) -> la marca como creada con Google -> no puede cambiar la contraseña
# (409) ni borrarse con ella -> pide el código (security escribe mail.account-deletion en su
# outbox) -> el servicio de notificaciones lo envía -> el código borra la cuenta.
#
# El inicio de sesión con Google necesita la ventana de Google, así que la prueba registra una
# cuenta con contraseña (MAIL_USERNAME+e2e-...) y le pone un google_subject en la base: para el
# servicio de seguridad eso es una cuenta creada con Google. Entra con esa contraseña solo para
# obtener el token. El correo con el código llega al buzón del proyecto.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost/api/v1}"
compose=(docker compose --project-directory "$here")

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  OK    %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FALLA %s\n' "$*"; }
check() { local name="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then ok "$name ($got)"; else bad "$name: esperado $expected, llego $got"; fi; }

# Espera hasta 30 s a que el comando imprima el valor esperado.
eventually() { local name="$1" expected="$2"; shift 2; local got=""
  for _ in $(seq 1 30); do got="$("$@" 2>/dev/null || true)"; [[ "$got" == "$expected" ]] && break; sleep 1; done
  check "$name" "$expected" "$got"; }

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

mysql_q() {
  "${compose[@]}" exec -T -e MYSQL_PWD="$(grep '^MYSQL_PASSWORD=' "$here/.env" | cut -d= -f2-)" mysql \
    mysql -N -B -uenergy_app energy_monitor -e "$1"; }

rabbit_queue() { # nombre -> mensajes en la cola
  "${compose[@]}" exec -T rabbitmq rabbitmqctl list_queues -q name messages 2>/dev/null | awk -v q="$1" '$1 == q {print $2}'; }

# Código de seis dígitos calculado como el servicio de seguridad: HMAC-SHA256 con el pepper sobre
# "<id>:<propósito><dirección>:<ventana de 15 minutos>".
derived_code() { # id propósito email
  local pepper digest
  pepper="$(grep '^SECURITY_RESET_PEPPER=' "$here/.env" | cut -d= -f2-)"
  digest="$(printf '%s' "$1:$2$3:$(( $(date +%s) / 900 ))" \
    | openssl dgst -sha256 -hmac "$pepper" -r | cut -c1-12)"
  printf '%06d' $(( 16#$digest % 1000000 )); }

grep -q '^SECURITY_ACCOUNT_DELETION_CODE_MAIL_ENABLED=true' "$here/.env" \
  || { echo "Pon SECURITY_ACCOUNT_DELETION_CODE_MAIL_ENABLED=true en .env y recrea security"; exit 1; }
mail_user="$(grep '^MAIL_USERNAME=' "$here/.env" | cut -d= -f2-)"
[[ "$mail_user" == *@* ]] || { echo "Falta MAIL_USERNAME en .env (la prueba registra una cuenta con ese dominio)"; exit 1; }
email="${mail_user%@*}+e2e-del-$(date +%s)@${mail_user#*@}"; email="${email,,}"; password='E2e-Pass-2026!'

echo "1. Cuenta"
check "registro (security)" 202 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\",\"name\":\"E2E\",\"lastName\":\"Borrado\",\"acceptTerms\":true}" "$API/auth/register")"
pending="$(mysql_q "SELECT id_user FROM pending_registration WHERE email = '$email'")"
check "verificar el correo crea la cuenta" 200 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"code\":\"$(derived_code "$pending" email-verification: "$email")\"}" "$API/auth/email/verify")"
id="$(mysql_q "SELECT id_user FROM user WHERE email = '$email' AND deleted_at IS NULL")"
mysql_q "UPDATE user SET google_subject = 'e2e-google-$id' WHERE id_user = '$id'"
token="$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$API/auth/login" | jq -r .accessToken)"
auth=(-H "Authorization: Bearer $token")
check "la cuenta se presenta como de Google" true "$(curl -fsS "${auth[@]}" "$API/auth/account" | jq -r .googleAccount)"

echo "2. Lo que una cuenta de Google no puede hacer"
check "cambiar la contraseña" 409 "$(status "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"currentPassword\":\"$password\",\"newPassword\":\"Otra-Pass-2026!\"}" "$API/auth/password/change")"
check "borrarse con la contraseña" 400 "$(status "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"password\":\"$password\"}" "$API/auth/account/delete")"

echo "3. Código por correo (security -> outbox -> notificaciones)"
check "pedir el código" 202 "$(status "${auth[@]}" -X POST "$API/auth/account/delete/code")"
eventually "mail.account-deletion publicado (outbox de security)" 0 \
  mysql_q "SELECT COUNT(*) FROM security_outbox WHERE message_type = 'mail.account-deletion' AND payload LIKE '%$id%' AND published_at IS NULL"
eventually "correo enviado (notificaciones)" SENT \
  mysql_q "SELECT delivery_status FROM notification WHERE user_id = '$id' AND message_key = 'security.account_deletion.v1' ORDER BY created_at DESC LIMIT 1"
check "nada en la dead-letter de correos" 0 "$(rabbit_queue notification-service.notification.mail.dlq)"

echo "4. Borrar con el código"
code="$(derived_code "$id" account-deletion: "$email")"
wrong=$([[ "$code" == 000000 ]] && echo 000001 || echo 000000)
check "un código equivocado no borra" 400 "$(status "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"code\":\"$wrong\"}" "$API/auth/account/delete")"
check "el código borra la cuenta" 204 "$(status "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"code\":\"$code\"}" "$API/auth/account/delete")"
check "cuenta borrada en la base" 1 "$(mysql_q "SELECT COUNT(*) FROM user WHERE id_user = '$id' AND deleted_at IS NOT NULL")"

echo
echo "Resultado: $pass OK, $fail fallas (cuenta de prueba: $email)"
[[ $fail -eq 0 ]]
