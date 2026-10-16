#!/usr/bin/env bash
# =============================================================================
# EnergyMonitor - Respaldo logico de MySQL en el servidor
# =============================================================================
# Uso:   ./deploy/backup-mysql.sh            (desde infra/)
# Cron:  0 3 * * * /opt/energy-monitor/infra/deploy/backup-mysql.sh >> /var/log/energy-monitor-backup.log 2>&1
#
# Deja energy_monitor-AAAAMMDD-HHMMSS.sql.gz en BACKUP_DIR (permisos 600) y borra los de
# mas de KEEP_DAYS dias. Un volumen de Docker no es un respaldo: este archivo si.
# Restaurar (sobrescribe la base):
#   gunzip -c <archivo>.sql.gz | docker compose -f docker-compose.prod.yml --env-file .env.prod \
#     exec -T -e MYSQL_PWD="<root>" mysql mysql -uroot energy_monitor
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/opt/energy-monitor/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
root_pass="$(grep -E '^MYSQL_ROOT_PASSWORD=' "$here/.env.prod" | cut -d= -f2-)"
[[ -n "$root_pass" ]] || { echo "Falta MYSQL_ROOT_PASSWORD en $here/.env.prod" >&2; exit 1; }

umask 077
mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/energy_monitor-$(date +%Y%m%d-%H%M%S).sql.gz"
docker compose --project-directory "$here" -f "$here/docker-compose.prod.yml" --env-file "$here/.env.prod" \
  exec -T -e MYSQL_PWD="$root_pass" mysql \
  mysqldump -uroot --single-transaction --routines --triggers --no-tablespaces energy_monitor \
  | gzip > "$out"
find "$BACKUP_DIR" -name 'energy_monitor-*.sql.gz' -mtime +"$KEEP_DAYS" -delete
echo "Respaldo: $out ($(du -h "$out" | cut -f1))"
