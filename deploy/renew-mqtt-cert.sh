#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Copia el certificado de Let's Encrypt del broker y reinicia Mosquitto
# =============================================================================
# Uso (una vez, y Certbot lo repite en cada renovacion):
#   sudo cp deploy/renew-mqtt-cert.sh /etc/letsencrypt/renewal-hooks/deploy/energy-monitor-mqtt.sh
#   sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/energy-monitor-mqtt.sh
#   sudo MQTT_DOMAIN=mqtt.DOMINIO /etc/letsencrypt/renewal-hooks/deploy/energy-monitor-mqtt.sh
#
# Mosquitto lee server.crt (fullchain) y server.key (privkey) de MQTT_CERT_DIR como uid 1000.
# Los valores por defecto coinciden con .env.prod.example; cambialos aqui si usas otros.
set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/energy-monitor/infra}"
MQTT_CERT_DIR="${MQTT_CERT_DIR:-/opt/energy-monitor/mqtt-certs}"
# En una renovacion Certbot entrega RENEWED_LINEAGE (/etc/letsencrypt/live/<dominio>).
MQTT_DOMAIN="${MQTT_DOMAIN:-}"
lineage="${RENEWED_LINEAGE:-/etc/letsencrypt/live/$MQTT_DOMAIN}"

# Certbot llama al hook por cada certificado renovado: solo actua con el del broker.
if [[ -z "$MQTT_DOMAIN" && "$(basename "$lineage")" != mqtt.* ]]; then
  exit 0
fi
if [[ ! -f "$lineage/fullchain.pem" ]]; then
  echo "No existe $lineage/fullchain.pem" >&2
  exit 1
fi

install -d -m 750 -o 1000 -g 1000 "$MQTT_CERT_DIR"
install -m 644 -o 1000 -g 1000 "$lineage/fullchain.pem" "$MQTT_CERT_DIR/server.crt"
install -m 600 -o 1000 -g 1000 "$lineage/privkey.pem" "$MQTT_CERT_DIR/server.key"

# Solo si la pila ya esta arriba (en la instalacion inicial todavia no lo esta).
if docker compose --project-directory "$INFRA_DIR" -f "$INFRA_DIR/docker-compose.prod.yml" \
    --env-file "$INFRA_DIR/.env.prod" ps --status running --services 2>/dev/null | grep -qx mosquitto; then
  docker compose --project-directory "$INFRA_DIR" -f "$INFRA_DIR/docker-compose.prod.yml" \
    --env-file "$INFRA_DIR/.env.prod" restart mosquitto
fi
echo "Certificado del broker actualizado en $MQTT_CERT_DIR"
