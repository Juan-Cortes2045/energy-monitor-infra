#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Prueba de punta a punta del servicio de mediciones (pila completa local)
# =============================================================================
# Uso, con la pila arriba (docker compose up -d --build) y todo (healthy):
#   ./e2e/measurement-flow.sh
#
# Recorre lo que cruza los servicios con una lectura: el modulo publica telemetria -> el servicio
# de mediciones la guarda (una sola vez: el backend ya no se suscribe) y la anuncia por su outbox
# (measurement.recorded) -> el backend la oye y su alerta de umbral clasifica la lectura con los
# niveles del servicio -> una lectura baja la resuelve. Tambien el consumo del hogar y los niveles
# por el gateway, y que la cola del backend quede vacia.
#
# Crea una cuenta (MAIL_USERNAME+e2e-...) y un hogar de prueba; al final borra el hogar. No imprime
# la API key del modulo.
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
auth=()
get()  { curl -fsS "${auth[@]}" "$API$1"; }

mqtt_pub() { # usuario clave topic payload [extra]
  "${compose[@]}" exec -T mosquitto mosquitto_pub -h localhost -p 1883 -u "$1" -P "$2" -t "$3" -m "$4" "${@:5}"; }

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

rabbit_queue() { # nombre -> mensajes en la cola
  "${compose[@]}" exec -T rabbitmq rabbitmqctl list_queues -q name messages 2>/dev/null | awk -v q="$1" '$1 == q {print $2}'; }

reading() { # potencia contador
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mqtt_pub "$code" "$api_key" "$topic/telemetry" \
    "{\"deviceId\":\"$device\",\"dateTime\":\"$now\",\"voltage\":120.1,\"current\":1.2,\"activePower\":$1,\"storedEnergy\":$2,\"frequency\":60,\"powerFactor\":0.95,\"rssi\":-60,\"sequence\":1}"; }

pending_threshold() {
  curl -fsS -H "Authorization: Bearer $token" "$API/alerts?homeId=$home&status=PENDING" \
    | jq -r "[.[] | select(.deviceId == \"$device\" and .type == \"THRESHOLD\")] | length"; }

echo "1. Rutas del gateway hacia mediciones"
check "/api/v1/consumption-levels sin token" 401 "$(status "$API/consumption-levels")"
check "/api/v1/measurements sin token" 401 "$(status "$API/measurements?deviceId=X")"
check "/api/v1/homes/X/consumption/summary sin token" 401 "$(status "$API/homes/X/consumption/summary")"

echo "2. Cuenta y hogar"
# El registro exige un dominio que reciba correo (example.com no lo recibe). Se usa la cuenta de
# correo del proyecto con un sufijo "+e2e-...": el código de verificación llega a su propio buzón.
mail_user="$(grep '^MAIL_USERNAME=' "$here/.env" | cut -d= -f2-)"
[[ "$mail_user" == *@* ]] || { echo "Falta MAIL_USERNAME en .env (la prueba registra una cuenta con ese dominio)"; exit 1; }
email="${mail_user%@*}+e2e-$(date +%s)@${mail_user#*@}"; password='E2e-Pass-2026!'
check "registro (security): solicitud aceptada" 202 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\",\"name\":\"E2E\",\"lastName\":\"Measurement\",\"acceptTerms\":true}" "$API/auth/register")"
check "sin verificar el correo no hay sesión" 403 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$API/auth/login")"
check "sin verificar no hay cuenta en la base" 0 \
  "$(mysql_q "SELECT COUNT(*) FROM user WHERE email = '${email,,}'")"
# El código llega por correo; la prueba lo calcula como el servicio y lo verifica por la API, que es
# cuando se crea la cuenta.
check "verificar el correo crea la cuenta" 200 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"code\":\"$(verification_code "$email")\"}" "$API/auth/email/verify")"
check "la solicitud de registro ya no existe" 0 \
  "$(mysql_q "SELECT COUNT(*) FROM pending_registration WHERE email = '${email,,}'")"
token="$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$API/auth/login" | jq -r .accessToken)"
auth=(-H "Authorization: Bearer $token")
home_type="$(get /home-types | jq -r '.[0].idHomeType')"
home="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"Casa E2E mediciones\",\"homeTypeId\":\"$home_type\",\"address\":\"Calle 1\"}" "$API/homes" | jq -r .idHome)"
[[ -n "$home" && "$home" != null ]] && ok "hogar creado (backend) $home" || bad "hogar no creado"

echo "3. Vincular un modulo"
appliance="$(get /appliance-types | jq -r '.[0].idApplianceType')"
[[ -n "$appliance" && "$appliance" != null ]] && ok "catalogo de electrodomesticos (device)" || bad "catalogo vacio"
code="E$(openssl rand -hex 3 | tr 'a-f' 'A-F' | cut -c1-5)"
link="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"deviceCode\":\"$code\",\"name\":\"Horno E2E\",\"applianceTypeId\":\"$appliance\",\"location\":\"Cocina\"}" \
  "$API/homes/$home/devices")"
device="$(jq -r .device.idDevice <<<"$link")"; api_key="$(jq -r .apiKey <<<"$link")"
[[ -n "$device" && "$device" != null && -n "$api_key" ]] && ok "modulo vinculado $device ($code)" || bad "vinculacion fallida"
check "lista de dispositivos del hogar" "$device" "$(get "/homes/$home/devices" | jq -r '.[0].idDevice')"

topic="energy-monitor/devices/$device"

echo "4. Lectura alta: mediciones la guarda y el backend levanta la alerta de umbral"
reading 2000.0 1.0 && ok "telemetria aceptada por el broker" || bad "telemetria rechazada por el broker"
eventually "lectura guardada (mediciones)" 2000.0 bash -c "curl -fsS -H 'Authorization: Bearer $token' '$API/measurements/latest?deviceId=$device' | jq -r .activePower"
eventually "guardada una sola vez" 1 mysql_q "SELECT COUNT(*) FROM measurement WHERE device_id='$device'"
eventually "measurement.recorded publicado (outbox de mediciones)" 0 \
  mysql_q "SELECT COUNT(*) FROM measurement_outbox WHERE payload LIKE '%$device%' AND published_at IS NULL"
eventually "alerta THRESHOLD pendiente (backend)" 1 pending_threshold
latest="$(get "/measurements/latest?deviceId=$device" | jq -r .idMeasurement)"
check "la alerta apunta a la lectura" "$latest" \
  "$(get "/alerts?homeId=$home&status=PENDING" | jq -r "[.[] | select(.type == \"THRESHOLD\")][0].measurementId")"

echo "5. Lectura baja: el backend resuelve la alerta"
reading 200.0 1.1 && ok "telemetria baja aceptada" || bad "telemetria baja rechazada"
eventually "dos lecturas guardadas" 2 mysql_q "SELECT COUNT(*) FROM measurement WHERE device_id='$device'"
eventually "alerta THRESHOLD resuelta (backend)" 0 pending_threshold

echo "6. Consumo y niveles por el gateway (mediciones)"
check "niveles de consumo" 4 "$(get /consumption-levels | jq length)"
check "resumen del hogar con su modulo" "$device" \
  "$(get "/homes/$home/consumption/summary?zone=America/Bogota" | jq -r '.devices[0].deviceId')"
check "historial del hogar" 200 "$(status "${auth[@]}" "$API/homes/$home/consumption/history?period=day&zone=America/Bogota")"
check "estadisticas del modulo" 2 "$(get "/measurements/statistics?deviceId=$device" | jq -r .measurementCount)"
eventually "cola del backend vacia (energy-monitor-backend.measurement.recorded)" 0 \
  rabbit_queue energy-monitor-backend.measurement.recorded
check "nada en su dead-letter" 0 "$(rabbit_queue energy-monitor-backend.measurement.recorded.dlq)"

echo "7. Limpieza"
check "hogar borrado (backend)" 204 "$(status -X DELETE "${auth[@]}" "$API/homes/$home")"

echo
echo "Resultado: $pass OK, $fail fallas (cuenta de prueba: $email)"
[[ $fail -eq 0 ]]
