#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Prueba de punta a punta del servicio de recomendaciones (pila completa local)
# =============================================================================
# Uso, con la pila arriba (docker compose up -d --build) y todo (healthy):
#   ./e2e/recommendation-flow.sh
#
# Recorre lo que cruza los servicios con una recomendacion: una semana de lecturas de un modulo,
# guardadas directo en la tabla de mediciones (una por hora, con mucho consumo de 18 a 22 h y 60 W
# de madrugada) -> el servicio de recomendaciones, recreado para que evalue a los 10 s, lee los
# dispositivos que reportan y su energia por hora del servicio de mediciones, los dispositivos y el
# limite de hogares y dispositivos, y guarda las de horas pico (PEAK_HOURS) y consumo en espera
# (SAVING) -> las anuncia por su outbox (recommendation.created) -> notificaciones las recibe.
# Tambien la API de recomendaciones por el gateway (leer, borrar) y que las colas queden vacias.
#
# Crea una cuenta (MAIL_USERNAME+e2e-...) y un hogar de prueba; al final borra las lecturas
# sembradas y el hogar, y deja el servicio con su espera normal (PT2M).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost/api/v1}"
compose=(docker compose --project-directory "$here")

command -v jq >/dev/null || { echo "Falta jq (Windows: winget install jqlang.jq)"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  OK    %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FALLA %s\n' "$*"; }
check() { local name="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then ok "$name ($got)"; else bad "$name: esperado $expected, llego $got"; fi; }

# Espera hasta N s (60 por defecto) a que el comando imprima el valor esperado.
eventually() { local name="$1" expected="$2"; shift 2; local got=""
  for _ in $(seq 1 "${WAIT:-60}"); do got="$("$@" 2>/dev/null || true)"; [[ "$got" == "$expected" ]] && break; sleep 1; done
  check "$name" "$expected" "$got"; }

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
auth=()
get()  { curl -fsS "${auth[@]}" "$API$1"; }

mysql_q() {
  "${compose[@]}" exec -T -e MYSQL_PWD="$(grep '^MYSQL_PASSWORD=' "$here/.env" | cut -d= -f2-)" mysql \
    mysql -N -B -uenergy_app energy_monitor -e "$1"; }

# El código que el servicio de seguridad manda por correo, calculado como él lo hace
# (EmailVerificationService): HMAC-SHA256 con el pepper sobre el id que reserva la solicitud de
# registro, la dirección y la ventana de 15 minutos, reducido a seis dígitos.
verification_code() { # email
  local email="${1,,}" id pepper digest
  id="$(mysql_q "SELECT id_user FROM pending_registration WHERE email = '$email'")"
  pepper="$(grep '^SECURITY_RESET_PEPPER=' "$here/.env" | cut -d= -f2-)"
  digest="$(printf '%s' "$id:email-verification:$email:$(( $(date +%s) / 900 ))" \
    | openssl dgst -sha256 -hmac "$pepper" -r | cut -c1-12)"
  printf '%06d' $(( 16#$digest % 1000000 )); }

rabbit_queue() { # nombre -> mensajes en la cola (vacio si la cola no existe)
  "${compose[@]}" exec -T rabbitmq rabbitmqctl list_queues -q name messages 2>/dev/null | awk -v q="$1" '$1 == q {print $2}'; }

# Recrea el contenedor con la primera evaluacion a $1 de arrancar.
recreate() { RECOMMENDATION_INITIAL_DELAY="$1" "${compose[@]}" up -d --no-deps --force-recreate recommendation >/dev/null 2>&1; }

health() { docker inspect -f '{{.State.Health.Status}}' energy-monitor-recommendation; }

listed() { # tipo -> recomendaciones de ese tipo en el hogar
  get "/recommendations?homeId=$home" | jq -r "[.[] | select(.type == \"$1\")] | length"; }

echo "1. Servicio de recomendaciones y su ruta en el gateway"
eventually "contenedor recommendation sano" healthy health
check "/api/v1/recommendations sin token" 401 "$(status "$API/recommendations?homeId=X")"
# El backend retirado tambien evaluaba: con los dos, la misma recomendacion se guardaria dos veces.
backend="$(docker ps -q -f name='^energy-monitor-backend$')"
check "el backend retirado no corre" "" "$backend"

echo "2. Cuenta y hogar"
# El registro exige un dominio que reciba correo (example.com no lo recibe). Se usa la cuenta de
# correo del proyecto con un sufijo "+e2e-...": el código de verificación llega a su propio buzón.
mail_user="$(grep '^MAIL_USERNAME=' "$here/.env" | cut -d= -f2-)"
[[ "$mail_user" == *@* ]] || { echo "Falta MAIL_USERNAME en .env (la prueba registra una cuenta con ese dominio)"; exit 1; }
email="${mail_user%@*}+e2e-recommendation-$(date +%s)@${mail_user#*@}"; password='E2e-Pass-2026!'
check "registro (security): solicitud aceptada" 202 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\",\"name\":\"E2E\",\"lastName\":\"Recommendation\",\"acceptTerms\":true}" "$API/auth/register")"
check "verificar el correo crea la cuenta" 200 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"code\":\"$(verification_code "$email")\"}" "$API/auth/email/verify")"
token="$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$API/auth/login" | jq -r .accessToken)"
auth=(-H "Authorization: Bearer $token")
home_type="$(get /home-types | jq -r '.[0].idHomeType')"
home="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"Casa E2E recomendaciones\",\"homeTypeId\":\"$home_type\",\"address\":\"Calle 1\"}" "$API/homes" | jq -r .idHome)"
[[ -n "$home" && "$home" != null ]] && ok "hogar creado (home) $home" || bad "hogar no creado"
check "un hogar ajeno no muestra recomendaciones" 404 "$(status "${auth[@]}" "$API/recommendations?homeId=OTRO000001")"
check "un hogar nuevo no tiene recomendaciones" 0 "$(get "/recommendations?homeId=$home" | jq length)"

echo "3. Vincular un modulo (un televisor: la nevera no cuenta para el consumo en espera)"
appliance="$(get /appliance-types | jq -r '[.[] | select(.name == "television")][0].idApplianceType')"
code="R$(openssl rand -hex 3 | tr 'a-f' 'A-F' | cut -c1-5)"
device="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"deviceCode\":\"$code\",\"name\":\"TV E2E\",\"applianceTypeId\":\"$appliance\",\"location\":\"Sala\"}" \
  "$API/homes/$home/devices" | jq -r .device.idDevice)"
[[ -n "$device" && "$device" != null ]] && ok "modulo vinculado $device ($code)" || bad "vinculacion fallida"

echo "4. Una semana de lecturas, una por hora"
# Hora local de Bogota (UTC-5). De 18 a 22 h 0,6 kWh por hora (600 W): mas del 40 % de la semana,
# horas pico. De 1 a 5 h 60 W, sobre los 15 W de espera, las tres ultimas noches. El resto 50 W.
# El contador (stored_energy) es acumulado, como lo manda el modulo.
prefix="E$(openssl rand -hex 2 | tr 'a-f' 'A-F')"
now_hour=$(( $(date +%s) / 3600 * 3600 ))
rows=(); energy=0
for n in $(seq 168 -1 1); do
  at=$(( now_hour - n * 3600 + 1800 ))
  local_hour=$(( ($(date -u -d "@$at" +%-H) + 19) % 24 ))
  if (( local_hour >= 18 && local_hour < 22 )); then power=600; kwh=600
  elif (( local_hour >= 1 && local_hour < 5 )); then power=60; kwh=60
  else power=50; kwh=50; fi
  energy=$(( energy + kwh ))
  rows+=("('$prefix$(printf '%05d' "$n")','$device','$(date -u -d "@$at" '+%F %T')',120.0,$(awk "BEGIN{print $power/120}"),$power,$(awk "BEGIN{print $energy/1000}"))")
done
mysql_q "INSERT INTO measurement (id_measurement, device_id, date_time, voltage, current, active_power, stored_energy)
  VALUES $(IFS=,; echo "${rows[*]}")"
check "lecturas sembradas (measurement)" 168 "$(mysql_q "SELECT COUNT(*) FROM measurement WHERE device_id='$device'")"

echo "5. La evaluacion guarda las recomendaciones y las anuncia"
recreate PT10S && ok "recommendation recreado con RECOMMENDATION_INITIAL_DELAY=PT10S" || bad "no se pudo recrear recommendation"
eventually "contenedor recommendation sano" healthy health
eventually "recomendacion PEAK_HOURS (recommendation)" 1 listed PEAK_HOURS
check "recomendacion SAVING del modulo" "$device" \
  "$(get "/recommendations?homeId=$home" | jq -r '[.[] | select(.type == "SAVING")][0].deviceId')"
check "con el nombre del modulo" "TV E2E" \
  "$(get "/recommendations?homeId=$home" | jq -r '[.[] | select(.type == "SAVING")][0].deviceName')"
check "nada mas: sin semana previa, sin historia del modulo ni limite" 2 "$(get "/recommendations?homeId=$home" | jq length)"
check "todas sin leer" UNREAD "$(get "/recommendations?homeId=$home" | jq -r '[.[].status] | unique | join(",")')"
eventually "recommendation.created publicado (recommendation_outbox)" 2 \
  mysql_q "SELECT COUNT(*) FROM recommendation_outbox WHERE message_type = 'recommendation.created' AND payload LIKE '%$home%' AND published_at IS NOT NULL"
eventually "notificaciones recibio las recomendaciones" 0 rabbit_queue notification-service.notification.recommendation-created
check "nada en su dead-letter" 0 "$(rabbit_queue notification-service.notification.recommendation-created.dlq)"

echo "6. Leer y borrar por la API (recommendation)"
peak="$(get "/recommendations?homeId=$home" | jq -r '[.[] | select(.type == "PEAK_HOURS")][0].idRecommendation')"
saving="$(get "/recommendations?homeId=$home" | jq -r '[.[] | select(.type == "SAVING")][0].idRecommendation')"
check "borrar una sin leer" 409 "$(status -X DELETE "${auth[@]}" "$API/recommendations/$peak")"
check "marcar como leida PEAK_HOURS" READ \
  "$(curl -fsS -X PUT "${auth[@]}" "$API/recommendations/$peak/read" | jq -r .status)"
check "borrar una leida" 204 "$(status -X DELETE "${auth[@]}" "$API/recommendations/$peak")"
check "la borrada ya no se lista" 0 "$(listed PEAK_HOURS)"
check "marcar como leida SAVING" READ \
  "$(curl -fsS -X PUT "${auth[@]}" "$API/recommendations/$saving/read" | jq -r .status)"
check "borrar las leidas del hogar" 1 \
  "$(curl -fsS -X DELETE "${auth[@]}" "$API/recommendations?homeId=$home" | jq -r .deleted)"
check "no queda ninguna recomendacion" 0 "$(get "/recommendations?homeId=$home" | jq length)"

echo "7. Limpieza"
mysql_q "DELETE FROM measurement WHERE device_id='$device'"
check "lecturas sembradas borradas" 0 "$(mysql_q "SELECT COUNT(*) FROM measurement WHERE device_id='$device'")"
check "hogar borrado (home)" 204 "$(status -X DELETE "${auth[@]}" "$API/homes/$home")"
recreate PT2M && ok "recommendation de vuelta con su espera normal (PT2M)" || bad "no se pudo recrear recommendation"

echo
echo "Resultado: $pass OK, $fail fallas (cuenta de prueba: $email)"
[[ $fail -eq 0 ]]
