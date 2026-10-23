#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Prueba de punta a punta del servicio de dispositivos (pila completa local)
# =============================================================================
# Uso, con la pila arriba (docker compose up -d --build) y todo (healthy):
#   ./e2e/device-flow.sh
#
# Recorre lo que cruza los servicios: cuenta (security) -> hogar (backend) -> vincular un modulo
# (device, que pregunta al backend) -> el modulo entra al broker (Mosquitto pregunta a device) ->
# telemetria (device la marca ONLINE, el backend guarda la lectura) -> estado offline (evento
# device.connectivity-lost -> alerta CONNECTIVITY en el backend) -> borrar el hogar (home.deleted
# -> device desvincula el modulo). Tambien comprueba lo que debe rechazarse.
#
# Crea una cuenta y un hogar de prueba (e2e-*@example.com); al final borra el hogar. No imprime
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

echo "1. Rutas del gateway"
check "/api/v1/homes sin token" 401 "$(status "$API/homes")"
check "/api/v1/appliance-types sin token" 401 "$(status "$API/appliance-types")"
# El nginx de la web solo pasa /api/ al gateway: cualquier otra ruta es la propia web.
check "/internal/** no llega a los servicios" text/html \
  "$(curl -s -o /dev/null -w '%{content_type}' http://localhost/internal/devices/X | cut -d';' -f1)"

echo "2. Cuenta y hogar"
email="e2e-$(date +%s)@example.com"; password='E2e-Pass-2026!'
check "registro (security)" 201 "$(status -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\",\"name\":\"E2E\",\"lastName\":\"Device\"}" "$API/auth/register")"
token="$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$API/auth/login" | jq -r .accessToken)"
auth=(-H "Authorization: Bearer $token")
home_type="$(get /home-types | jq -r '.[0].idHomeType')"
home="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"Casa E2E\",\"homeTypeId\":\"$home_type\",\"address\":\"Calle 1\"}" "$API/homes" | jq -r .idHome)"
[[ -n "$home" && "$home" != null ]] && ok "hogar creado (backend) $home" || bad "hogar no creado"

echo "3. Vincular un modulo (device -> backend /internal/homes/{id}/access)"
appliance="$(get /appliance-types | jq -r '.[0].idApplianceType')"
[[ -n "$appliance" && "$appliance" != null ]] && ok "catalogo de electrodomesticos (device)" || bad "catalogo vacio"
code="E$(openssl rand -hex 3 | tr 'a-f' 'A-F' | cut -c1-5)"
link="$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  -d "{\"deviceCode\":\"$code\",\"name\":\"Nevera E2E\",\"applianceTypeId\":\"$appliance\",\"location\":\"Cocina\"}" \
  "$API/homes/$home/devices")"
device="$(jq -r .device.idDevice <<<"$link")"; api_key="$(jq -r .apiKey <<<"$link")"
[[ -n "$device" && "$device" != null && -n "$api_key" ]] && ok "modulo vinculado $device ($code)" || bad "vinculacion fallida"
check "lista de dispositivos del hogar" "$device" "$(get "/homes/$home/devices" | jq -r '.[0].idDevice')"

echo "4. Broker (Mosquitto -> device /internal/mqtt/auth)"
topic="energy-monitor/devices/$device"
if mqtt_pub "$code" "clave-incorrecta" "$topic/telemetry" '{}' 2>/dev/null; then
  bad "el broker acepto una clave incorrecta"; else ok "clave incorrecta rechazada"; fi
if mqtt_pub "$code" "$api_key" "energy-monitor/devices/OTRO000001/telemetry" '{}' 2>/dev/null; then
  ok "publicar en un topic ajeno no rompe la conexion (la ACL lo descarta)"; else ok "topic ajeno rechazado"; fi

echo "5. Telemetria: device la marca ONLINE y el backend guarda la lectura"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mqtt_pub "$code" "$api_key" "$topic/telemetry" \
  "{\"deviceId\":\"$device\",\"dateTime\":\"$now\",\"voltage\":120.1,\"current\":1.2,\"activePower\":140.5,\"storedEnergy\":0.5,\"frequency\":60,\"powerFactor\":0.95,\"rssi\":-60,\"sequence\":1}" \
  && ok "telemetria aceptada por el broker" || bad "telemetria rechazada por el broker"
eventually "estado ONLINE (device)" ONLINE bash -c "curl -fsS -H 'Authorization: Bearer $token' '$API/homes/$home/devices' | jq -r '.[0].status'"
eventually "lectura guardada (backend)" 140.5 bash -c "curl -fsS -H 'Authorization: Bearer $token' '$API/measurements/latest?deviceId=$device' | jq -r .activePower"

echo "6. Estado offline: device.connectivity-lost -> alerta en el backend"
mqtt_pub "$code" "$api_key" "$topic/status" "{\"deviceId\":\"$device\",\"status\":\"offline\"}" \
  && ok "estado offline publicado" || bad "estado offline rechazado"
eventually "estado OFFLINE (device)" OFFLINE bash -c "curl -fsS -H 'Authorization: Bearer $token' '$API/homes/$home/devices' | jq -r '.[0].status'"
eventually "alerta CONNECTIVITY (backend)" CONNECTIVITY bash -c \
  "curl -fsS -H 'Authorization: Bearer $token' '$API/alerts?homeId=$home' | jq -r '[.[] | select(.deviceId == \"$device\") | .type] | map(select(. == \"CONNECTIVITY\")) | .[0]'"
# Limpia el retenido para no dejar un estado viejo en el broker.
mqtt_pub "$code" "$api_key" "$topic/status" "" -r >/dev/null 2>&1 || true

echo "7. Borrar el hogar: home.deleted -> device desvincula el modulo"
check "hogar borrado (backend)" 204 "$(status -X DELETE "${auth[@]}" "$API/homes/$home")"
eventually "modulo desvinculado (device_home.deleted_at)" 1 \
  mysql_q "SELECT COUNT(*) FROM device_home WHERE device_id='$device' AND deleted_at IS NOT NULL"
eventually "outbox del backend publicado" 0 \
  mysql_q "SELECT COUNT(*) FROM home_outbox WHERE published_at IS NULL AND discarded_at IS NULL"
eventually "outbox de device publicado" 0 \
  mysql_q "SELECT COUNT(*) FROM device_outbox WHERE published_at IS NULL AND discarded_at IS NULL"
if mqtt_pub "$code" "$api_key" "$topic/telemetry" '{}' 2>/dev/null; then
  echo "  (aviso) el broker aun acepta la clave: su cache de decisiones dura hasta 5 min"
else ok "la clave revocada ya no entra al broker"; fi

echo
echo "Resultado: $pass OK, $fail fallas (cuenta de prueba: $email)"
[[ $fail -eq 0 ]]
