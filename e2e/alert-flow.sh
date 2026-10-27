#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Prueba de punta a punta del servicio de alertas (pila completa local)
# =============================================================================
# Uso, con la pila arriba (docker compose up -d --build), todo (healthy), el backend sin modulo de
# alertas y ALERT_CONSUMERS_ENABLED=true en .env:
#   ./e2e/alert-flow.sh
#
# Recorre lo que cruza los servicios con una alerta: el modulo publica telemetria -> mediciones la
# guarda y la anuncia (measurement.recorded) -> el servicio de alertas la oye en su cola, la
# clasifica con los niveles de mediciones y crea la alerta de umbral, una sola aunque la lectura se
# repita -> la anuncia por su outbox (alert.raised) -> notificaciones la recibe. Una lectura baja la
# resuelve. El estado offline del modulo crea la alerta de conectividad y la telemetria siguiente la
# resuelve. Tambien la API de alertas por el gateway (leer, borrar) y que las colas queden vacias.
#
# Crea una cuenta (MAIL_USERNAME+e2e-...) y un hogar de prueba; al final borra el hogar. No imprime
# la API key del modulo.
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

rabbit_queue() { # nombre -> mensajes en la cola (vacio si la cola no existe)
  "${compose[@]}" exec -T rabbitmq rabbitmqctl list_queues -q name messages 2>/dev/null | awk -v q="$1" '$1 == q {print $2}'; }

rabbit_consumers() { # nombre -> consumidores de la cola
  "${compose[@]}" exec -T rabbitmq rabbitmqctl list_queues -q name consumers 2>/dev/null | awk -v q="$1" '$1 == q {print $2}'; }

reading() { # potencia contador
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mqtt_pub "$code" "$api_key" "$topic/telemetry" \
    "{\"deviceId\":\"$device\",\"dateTime\":\"$now\",\"voltage\":120.1,\"current\":1.2,\"activePower\":$1,\"storedEnergy\":$2,\"frequency\":60,\"powerFactor\":0.95,\"rssi\":-60,\"sequence\":1}"; }

pending() { # tipo -> alertas pendientes de ese tipo del modulo
  curl -fsS -H "Authorization: Bearer $token" "$API/alerts?homeId=$home&status=PENDING" \
    | jq -r "[.[] | select(.deviceId == \"$device\" and .type == \"$1\")] | length"; }

echo "1. Servicio de alertas y su ruta en el gateway"
eventually "contenedor alert sano" healthy docker inspect -f '{{.State.Health.Status}}' energy-monitor-alert
check "/api/v1/alerts sin token" 401 "$(status "$API/alerts?homeId=X")"
check "consumidor en alert-service.measurement.recorded (ALERT_CONSUMERS_ENABLED)" 1 \
  "$(rabbit_consumers alert-service.measurement.recorded)"
check "consumidor en alert-service.device.events" 1 "$(rabbit_consumers alert-service.device.events)"
# La cola puede seguir en el broker hasta el paso 5 del corte (README, "Servicio de alertas"), pero
# el backend sin alertas ya no la consume: o no existe o no tiene consumidor.
backend_readings="$(rabbit_consumers energy-monitor-backend.measurement.recorded)"
check "el backend ya no consume las lecturas" 0 "${backend_readings:-0}"

echo "2. Cuenta y hogar"
# El registro exige un dominio que reciba correo (example.com no lo recibe). Se usa la cuenta de
# correo del proyecto con un sufijo "+e2e-...": el código de verificación llega a su propio buzón.
mail_user="$(grep '^MAIL_USERNAME=' "$here/.env" | cut -d= -f2-)"
[[ "$mail_user" == *@* ]] || { echo "Falta MAIL_USERNAME en .env (la prueba registra una cuenta con ese dominio)"; exit 1; }
email="${mail_user%@*}+e2e-alert-$(date +%s)@${mail_user#*@}"; password='E2e-Pass-2026!'
check "registro (security): solicitud aceptada" 202 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\",\"name\":\"E2E\",\"lastName\":\"Alert\",\"acceptTerms\":true}" "$API/auth/register")"
check "verificar el correo crea la cuenta" 200 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"code\":\"$(verification_code "$email")\"}" "$API/auth/email/verify")"
token="$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$API/auth/login" | jq -r .accessToken)"
auth=(-H "Authorization: Bearer $token")
home_type="$(get /home-types | jq -r '.[0].idHomeType')"
home="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"Casa E2E alertas\",\"homeTypeId\":\"$home_type\",\"address\":\"Calle 1\"}" "$API/homes" | jq -r .idHome)"
[[ -n "$home" && "$home" != null ]] && ok "hogar creado (home) $home" || bad "hogar no creado"
check "un hogar ajeno no muestra alertas" 404 "$(status "${auth[@]}" "$API/alerts?homeId=OTRO000001")"

echo "3. Vincular un modulo"
appliance="$(get /appliance-types | jq -r '.[0].idApplianceType')"
code="A$(openssl rand -hex 3 | tr 'a-f' 'A-F' | cut -c1-5)"
link="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"deviceCode\":\"$code\",\"name\":\"Horno E2E\",\"applianceTypeId\":\"$appliance\",\"location\":\"Cocina\"}" \
  "$API/homes/$home/devices")"
device="$(jq -r .device.idDevice <<<"$link")"; api_key="$(jq -r .apiKey <<<"$link")"
[[ -n "$device" && "$device" != null && -n "$api_key" ]] && ok "modulo vinculado $device ($code)" || bad "vinculacion fallida"
topic="energy-monitor/devices/$device"

echo "4. Lectura alta: el servicio de alertas crea la alerta de umbral y la anuncia"
reading 2000.0 1.0 && ok "telemetria aceptada por el broker" || bad "telemetria rechazada por el broker"
eventually "alerta THRESHOLD pendiente (alert)" 1 pending THRESHOLD
latest="$(get "/measurements/latest?deviceId=$device" | jq -r .idMeasurement)"
alert="$(get "/alerts?homeId=$home&status=PENDING" | jq -r "[.[] | select(.type == \"THRESHOLD\")][0].idAlert")"
check "la alerta apunta a la lectura" "$latest" "$(get "/alerts/$alert" | jq -r .measurementId)"
eventually "alert.raised publicado (alert_outbox)" 1 \
  mysql_q "SELECT COUNT(*) FROM alert_outbox WHERE message_type = 'alert.raised' AND payload LIKE '%$alert%' AND published_at IS NOT NULL"
eventually "notificaciones recibio la alerta" 0 rabbit_queue notification-service.notification.alert-raised
check "nada en su dead-letter" 0 "$(rabbit_queue notification-service.notification.alert-raised.dlq)"
eventually "la primera lectura avisa del modulo vinculado (alerta DEVICE)" 1 pending DEVICE

echo "5. La misma lectura otra vez no repite la alerta"
reading 2100.0 1.1 && ok "segunda lectura alta aceptada" || bad "segunda lectura rechazada"
eventually "dos lecturas guardadas" 2 mysql_q "SELECT COUNT(*) FROM measurement WHERE device_id='$device'"
eventually "cola del servicio vacia" 0 rabbit_queue alert-service.measurement.recorded
check "sigue una sola alerta THRESHOLD" 1 "$(pending THRESHOLD)"

echo "6. Lectura baja: la alerta se resuelve"
reading 200.0 1.2 && ok "telemetria baja aceptada" || bad "telemetria baja rechazada"
eventually "alerta THRESHOLD resuelta" 0 pending THRESHOLD
check "marcar como leida una alerta del sistema" 409 "$(status -X PUT "${auth[@]}" "$API/alerts/$alert/read")"

echo "7. Estado offline: alerta de conectividad; la telemetria siguiente la resuelve"
mqtt_pub "$code" "$api_key" "$topic/status" "{\"deviceId\":\"$device\",\"status\":\"offline\"}" \
  && ok "estado offline publicado" || bad "estado offline rechazado"
eventually "alerta CONNECTIVITY pendiente (alert)" 1 pending CONNECTIVITY
reading 150.0 1.3 && ok "telemetria de vuelta aceptada" || bad "telemetria de vuelta rechazada"
eventually "alerta CONNECTIVITY resuelta" 0 pending CONNECTIVITY
# Limpia el retenido para no dejar un estado viejo en el broker.
mqtt_pub "$code" "$api_key" "$topic/status" "" -r >/dev/null 2>&1 || true

echo "8. Leer y borrar por la API (alert)"
device_alert="$(get "/alerts?homeId=$home&status=PENDING" | jq -r "[.[] | select(.type == \"DEVICE\")][0].idAlert")"
check "marcar como leida la alerta DEVICE" RESOLVED \
  "$(curl -fsS -X PUT "${auth[@]}" "$API/alerts/$device_alert/read" | jq -r .alertStatus)"
check "borrar una alerta resuelta" 204 "$(status -X DELETE "${auth[@]}" "$API/alerts/$alert")"
check "la alerta borrada ya no se ve" 404 "$(status "${auth[@]}" "$API/alerts/$alert")"
check "borrar las resueltas del hogar" 2 \
  "$(curl -fsS -X DELETE "${auth[@]}" "$API/alerts?homeId=$home" | jq -r .deleted)"
check "no queda ninguna alerta" 0 "$(get "/alerts?homeId=$home" | jq length)"

echo "9. Colas"
eventually "alert-service.device.events vacia" 0 rabbit_queue alert-service.device.events
check "nada en las dead-letter del servicio" "0 0" \
  "$(rabbit_queue alert-service.measurement.recorded.dlq) $(rabbit_queue alert-service.device.events.dlq)"

echo "10. Limpieza"
check "hogar borrado (home)" 204 "$(status -X DELETE "${auth[@]}" "$API/homes/$home")"

echo
echo "Resultado: $pass OK, $fail fallas (cuenta de prueba: $email)"
[[ $fail -eq 0 ]]
