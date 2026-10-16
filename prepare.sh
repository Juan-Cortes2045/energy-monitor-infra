#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Prepara la pila local: claves RSA del backend y certificados
# de desarrollo del broker Mosquitto.
# =============================================================================
# Uso:  ./prepare.sh
#
# Crea:
#   infra/keys/private.pem, public.pem   par RSA de los JWT del backend
#   devices/docker/mosquitto/certs/*     CA y certificado de desarrollo del broker
#   devices/esp32-pzem-monitor/dev_ca.h  (lo escribe el script de certificados)
#
# Es idempotente: no regenera nada que ya exista (los dispositivos ya vinculados
# seguirian confiando en la misma CA).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
keys="$here/keys"
mkdir -p "$keys"

# ── 1. Par RSA de los JWT ───────────────────────────────────────────────────────
if [[ -f "$keys/private.pem" && -f "$keys/public.pem" ]]; then
  echo "El par RSA ya existe en $keys (no se regenera)."
else
  echo "Generando el par RSA de los JWT en $keys ..."
  openssl genpkey -algorithm RSA -out "$keys/private.pem" -pkeyopt rsa_keygen_bits:2048 2>/dev/null
  openssl rsa -in "$keys/private.pem" -pubout -out "$keys/public.pem" 2>/dev/null
  chmod 600 "$keys/private.pem"
  chmod 644 "$keys/public.pem"
fi

# ── 2. .env (se crea desde .env.example si falta) ───────────────────────────────
if [[ ! -f "$here/.env" ]]; then
  if [[ -f "$here/.env.example" ]]; then
    cp "$here/.env.example" "$here/.env"
    echo "Creado $here/.env desde .env.example: rellena los CHANGE_ME/vacios antes de arrancar."
  else
    echo "Aviso: no existe $here/.env ni .env.example." >&2
  fi
fi

# El backend corre con el uid/gid de BACKEND_UID/BACKEND_GID. Como las claves las
# genera tu usuario, apuntamos esos valores a tu uid/gid para que pueda leerlas.
if [[ -f "$here/.env" ]]; then
  uid="$(id -u)"; gid="$(id -g)"
  set_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$here/.env"; then
      sed -i "s/^${key}=.*/${key}=${value}/" "$here/.env"
    else
      printf '%s=%s\n' "$key" "$value" >> "$here/.env"
    fi
  }
  set_env BACKEND_UID "$uid"
  set_env BACKEND_GID "$gid"
  echo "BACKEND_UID/BACKEND_GID ajustados a $uid:$gid en .env."

  # Si el host aun no tiene IP de LAN configurada, dejamos una pista.
  if grep -q '^DEVICE_MQTT_PUBLIC_HOST=$' "$here/.env"; then
    echo "Recuerda: pon la IP de LAN de este PC en DEVICE_MQTT_PUBLIC_HOST (hostname -I)."
  fi
fi

# ── 3. Certificados de desarrollo del broker ────────────────────────────────────
echo "Generando los certificados de desarrollo del broker ..."
(cd "$here/../devices/docker/mosquitto" && ./generate-dev-certs.sh)

echo
echo "Listo. Siguientes pasos:"
echo "  1. Revisa $here/.env (contrasenas, pepper, DEVICE_MQTT_PUBLIC_HOST)."
echo "  2. cd $here && docker compose up -d --build"
