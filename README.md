# infra — Pila completa local en Docker

Levanta **todo** EnergyMonitor en contenedores sobre Docker, sin depender de un
servidor: base de datos MySQL, broker MQTT, backend Spring Boot y frontend React.

```
┌──────────────────────────────────────────────────────────────┐
│                    red Docker: energy-monitor                │
│                                                              │
│  frontend :80 ──/api/──► backend :8080 ──► mysql :3306       │
│                              ▲                               │
│                              │ /internal/mqtt/auth           │
│                          mosquitto :1883 / :8883 TLS         │
└──────────────────────────────────────────────────────────────┘
```

## Requisitos

- Docker Engine 24+ con el plugin `docker compose` (probado con Docker 29 / Compose v5).
- `openssl` (lo usa `prepare.sh`).

## Arranque rápido

```bash
cd infra
cp .env.example .env      # rellena los valores (o déjalo: prepare.sh lo crea)
./prepare.sh              # genera la clave RSA del backend y los certificados del broker
# edita .env: contraseñas, SECURITY_RESET_PEPPER, MQTT_BACKEND_PASS, DEVICE_MQTT_PUBLIC_HOST
# y (opcional) GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET + VITE_GOOGLE_CLIENT_ID
docker compose up -d --build
```

Luego abre <http://localhost>. El backend responde en <http://localhost:8080>,
Swagger en <http://localhost:8080/swagger-ui.html> y `health` en
<http://localhost:8080/actuator/health>.

## Cuentas: registro, primer administrador y Google

- **Crear una cuenta:** desde <http://localhost> (registro con correo y contraseña, o
  «Iniciar sesión con Google»). El registro **no** exige verificar el correo para entrar.
- **Primer administrador:** ninguna cuenta es administradora al instalar. Tras crear la
  cuenta, otórgale el rol global `ADMIN` con el script de la carpeta:

  ```bash
  ./make-admin.sh correo@ejemplo.com
  ```

  (Lee `MYSQL_ROOT_PASSWORD` de `.env` y es idempotente.) Cierra sesión y vuelve a entrar
  para ver la pantalla de **Administración**, desde donde ese admin ya puede dar `ADMIN` a
  otras cuentas.

- **Iniciar sesión con Google:** el cliente OAuth llega al backend por `GOOGLE_CLIENT_ID`
  y `GOOGLE_CLIENT_SECRET` (`.env`), y al navegador por `VITE_GOOGLE_CLIENT_ID` (build-arg
  del frontend). Si Google responde **`origin_mismatch`**, falta registrar el origen en
  Google Cloud Console → *APIs & Services → Credentials → (tu OAuth client, tipo Web
  application)* → **Authorized JavaScript origins**: añade `http://localhost` (y la URL de
  producción más adelante). Si la app está en modo *Testing*, agrega además la cuenta de
  Google en **Test users**. Sin ambos, Google bloquea el inicio de sesión.

## Imágenes

| Imagen | Origen | Notas |
|---|---|---|
| `energy-monitor-backend:local` | `../backend/energy-monitor-backend/Dockerfile` | Ya existía; multi-stage Maven + JRE 21, corre como uid 10001. |
| `energy-monitor-frontend:local` | `../frontend/energy-monitor-web/Dockerfile` | **Nuevo**: build con Vite y se sirve con nginx. |
| `mysql:8.4` | Docker Hub | Base de datos, con volumen `mysql-data`. |
| `iegomez/mosquitto-go-auth:3.0.0-mosquitto_2.0.18` | Docker Hub | Broker MQTT; autentica contra el backend. |

El frontend se construye con `VITE_API_BASE_URL` **vacío**, así que el navegador
llama a `/api/v1/...` en su propio origen y nginx lo reenvía a `backend:8080`
(mismo origen: **no hace falta CORS**).

## Integración MQTT (ya hecha en el código)

El código del backend ya trae la integración; esta pila solo conecta las piezas:

- El backend publica/consume telemetría y estado como un cliente MQTT más
  (`MQTT_BROKER_URL=tcp://mosquitto:1883`, listener interno sin TLS).
- El broker **no guarda usuarios**: por cada conexión pregunta al backend
  (`POST /internal/mqtt/auth/user`) y por cada publicación (`/acl`), cacheado 5 min.
  Por eso `mosquitto.conf` apunta a `auth_opt_http_host backend`, que aquí es el
  servicio `backend` de la red Docker.
- Los dispositivos ESP32 se conectan por **8883 TLS** con su `device_code`/`api_key`
  (guardada como hash SHA-256). Los certificados de desarrollo salen de
  `../devices/docker/mosquitto/generate-dev-certs.sh` (los genera `prepare.sh`).
- `DEVICE_MQTT_PUBLIC_HOST` es la IP de LAN que la web escribe al módulo al vincularlo
  por Bluetooth; debe ser alcanzable desde la Wi-Fi del hogar (nunca `localhost`).

El `mosquitto.conf` es **el mismo** que usa producción
(`devices/docker/mosquitto/mosquitto.conf`); lo único que cambia es qué resuelve el
nombre `backend` (aquí, el contenedor; en dev con backend en el host, `host-gateway`).

## Puertos publicados

| Puerto | Servicio | Para qué |
|---|---|---|
| 80 | frontend (nginx) | La web; reenvía `/api/` al backend. |
| 8080 | backend | REST `/api/v1` (abierto para depurar). |
| 8883 | mosquitto | MQTT sobre TLS, para los dispositivos. |
| 1883 | mosquitto | MQTT sin TLS, solo en `127.0.0.1`, para el backend. |
| 3306 | mysql | Base de datos (abierto para depurar). |

## Comandos útiles

```bash
docker compose logs -f backend        # ver el arranque del backend
docker compose ps                     # estado de los contenedores
docker compose down                   # parar (conserva los volúmenes)
docker compose down -v                # parar y borrar también datos y certificados
docker compose up -d --build backend  # reconstruir solo el backend
```

## Verificación

```bash
curl -s http://localhost:8080/actuator/health            # {"status":"UP",...}
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/          # 200 (web)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/v1/homes  # 401 si no hay sesión (el proxy funciona)
# MQTT: el backend ya está suscrito; confírmalo en el log del broker
docker compose logs mosquitto | grep "New client connected"          # ... u'em-backend'
```

Publicar telemetría de prueba requiere un dispositivo aprovisionado (su `device_code`/`api_key`)
o las credenciales del backend con ACL de publicación; el broker **no** acepta clientes anónimos.

## Solución de problemas

- **`ERROR 1045 ... Access denied for user 'root'@'localhost'`** al usar `docker exec ... mysql -u root -p`:
  la contraseña de `root` es la de `MYSQL_ROOT_PASSWORD` en `.env`. Usa la variable, no la escribas a mano:

  ```bash
  docker exec -e MYSQL_PWD="$(grep '^MYSQL_ROOT_PASSWORD=' .env | cut -d= -f2-)" \
    -it energy-monitor-mysql mysql -uroot energy_monitor
  ```

  El usuario de la aplicación es `energy_app` con `MYSQL_PASSWORD` (no `root`).

- **`origin_mismatch` al iniciar sesión con Google:** falta `http://localhost` en
  *Authorized JavaScript origins* del cliente OAuth (ver sección de cuentas arriba) y, en
  modo *Testing*, la cuenta en *Test users*.

- **El frontend repite `401` en `/api/v1/homes`:** es lo esperado sin sesión; inicia sesión
  (registro o Google) y el error desaparece.

- **El backend tarda ~2 min en el primer arranque:** Liquibase ejecuta los 50 changesets
  sobre la base nueva. Es normal; espera a `health = UP`.

## Notas

- **Secretos**: `.env`, `keys/*.pem` y los certificados están en `.gitignore`; no se versionan.
- **Producción**: en un servidor se usa `devices/docker/docker-compose.prod.yml`
  (broker + backend + MySQL con TLS de Let's Encrypt y el reverse proxy delante), **no** esta pila.
- **Certificados**: si cambia la IP de LAN del PC, vuelve a ejecutar `./prepare.sh`
  (reemite el certificado del broker; la CA se reutiliza).
