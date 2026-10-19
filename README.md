# infra — EnergyMonitor en Docker

Todo lo de Docker de EnergyMonitor vive aquí: base de datos MySQL, broker MQTT (Mosquitto),
backend Spring Boot y frontend React, en tres modos:

| Modo | Archivos | Para qué |
|---|---|---|
| Pila completa local | `docker-compose.yml` | Correr todo el sistema en este PC (demo, pruebas de punta a punta) |
| Desarrollo | `docker-compose.yml` + `docker-compose.dev.yml` | Solo MySQL y broker; el backend corre en el PC con `./mvnw` (IDE, tests) |
| Producción | `docker-compose.prod.yml` + `.env.prod` | Servidor con dominio, Let's Encrypt y proxy HTTPS delante |

Los `Dockerfile` siguen en su repositorio (`backend/energy-monitor-backend` y
`frontend/energy-monitor-web`): cambian con su código, e infra los construye desde ahí.

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

- Docker Engine 24+ con el plugin `docker compose` 2.24 o superior (probado con Docker 29 /
  Compose v5). El modo desarrollo usa la etiqueta `!override`.
- `openssl` (lo usa `prepare.sh`).
- Los repositorios clonados uno al lado del otro:

  ```bash
  mkdir energy-monitor && cd energy-monitor
  git clone https://github.com/Juan-Cortes2045/energy-monitor-infra.git infra
  git clone https://github.com/Juan-Cortes2045/energy-monitor-backend.git backend/energy-monitor-backend
  git clone https://github.com/Juan-Cortes2045/Energy-Monitor-application.git frontend/energy-monitor-web
  ```

  Otras rutas: `BACKEND_CONTEXT` y `FRONTEND_CONTEXT` en `.env`.

## Estructura

| Ruta | Versionado | Contenido |
|---|---|---|
| `docker-compose.yml` | sí | Pila completa local |
| `docker-compose.dev.yml` | sí | Modo desarrollo (se combina con el anterior) |
| `docker-compose.prod.yml` | sí | Servidor |
| `.env.example` / `.env.prod.example` | sí | Plantillas de `.env` / `.env.prod` |
| `prepare.sh` | sí | Claves RSA, `.env` y certificado de desarrollo del broker |
| `make-admin.sh` | sí | Da el rol global `ADMIN` a una cuenta (`--prod` en el servidor) |
| `deploy/nginx-energy-monitor.conf` | sí | Sitio de Nginx del servidor (proxy HTTPS) |
| `deploy/renew-mqtt-cert.sh` | sí | Hook de Certbot: copia el certificado del broker y reinicia `mosquitto` |
| `deploy/backup-mysql.sh` | sí | Respaldo lógico diario de MySQL en el servidor |
| `deploy/deploy.sh` | sí | Despliegue de un componente en el servidor (lo llama GitHub Actions) |
| `.github/workflows/ci-cd.yml` | sí | Validación de las compose y scripts, y despliegue de infra |
| `mosquitto/mosquitto.conf` | sí | Configuración del broker (la misma en los tres modos) |
| `mosquitto/generate-dev-certs.sh` | sí | CA y certificado de desarrollo (lo llama `prepare.sh`) |
| `mosquitto/certs/` | **no** | CA, certificado y claves privadas del broker |
| `keys/` | **no** | Par RSA de los JWT |
| `.env`, `.env.prod` | **no** | Contraseñas y secretos |

`generate-dev-certs.sh` escribe además
`../backend/energy-monitor-backend/firmware/esp32-pzem-monitor/dev_ca.h` (ignorado por git), para
que el firmware del ESP32 (que vive en el repo backend, ver `firmware/README.md`) confíe en la CA
de desarrollo.

## Arranque rápido (pila completa)

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

  (Lee `MYSQL_ROOT_PASSWORD` de `.env` y es idempotente; si a la cuenta se le había revocado
  `ADMIN` desde la web, se lo devuelve.) Cierra sesión y vuelve a entrar
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

## Modo desarrollo (backend en el PC)

Para trabajar el backend desde el IDE o con `./mvnw spring-boot:run` / `./mvnw test`, levanta
solo MySQL y el broker:

```bash
docker compose stop backend frontend     # si la pila completa estaba arriba
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d mysql mosquitto
cd ../backend/energy-monitor-backend && ./mvnw spring-boot:run
```

- Es la **misma base y el mismo broker** que la pila completa (mismos volúmenes y `.env`): lo que
  hagas en un modo se ve en el otro.
- El backend del PC se conecta con `application-local.yaml` y `SPRING_DATASOURCE_PASSWORD` de su
  `.env`: ambos deben tener `MYSQL_PASSWORD` de `infra/.env`.
- En este modo `backend` (quien autentica cada cliente MQTT) apunta al host con `host-gateway`.
  En Linux con `ufw` permite solo las redes de Docker, una vez:

  ```bash
  sudo ufw allow from 172.16.0.0/12 to any port 8080 proto tcp comment 'mosquitto -> backend'
  ```

- Para volver a la pila completa: `docker compose up -d` (recrea el broker sin `host-gateway`).

## Producción (servidor)

`docker-compose.prod.yml` corre MySQL, backend, broker y frontend en un servidor (VPS Ubuntu con
Docker, Nginx y Certbot). El procedimiento completo, con verificación y reversión, está en el
manual de despliegue (`energy-monitor-docs-final/17-despliegue`). En resumen:

1. **DNS**: registros A de `DOMINIO`, `www.DOMINIO` y `mqtt.DOMINIO` hacia la IP del VPS.
2. **Servidor**: Docker, Nginx y Certbot; firewall con 22, 80, 443 y 8883 abiertos.
3. **Código** en `/opt/energy-monitor` (`infra`, `backend/energy-monitor-backend`,
   `frontend/energy-monitor-web`), como en "Requisitos".
4. **Claves JWT** en `JWT_KEYS_DIR` (`/opt/energy-monitor/keys`), legibles por `BACKEND_UID` (10001).
5. **Nginx y certificados**: `deploy/nginx-energy-monitor.conf` (sitio que reenvía todo el dominio a
   `127.0.0.1:${WEB_PORT}`, por defecto 8081) y Certbot. El del broker va aparte
   (`certbot certonly --nginx -d mqtt.DOMINIO`) y `deploy/renew-mqtt-cert.sh`, instalado como hook
   de renovación, lo copia a `MQTT_CERT_DIR` y reinicia `mosquitto`. El firmware no cambia: confía
   en las raíces de Let's Encrypt.
6. **Configuración**: `cp .env.prod.example .env.prod` y rellénalo (contraseñas, pepper,
   `MQTT_BACKEND_PASS`, `DEVICE_MQTT_PUBLIC_HOST=mqtt.DOMINIO`, `https://DOMINIO` como origen y URL
   pública, correo, Google, VAPID, Expo). `chmod 600 .env.prod`.
7. **Arranque**: `docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build`
8. **Primer administrador**: registra la cuenta en la web y `./make-admin.sh --prod correo@ejemplo.com`.
9. **Respaldo diario**: `deploy/backup-mysql.sh` en el cron de root.

El nginx del frontend solo pasa `/api/` al backend, así que `/internal/**` nunca queda expuesto, y
el backend corre con `SERVER_FORWARD_HEADERS_STRATEGY=native` para ver la IP real del cliente.
1883, 3306, 8080 y 8081 no se abren en el firewall. Varias instancias del backend necesitan
`MQTT_CLIENT_ID` distintos.

Claves VAPID para push en el navegador (una vez por entorno; cambiarlas invalida las suscripciones):

```bash
openssl ecparam -name prime256v1 -genkey -noout -out vapid.pem
echo "NOTIFICATION_VAPID_PRIVATE_KEY=$(openssl ec -in vapid.pem -outform DER | tail -c +8 | head -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
echo "NOTIFICATION_VAPID_PUBLIC_KEY=$(openssl ec -in vapid.pem -pubout -outform DER | tail -c 65 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
rm vapid.pem
```

## CI/CD con GitHub Actions

Cada repositorio (backend, web e infra) tiene `.github/workflows/ci-cd.yml`:

- **CI** en cada PR y push a `dev`/`main`: backend `./mvnw test` contra MySQL 8.4 (servicio del
  runner), web `vitest` + `npm run build`, infra `docker compose config` de los tres modos,
  `shellcheck` y `nginx -t` de la plantilla.
- **CD** solo desde `main` (push o *Run workflow*), después de los tests y de la aprobación del
  environment `production`: entra por SSH al VPS y ejecuta `deploy/deploy.sh backend|frontend|infra`.
  El script respalda MySQL, hace `git pull` de `main`, reconstruye solo ese servicio y espera
  `actuator/health`; si falla, vuelve a la versión anterior y el job queda en rojo.

La llave SSH de GitHub está restringida en `authorized_keys` a `deploy.sh`
(`command="/opt/energy-monitor/infra/deploy/deploy.sh",no-pty,...`): no abre una consola ni
ejecuta otra cosa. Secretos del environment `production` en cada repositorio: `DEPLOY_HOST`,
`DEPLOY_USER`, `DEPLOY_SSH_KEY` y `DEPLOY_KNOWN_HOSTS`. Configuración paso a paso: manual de
despliegue, sección 8.5.

## Integración MQTT (ya hecha en el código)

El código del backend ya trae la integración; infra solo conecta las piezas:

- El backend publica/consume telemetría y estado como un cliente MQTT más
  (`MQTT_BROKER_URL=tcp://mosquitto:1883`, listener interno sin TLS).
- El broker **no guarda usuarios**: por cada conexión pregunta al backend
  (`POST /internal/mqtt/auth/user`) y por cada publicación (`/acl`), cacheado 5 min.
  Por eso `mosquitto.conf` apunta a `auth_opt_http_host backend`: en la pila completa y en
  producción es el contenedor `backend`; en modo desarrollo, el host (`host-gateway`).
- Los dispositivos ESP32 se conectan por **8883 TLS** con su `device_code`/`api_key`
  (guardada como hash SHA-256). En local, el certificado es de la CA de desarrollo que crea
  `prepare.sh`; en producción, de Let's Encrypt.
- `DEVICE_MQTT_PUBLIC_HOST` es la IP de LAN que la web escribe al módulo al vincularlo
  por Bluetooth; debe ser alcanzable desde la Wi-Fi del hogar (nunca `localhost`), y
  `prepare.sh` la incluye siempre en el certificado.

## Puertos publicados

| Puerto | Servicio | Para qué |
|---|---|---|
| 80 | frontend (nginx) | La web; reenvía `/api/` al backend. |
| 8080 | backend | REST `/api/v1` (abierto para depurar). |
| 8883 | mosquitto | MQTT sobre TLS, para los dispositivos. |
| 1883 | mosquitto | MQTT sin TLS, solo en `127.0.0.1`, para el backend. |
| 3306 | mysql | Base de datos, solo en `127.0.0.1` (para depurar desde este PC). |

## Comandos útiles

```bash
docker compose logs -f backend        # ver el arranque del backend
docker compose ps                     # estado de los contenedores
docker compose down                   # parar (conserva los volúmenes)
docker compose down -v                # parar y borrar también los datos (MySQL y broker); claves y certificados quedan en disco
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

- **El dispositivo no conecta: `[TLS] X509 - Certificate verification failed`** (o el broker
  registra `tlsv1 alert unknown ca`): el certificado del broker no cubre la IP a la que se
  conecta el módulo, o el firmware se compiló con otra CA. Pon la IP correcta en
  `DEVICE_MQTT_PUBLIC_HOST`, ejecuta `./prepare.sh` (siempre incluye esa IP en el certificado)
  y `docker compose up -d --force-recreate mosquitto`. Si persiste, vuelve a flashear el firmware
  desde este PC: `backend/energy-monitor-backend/firmware/esp32-pzem-monitor/dev_ca.h` debe ser la CA de
  `infra/mosquitto/certs/ca.crt`.

- **`Access denied for user 'energy_app'` en el backend del PC (modo desarrollo):** su
  `application-local.yaml` o `SPRING_DATASOURCE_PASSWORD` no coinciden con `MYSQL_PASSWORD` de
  `infra/.env`.

- **El broker registra `context deadline exceeded` llamando a `backend:8080` (modo desarrollo):**
  el backend del PC no está corriendo, o falta la regla de `ufw` de "Modo desarrollo".

- **El backend tarda ~2 min en el primer arranque:** Liquibase ejecuta los 50 changesets
  sobre la base nueva. Es normal; espera a `health = UP`.

## Notas

- **Secretos**: `.env`, `.env.prod`, `keys/` y `mosquitto/certs/` están en `.gitignore`; no se versionan.
- **Producción**: en un servidor se usa `docker-compose.prod.yml` (sección "Producción"), no la
  pila local.
- **Certificados**: si cambia la IP de LAN del PC, actualiza `DEVICE_MQTT_PUBLIC_HOST` y vuelve a
  ejecutar `./prepare.sh` (reemite el certificado del broker con las IPs actuales más
  `DEVICE_MQTT_PUBLIC_HOST`; la CA se reutiliza, así que no hace falta reflashear).
