#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Prueba de punta a punta de las notificaciones de actividad (pila completa local)
# =============================================================================
# Uso, con la pila arriba (docker compose up -d --build) y todo (healthy):
#   ./e2e/activity-flow.sh
#
# Tres cuentas (Ana, propietaria; Luis y Sara, miembros) recorren cada evento que el servicio de
# notificaciones cuenta a quien le concierne: bienvenida del primer ingreso (security), hogar creado,
# unirse, umbrales, dispositivo vinculado, salir, transferir el hogar, quitar a un miembro y borrar
# el hogar (home y device). Comprueba que cada uno llega a quien debe y no a quien no, la bandeja
# (filtro por hogar, marcar leídas, eliminar) y que se respetan los canales: Luis y Sara apagan el
# correo y el push, y no reciben ninguno.
#
# Crea tres cuentas (MAIL_USERNAME+e2e-...) y un hogar de prueba, que al final borra. Si el correo
# está configurado, Ana recibe en ese buzón el de cada actividad suya.
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
env_value() { grep "^$1=" "$here/.env" | cut -d= -f2-; }

mysql_q() {
  "${compose[@]}" exec -T -e MYSQL_PWD="$(env_value MYSQL_PASSWORD)" mysql \
    mysql -N -B -uenergy_app energy_monitor -e "$1"; }

# El código que el servicio de seguridad manda por correo, calculado como él lo hace (ver
# device-flow.sh).
verification_code() { # email
  local email="${1,,}" id pepper digest
  id="$(mysql_q "SELECT id_user FROM pending_registration WHERE email = '$email'")"
  pepper="$(env_value SECURITY_RESET_PEPPER)"
  digest="$(printf '%s' "$id:email-verification:$email:$(( $(date +%s) / 900 ))" \
    | openssl dgst -sha256 -hmac "$pepper" -r | cut -c1-12)"
  printf '%06d' $(( 16#$digest % 1000000 )); }

mail_user="$(env_value MAIL_USERNAME)"
[[ "$mail_user" == *@* ]] || { echo "Falta MAIL_USERNAME en .env (la prueba registra cuentas con ese dominio)"; exit 1; }
run_id="$(date +%s)"
password='E2e-Pass-2026!'

declare -A email token id
# Registra y verifica la cuenta, e inicia sesión: el primer ingreso es el que da la bienvenida.
account() { # clave nombre
  local key="$1" name="$2" login
  email[$key]="${mail_user%@*}+e2e-act-$key-$run_id@${mail_user#*@}"
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email[$key]}\",\"password\":\"$password\",\"name\":\"$name\",\"lastName\":\"E2E\",\"acceptTerms\":true}" "$API/auth/register"
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email[$key]}\",\"code\":\"$(verification_code "${email[$key]}")\"}" "$API/auth/email/verify"
  login="$(curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email[$key]}\",\"password\":\"$password\"}" "$API/auth/login")"
  token[$key]="$(jq -r .accessToken <<<"$login")"
  id[$key]="$(jq -r .account.idUser <<<"$login")"
  [[ -n "${token[$key]}" && "${token[$key]}" != null ]] && ok "cuenta $name ${id[$key]}" || bad "cuenta $name sin sesión"; }

as() { local key="$1"; shift; curl -fsS -H "Authorization: Bearer ${token[$key]}" "$@"; }
as_status() { local key="$1"; shift; status -H "Authorization: Bearer ${token[$key]}" "$@"; }

# Cuántas notificaciones de actividad de esa clave tiene la cuenta (del hogar, si se da).
activity_count() { # clave messageKey [homeId]
  as "$1" "$API/notifications/activity${3:+?homeId=$3}" \
    | jq --arg key "activity.$2.v1" '[.[] | select(.messageKey == $key)] | length'; }

expect_activity() { # clave messageKey cantidad [homeId]
  eventually "${1}: $2" "$3" activity_count "$1" "$2" "${4:-}"; }

echo "1. Bienvenida del primer ingreso (security: account.first-signed-in)"
account ana Ana
account luis Luis
account sara Sara
for key in ana luis sara; do expect_activity "$key" account.welcome 1; done
curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"${email[ana]}\",\"password\":\"$password\"}" "$API/auth/login"
sleep 3
check "un segundo ingreso no repite la bienvenida" 1 "$(activity_count ana account.welcome)"
check "la bienvenida no es de ningún hogar" null \
  "$(as ana "$API/notifications/activity" | jq -r '[.[] | select(.messageKey == "activity.account.welcome.v1")][0].homeId')"

echo "2. Canales: Luis y Sara apagan el correo y el push"
for key in luis sara; do
  check "$key: preferencias guardadas" false "$(as "$key" -X PUT -H 'Content-Type: application/json' \
    -d '{"emailEnabled":false,"pushEnabled":false}' "$API/notifications/preferences" | jq -r .emailEnabled)"
done

echo "3. Hogar creado y miembros que se unen (home.created, home.member-joined)"
home_type="$(as ana "$API/home-types" | jq -r '.[0].idHomeType')"
created="$(as ana -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"Casa Actividad E2E\",\"homeTypeId\":\"$home_type\",\"address\":\"Calle 1\"}" "$API/homes")"
home="$(jq -r .idHome <<<"$created")"; code="$(jq -r .accessCode <<<"$created")"
[[ -n "$home" && "$home" != null ]] && ok "hogar creado $home" || bad "hogar no creado"
expect_activity ana home.created 1 "$home"
check "luis se une" 201 "$(as_status luis -X POST -H 'Content-Type: application/json' -d "{\"accessCode\":\"$code\"}" "$API/homes/join")"
expect_activity luis home.joined 1 "$home"
expect_activity ana home.member-joined 1 "$home"
check "sara se une" 201 "$(as_status sara -X POST -H 'Content-Type: application/json' -d "{\"accessCode\":\"$code\"}" "$API/homes/join")"
expect_activity sara home.joined 1 "$home"
expect_activity ana home.member-joined 2 "$home"
expect_activity luis home.member-joined 1 "$home"
check "quién se unió va con su nombre" true \
  "$(as luis "$API/notifications/activity?homeId=$home" \
    | jq '[.[] | select(.messageKey == "activity.home.member-joined.v1")][0].params.actorName | test("Sara")')"
check "el nombre del hogar queda guardado" "Casa Actividad E2E" \
  "$(as luis "$API/notifications/activity?homeId=$home" | jq -r '.[0].params.homeName')"

echo "4. Umbrales (home.thresholds-updated): a los miembros, no a quien los cambió"
as ana -o /dev/null -X PUT -H 'Content-Type: application/json' \
  -d '{"limitPeriod":"MONTHLY","limit":150}' "$API/homes/$home/thresholds" && ok "umbral cambiado" || bad "umbral no cambiado"
expect_activity luis home.thresholds-updated 1 "$home"
expect_activity sara home.thresholds-updated 1 "$home"
check "ana: no se avisa a sí misma" 0 "$(activity_count ana home.thresholds-updated)"

echo "5. Dispositivo vinculado (device: device.linked)"
appliance="$(as ana "$API/appliance-types" | jq -r '.[0].idApplianceType')"
device_code="E$(openssl rand -hex 3 | tr 'a-f' 'A-F' | cut -c1-5)"
device="$(as ana -X POST -H 'Content-Type: application/json' \
  -d "{\"deviceCode\":\"$device_code\",\"name\":\"Nevera Actividad\",\"applianceTypeId\":\"$appliance\",\"location\":\"Cocina\"}" \
  "$API/homes/$home/devices" | jq -r .device.idDevice)"
[[ -n "$device" && "$device" != null ]] && ok "módulo vinculado $device" || bad "vinculación fallida"
for key in ana luis sara; do expect_activity "$key" device.linked 1 "$home"; done
check "el dispositivo va con su nombre" "Nevera Actividad" \
  "$(as sara "$API/notifications/activity?homeId=$home" \
    | jq -r '[.[] | select(.messageKey == "activity.device.linked.v1")][0].params.deviceName')"

echo "6. Un miembro sale (home.member-left)"
check "sara sale" 204 "$(as_status sara -X DELETE "$API/homes/$home/members/me")"
expect_activity ana home.member-left 1 "$home"
expect_activity luis home.member-left 1 "$home"

echo "7. Transferir el hogar (home.ownership-transferred)"
check "ana transfiere a luis" 204 "$(as_status ana -X PUT -H 'Content-Type: application/json' \
  -d "{\"newOwnerId\":\"${id[luis]}\"}" "$API/homes/$home/owner")"
expect_activity luis home.ownership-received 1 "$home"
expect_activity ana home.ownership-given 1 "$home"

echo "8. El propietario quita a un miembro (home.member-removed)"
check "luis quita a ana" 204 "$(as_status luis -X DELETE "$API/homes/$home/members/${id[ana]}")"
expect_activity ana home.removed-you 1 "$home"

echo "9. Borrar el hogar (home.deleted)"
check "sara vuelve a unirse" 201 "$(as_status sara -X POST -H 'Content-Type: application/json' -d "{\"accessCode\":\"$code\"}" "$API/homes/join")"
expect_activity sara home.joined 2 "$home"
check "luis borra el hogar" 204 "$(as_status luis -X DELETE "$API/homes/$home")"
expect_activity luis home.deleted-by-you 1 "$home"
expect_activity sara home.deleted 1 "$home"
check "ana ya no era miembro: no se le avisa" 0 "$(activity_count ana home.deleted)"

echo "10. Todo entregado: outboxes publicados y colas vacías"
# Antes de contar la bandeja: borrar el hogar también desvincula el módulo (device.unlinked), que
# llega después.
for outbox in security_outbox home_outbox device_outbox; do
  eventually "$outbox publicado" 0 \
    mysql_q "SELECT COUNT(*) FROM $outbox WHERE published_at IS NULL AND discarded_at IS NULL"
done
queue_depth() { "${compose[@]}" exec -T rabbitmq rabbitmqctl -q list_queues name messages \
  | awk -v q="$1" '$1 == q { print $2 }'; }
eventually "cola de actividad vacía" 0 queue_depth notification-service.notification.activity
check "ninguna en la cola de mensajes fallidos" 0 "$(queue_depth notification-service.notification.activity.dlq)"

echo "11. La bandeja: filtro por hogar, marcar leídas y eliminar"
total="$(as sara "$API/notifications/activity" | jq length)"
of_home="$(as sara "$API/notifications/activity?homeId=$home" | jq length)"
check "el filtro por hogar deja fuera la bienvenida" $((total - 1)) "$of_home"
first="$(as sara "$API/notifications/activity?homeId=$home" | jq -r '.[0].id')"
check "marcar una como leída" 204 "$(as_status sara -X PUT "$API/notifications/activity/$first/read")"
check "queda leída" true "$(as sara "$API/notifications/activity" | jq --arg id "$first" '.[] | select(.id == $id) | .read')"
check "marcar las del hogar" $((of_home - 1)) "$(as sara -X PUT "$API/notifications/activity/read?homeId=$home" | jq .read)"
check "la bienvenida sigue sin leer" false \
  "$(as sara "$API/notifications/activity" | jq '[.[] | select(.homeId == null)][0].read')"
check "eliminar una" 204 "$(as_status sara -X DELETE "$API/notifications/activity/$first")"
check "ya no aparece" 0 "$(as sara "$API/notifications/activity" | jq --arg id "$first" '[.[] | select(.id == $id)] | length')"
check "la de otra cuenta no se puede tocar" 404 "$(as_status ana -X DELETE "$API/notifications/activity/$first")"

echo "12. Canales: cada uno recibe por los que eligió"
# La bienvenida (ACCOUNT) pudo salir antes de que apagaran el correo: no se cuenta.
check "luis y sara sin correo ni push de su actividad" 0 "$(mysql_q "SELECT COUNT(*) FROM notification
  WHERE user_id IN ('${id[luis]}', '${id[sara]}') AND channel IN ('EMAIL', 'PUSH')
    AND source_type IN ('HOME', 'DEVICE')")"
check "pero sí en la bandeja de la app" true "$(as luis "$API/notifications/activity" | jq 'length > 1')"
if [[ -n "$(env_value MAIL_HOST)" ]]; then
  check "ana, con el correo encendido, la recibe por correo" true "$(mysql_q "SELECT COUNT(*) > 0 FROM notification
    WHERE user_id = '${id[ana]}' AND channel = 'EMAIL' AND source_type = 'HOME'" | sed 's/^1$/true/; s/^0$/false/')"
else
  echo "  (aviso) MAIL_HOST vacío en .env: no se comprueba el envío por correo"
fi

echo
echo "Resultado: $pass OK, $fail fallas (cuentas de prueba: ${email[ana]}, ${email[luis]}, ${email[sara]})"
[[ $fail -eq 0 ]]
