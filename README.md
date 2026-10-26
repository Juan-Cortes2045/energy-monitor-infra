# infra — EnergyMonitor en Docker

Todo lo de Docker de EnergyMonitor vive aquí: base de datos MySQL, cola RabbitMQ, broker MQTT
(Mosquitto), los cuatro servicios Spring Boot (API gateway, servicio de seguridad, servicio de
dispositivos y backend) y el
frontend React, en tres modos:

| Modo | Archivos | Para qué |
|---|---|---|
| Pila completa local | `docker-compose.yml` | Correr todo el sistema en este PC (demo, pruebas de punta a punta) |
| Desarrollo | `docker-compose.yml` + `docker-compose.dev.yml` | Solo MySQL, RabbitMQ y broker; los servicios corren en el PC con `./mvnw` (IDE, tests) |
| Producción | `docker-compose.prod.yml` + `.env.prod` | Servidor con dominio, Let's Encrypt y proxy HTTPS delante |

Los `Dockerfile` siguen en su repositorio (`backend/energy-monitor-backend`,
`backend/en-monitor-security-service`, `backend/en-monitor-device-service`,
`backend/en-monitor-api-gateway` y `frontend/energy-monitor-web`): cambian con su código, e infra los construye desde ahí.

```
red Docker: energy-monitor

  frontend :80 ──/api/──► gateway :8080 ─┬─ /api/v1/auth/**, /api/v1/admin/users|roles/** ─► security :8082
                                         ├─ /api/v1/homes/*/devices/**, /appliance-types ──► device   :8084
                                         └─ resto de /api/v1/** ────────────────────────────► backend  :8083

  security :8082 ◄── /internal/** (INTERNAL_API_TOKEN) ──► backend :8083 ◄──► device :8084
  security, device, backend ──► mysql :3306 (misma base)  y  ──► rabbitmq :5672 (eventos, correo)
  mosquitto :1883 / :8883 TLS ── /internal/mqtt/auth ──► device :8084
  device (conectividad, comandos) y backend (lecturas) ──► mosquitto :1883
```

Solo se publican la web (`:80`), el gateway para la app móvil (`:8080`), MQTT TLS (`:8883`) y, en
`127.0.0.1`, MySQL, AMQP, la consola de RabbitMQ y MQTT sin TLS. Los tres servicios solo se
alcanzan por la red de Docker y el gateway rechaza `/internal/**`: nunca queda expuesto.

## Requisitos

- Docker Engine 24+ con el plugin `docker compose` 2.24 o superior (probado con Docker 29 /
  Compose v5). El modo desarrollo usa la etiqueta `!override`.
- `openssl` (lo usa `prepare.sh`).
- Los repositorios clonados uno al lado del otro:

  ```bash
  mkdir energy-monitor && cd energy-monitor
  git clone https://github.com/Juan-Cortes2045/energy-monitor-infra.git infra
  git clone https://github.com/Juan-Cortes2045/energy-monitor-backend.git backend/energy-monitor-backend
  git clone https://github.com/Juan-Cortes2045/en-monitor-security-service.git backend/en-monitor-security-service
  git clone https://github.com/Juan-Cortes2045/en-monitor-device-service.git backend/en-monitor-device-service
  git clone https://github.com/Juan-Cortes2045/en-monitor-api-gateway.git backend/en-monitor-api-gateway
  git clone https://github.com/Juan-Cortes2045/Energy-Monitor-application.git frontend/energy-monitor-web
  ```

  Otras rutas: `BACKEND_CONTEXT`, `SECURITY_CONTEXT`, `DEVICE_CONTEXT`, `GATEWAY_CONTEXT` y
  `FRONTEND_CONTEXT` en `.env`.

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
| `keys/` | **no** | Par RSA de los JWT (privada: solo el servicio de seguridad) |
| `.env`, `.env.prod` | **no** | Contraseñas y secretos |

`generate-dev-certs.sh` escribe además
`../backend/energy-monitor-backend/firmware/esp32-pzem-monitor/dev_ca.h` (ignorado por git), para
que el firmware del ESP32 (que vive en el repo backend, ver `firmware/README.md`) confíe en la CA
de desarrollo.

## Arranque rápido (pila completa)

```bash
cd infra
cp .env.example .env      # rellena los valores (o déjalo: prepare.sh lo crea)
./prepare.sh              # genera el par RSA de los JWT y los certificados del broker
# edita .env: contraseñas, SECURITY_RESET_PEPPER, RABBITMQ_PASSWORD, INTERNAL_API_TOKEN,
# MQTT_BACKEND_PASS, MQTT_DEVICE_SERVICE_PASS, DEVICE_MQTT_PUBLIC_HOST y (opcional) GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET
# + VITE_GOOGLE_CLIENT_ID
docker compose up -d --build
docker compose ps         # gateway, security, device y backend deben quedar (healthy)
```

Luego abre <http://localhost>. La API responde en el mismo origen, <http://localhost/api/v1/...>,
a través del gateway; la app móvil (APK) en la LAN llama directo al gateway con
`EXPO_PUBLIC_API_BASE_URL=http://<IP de LAN>:8080` (la misma IP que `DEVICE_MQTT_PUBLIC_HOST`;
en Windows, permite el puerto 8080 en el firewall para redes privadas). La consola de RabbitMQ
está en <http://localhost:15672>
(`RABBITMQ_USERNAME` / `RABBITMQ_PASSWORD`). Swagger de cada servicio: en modo desarrollo
(`http://localhost:8082/swagger-ui.html`, `:8084` y `:8083`), porque en la pila completa no publican puertos.

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

- **Iniciar sesión con Google:** el cliente OAuth llega al servicio de seguridad por `GOOGLE_CLIENT_ID`
  y `GOOGLE_CLIENT_SECRET` (`.env`), y al navegador por `VITE_GOOGLE_CLIENT_ID` (build-arg
  del frontend). Si Google responde **`origin_mismatch`**, falta registrar el origen en
  Google Cloud Console → *APIs & Services → Credentials → (tu OAuth client, tipo Web
  application)* → **Authorized JavaScript origins**: añade `http://localhost` (y la URL de
  producción más adelante). Si la app está en modo *Testing*, agrega además la cuenta de
  Google en **Test users**. Sin ambos, Google bloquea el inicio de sesión.

## Imágenes

| Imagen | Origen | Notas |
|---|---|---|
| `energy-monitor-gateway:local` | `../backend/en-monitor-api-gateway/Dockerfile` | Multi-stage Maven + JRE 21, uid 10001. Solo recibe `public.pem`. |
| `energy-monitor-security:local` | `../backend/en-monitor-security-service/Dockerfile` | Igual; lee `private.pem`, así que corre como `BACKEND_UID:BACKEND_GID`. |
| `energy-monitor-device:local` | `../backend/en-monitor-device-service/Dockerfile` | Igual; solo recibe `public.pem`. |
| `energy-monitor-backend:local` | `../backend/energy-monitor-backend/Dockerfile` | Igual; solo recibe `public.pem`. |
| `energy-monitor-frontend:local` | `../frontend/energy-monitor-web/Dockerfile` | Build con Vite y se sirve con nginx. |
| `mysql:8.4` | Docker Hub | Base de datos compartida por los servicios, con volumen `mysql-data`. |
| `rabbitmq:4.1-management` | Docker Hub | Eventos de cuentas, hogares y dispositivos y pedidos de correo (outbox), con volumen `rabbitmq-data`. |
| `iegomez/mosquitto-go-auth:3.0.0-mosquitto_2.0.18` | Docker Hub | Broker MQTT; autentica contra el servicio de dispositivos. |

El frontend se construye con `VITE_API_BASE_URL` **vacío**, así que el navegador
llama a `/api/v1/...` en su propio origen y nginx lo reenvía a `gateway:8080`
(mismo origen: **no hace falta CORS**). Los cuatro servicios Java tienen `healthcheck` con
`/actuator/health`; el de los servicios de seguridad y de dispositivos y el del backend incluyen
RabbitMQ y MySQL.

## Modo desarrollo (servicios en el PC)

Para trabajar los servicios desde el IDE o con `./mvnw spring-boot:run` / `./mvnw test`, levanta
solo MySQL, RabbitMQ y el broker, y cada servicio en su terminal:

```bash
docker compose stop gateway security device backend frontend    # si la pila completa estaba arriba
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d mysql rabbitmq mosquitto
cd ../backend/en-monitor-security-service && ./mvnw spring-boot:run   # :8082
cd ../backend/en-monitor-device-service   && ./mvnw spring-boot:run   # :8084
cd ../backend/energy-monitor-backend      && ./mvnw spring-boot:run   # :8083
cd ../backend/en-monitor-api-gateway      && ./mvnw spring-boot:run   # :8080
```

- Es la **misma base, la misma cola y el mismo broker** que la pila completa (mismos volúmenes y
  `.env`): lo que hagas en un modo se ve en el otro.
- Cada servicio se conecta con su `application-local.yaml` y su `.env`: deben tener
  `MYSQL_PASSWORD`, `RABBITMQ_USERNAME`/`RABBITMQ_PASSWORD` e `INTERNAL_API_TOKEN` de `infra/.env`.
  La web de Vite (`:5173`) llama al gateway en `:8080`.
- El `.env` del servicio de dispositivos lleva además `MQTT_DEVICE_SERVICE_USER/PASS` y
  `MQTT_BACKEND_USER/PASS` de `infra/.env` (con ellos decide quién entra al broker), y el del
  backend `MQTT_BACKEND_USER/PASS`.
- En este modo `device` (quien autentica cada cliente MQTT) apunta al host con `host-gateway`.
  En Linux con `ufw` permite solo las redes de Docker, una vez:

  ```bash
  sudo ufw allow from 172.16.0.0/12 to any port 8084 proto tcp comment 'mosquitto -> device'
  ```

- Para volver a la pila completa: `docker compose up -d` (recrea el broker sin `host-gateway`).

## Producción (servidor)

`docker-compose.prod.yml` corre MySQL, RabbitMQ, broker, el gateway, los tres servicios y el frontend en un servidor (VPS Ubuntu con
Docker, Nginx y Certbot). El procedimiento completo, con verificación y reversión, está en el
manual de despliegue (`energy-monitor-docs-final/17-despliegue`). En resumen:

1. **DNS**: registros A de `DOMINIO`, `www.DOMINIO` y `mqtt.DOMINIO` hacia la IP del VPS.
2. **Servidor**: Docker, Nginx y Certbot; firewall con 22, 80, 443 y 8883 abiertos.
3. **Código** en `/opt/energy-monitor` (`infra`, `backend/energy-monitor-backend`,
   `backend/en-monitor-security-service`, `backend/en-monitor-device-service`,
   `backend/en-monitor-api-gateway`, `frontend/energy-monitor-web`), como en "Requisitos".
4. **Claves JWT** en `JWT_KEYS_DIR` (`/opt/energy-monitor/keys`): `private.pem` legible por
   `BACKEND_UID` (10001, el servicio de seguridad) y `public.pem` legible por todos (644).
5. **Nginx y certificados**: `deploy/nginx-energy-monitor.conf` (sitio que reenvía todo el dominio a
   `127.0.0.1:${WEB_PORT}`, por defecto 8081) y Certbot. El del broker va aparte
   (`certbot certonly --nginx -d mqtt.DOMINIO`) y `deploy/renew-mqtt-cert.sh`, instalado como hook
   de renovación, lo copia a `MQTT_CERT_DIR` y reinicia `mosquitto`. El firmware no cambia: confía
   en las raíces de Let's Encrypt.
6. **Configuración**: `cp .env.prod.example .env.prod` y rellénalo (contraseñas, pepper,
   `RABBITMQ_PASSWORD`, `INTERNAL_API_TOKEN`, `MQTT_BACKEND_PASS`, `MQTT_DEVICE_SERVICE_PASS`, `DEVICE_MQTT_PUBLIC_HOST=mqtt.DOMINIO`, `https://DOMINIO` como origen y URL
   pública, correo, Google, VAPID, Expo). `chmod 600 .env.prod`.
7. **Arranque**: `docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build`
8. **Primer administrador**: registra la cuenta en la web y `./make-admin.sh --prod correo@ejemplo.com`.
9. **Respaldo diario**: `deploy/backup-mysql.sh` en el cron de root.

El nginx del frontend solo pasa `/api/` al gateway, que rechaza `/internal/**`, y ni el gateway ni
los servicios publican puertos. El gateway y el servicio de seguridad toman la IP real del cliente
de `X-Forwarded-For` solo si la conexión viene de loopback o de la red de Docker. 1883, 3306, 8081
y 15672 no se abren en el firewall; la consola de RabbitMQ se abre con un túnel
(`ssh -L 15672:127.0.0.1:15672 servidor`). Varias instancias del backend o del servicio de
dispositivos necesitan `MQTT_CLIENT_ID` distintos.

**Primer despliegue con el gateway** (el servidor tenía solo el backend): clona los dos
repositorios nuevos, agrega a `.env.prod` `RABBITMQ_PASSWORD`, `INTERNAL_API_TOKEN` y
`SECURITY_CONTEXT`/`GATEWAY_CONTEXT`, conserva el mismo `SECURITY_RESET_PEPPER` (con otro, los
códigos de recuperación ya enviados dejan de servir) y ejecuta `deploy/deploy.sh infra`: crea
RabbitMQ, construye el servicio de seguridad y el gateway y recrea el resto. Los changesets de
seguridad ya aplicados por el backend antiguo se reconocen en `DATABASECHANGELOG` y no se repiten.

**Primer despliegue con el servicio de dispositivos** (el backend aún autenticaba el broker): va
junto, en `main`, con el backend sin módulo de dispositivos y las rutas nuevas del gateway, y el
repositorio `en-monitor-device-service` debe tener ya su `Dockerfile` en `main`.

1. Clona `en-monitor-device-service` en `backend/` y agrega a `.env.prod` `DEVICE_CONTEXT` y
   `MQTT_DEVICE_SERVICE_PASS` (`openssl rand -hex 24`); `MQTT_BACKEND_PASS` sigue igual.
2. `deploy/deploy.sh infra`: construye el servicio de dispositivos, recrea el backend, el gateway
   y el broker, que desde ahí pregunta a `device:8084`.
3. Los changesets `device-001` a `device-008` ya aplicados por el backend se reconocen en
   `DATABASECHANGELOG`; solo se crea `device_outbox`. Los módulos siguen con su `device_code` y su
   API key: la tabla es la misma y no hace falta volver a vincularlos.

Claves VAPID para push en el navegador (una vez por entorno; cambiarlas invalida las suscripciones):

```bash
openssl ecparam -name prime256v1 -genkey -noout -out vapid.pem
echo "NOTIFICATION_VAPID_PRIVATE_KEY=$(openssl ec -in vapid.pem -outform DER | tail -c +8 | head -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
echo "NOTIFICATION_VAPID_PUBLIC_KEY=$(openssl ec -in vapid.pem -pubout -outform DER | tail -c 65 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
rm vapid.pem
```

## CI/CD con GitHub Actions

Cada repositorio (gateway, servicio de seguridad, servicio de dispositivos, backend, web e infra) tiene
`.github/workflows/ci-cd.yml`:

- **CI** en cada PR y push a `dev`/`main`: backend y servicios de seguridad y de dispositivos `./mvnw test` contra
  MySQL 8.4 (servicio del runner), gateway `./mvnw test` (no necesita nada más), web `vitest` +
  `npm run build`, infra `docker compose config` de los tres modos, `shellcheck` y `nginx -t` de la
  plantilla.
- **CD** solo desde `main` (push o *Run workflow*), después de los tests y de la aprobación del
  environment `production`: entra por SSH al VPS y ejecuta
  `deploy/deploy.sh backend|security|device|gateway|frontend|infra`. El script respalda MySQL, hace
  `git pull` de `main`, reconstruye solo ese servicio y espera a que los cuatro servicios Java estén
  `healthy`, la web responda 200 y `/api/v1/homes` responda 401 a través del gateway; si falla,
  vuelve a la versión anterior y el job queda en rojo.

La llave SSH de GitHub está restringida en `authorized_keys` a `deploy.sh`
(`command="/opt/energy-monitor/infra/deploy/deploy.sh",no-pty,...`): no abre una consola ni
ejecuta otra cosa. Secretos del environment `production` en cada repositorio (también en los
nuevos): `DEPLOY_HOST`,
`DEPLOY_USER`, `DEPLOY_SSH_KEY` y `DEPLOY_KNOWN_HOSTS`. Configuración paso a paso: manual de
despliegue, sección 8.5.

## Integración MQTT (ya hecha en el código)

El código de los servicios ya trae la integración; infra solo conecta las piezas:

- El servicio de dispositivos (`MQTT_DEVICE_SERVICE_USER`) se suscribe a telemetría y estado para
  la conectividad y es el único que publica comandos; el backend (`MQTT_BACKEND_USER`) solo lee la
  telemetría para guardar las lecturas. Los dos por el listener interno sin TLS
  (`MQTT_BROKER_URL=tcp://mosquitto:1883`).
- El broker **no guarda usuarios**: por cada conexión pregunta al servicio de dispositivos
  (`POST /internal/mqtt/auth/user`) y por cada publicación (`/acl`), cacheado 5 min.
  Por eso `mosquitto.conf` apunta a `auth_opt_http_host device`: en la pila completa y en
  producción es el contenedor `device`; en modo desarrollo, el host (`host-gateway`).
- Los dispositivos ESP32 se conectan por **8883 TLS** con su `device_code`/`api_key`
  (guardada como hash SHA-256). En local, el certificado es de la CA de desarrollo que crea
  `prepare.sh`; en producción, de Let's Encrypt.
- `DEVICE_MQTT_PUBLIC_HOST` (del servicio de dispositivos) es la IP de LAN que la web escribe al módulo al vincularlo
  por Bluetooth; debe ser alcanzable desde la Wi-Fi del hogar (nunca `localhost`), y
  `prepare.sh` la incluye siempre en el certificado.

## Puertos publicados

| Puerto | Servicio | Para qué |
|---|---|---|
| 80 | frontend (nginx) | La web; reenvía `/api/` al gateway. |
| 8080 | gateway | La API para la app móvil en la LAN (`http://<IP de LAN>:8080`). |
| 8883 | mosquitto | MQTT sobre TLS, para los dispositivos. |
| 1883 | mosquitto | MQTT sin TLS, solo en `127.0.0.1`. |
| 3306 | mysql | Base de datos, solo en `127.0.0.1` (para depurar desde este PC). |
| 5672 | rabbitmq | AMQP, solo en `127.0.0.1` (servicios del PC en modo desarrollo). |
| 15672 | rabbitmq | Consola web, solo en `127.0.0.1`. |

El servicio de seguridad (8082), el backend (8083) y el servicio de dispositivos (8084) no publican
puertos en la pila completa. El gateway (8080) sí, solo en la pila local y para la app móvil: ahí
los clientes de la LAN llegan sin el nginx delante y el gateway puede verlos con la IP del puente
de Docker, así que confiaría en un `X-Forwarded-For` enviado por el cliente (límite de intentos).
En producción no se publica: la app usa `https://DOMINIO`.

## Comandos útiles

```bash
docker compose logs -f backend        # ver el arranque del backend (o security, device, gateway)
docker compose ps                     # estado y salud de los contenedores
docker compose down                   # parar (conserva los volúmenes)
docker compose down -v                # parar y borrar también los datos (MySQL y broker); claves y certificados quedan en disco
docker compose up -d --build backend  # reconstruir solo el backend
```

## Verificación

```bash
docker compose ps                                                     # gateway, security, device, backend (healthy)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/          # 200 (web)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/v1/homes  # 401 sin sesión: lo responde el gateway
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' \
  http://localhost/api/v1/auth/login                                  # 400: llegó al servicio de seguridad
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/v1/appliance-types  # 401: ruta del servicio de dispositivos
# MQTT: los dos servicios ya están suscritos; confírmalo en el log del broker
docker compose logs mosquitto | grep "New client connected"          # ... u'em-backend' y u'em-device-service'
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

- **El broker registra `context deadline exceeded` llamando a `device:8084` (modo desarrollo):**
  el servicio de dispositivos del PC no está corriendo, o falta la regla de `ufw` de "Modo
  desarrollo" (con el puerto 8084: la de 8083 de antes ya no sirve).

- **Un cliente MQTT es rechazado con `rc=5` (no autorizado):** el servicio de dispositivos no
  reconoce sus credenciales. Para el backend y el propio servicio, `MQTT_BACKEND_USER/PASS` y
  `MQTT_DEVICE_SERVICE_USER/PASS` deben ser los mismos en el contenedor (o el `.env`) de quien se
  conecta y en el del servicio de dispositivos.

- **Los servicios tardan ~2 min en el primer arranque:** Liquibase
  ejecuta sus changesets sobre la base nueva. Es normal; espera a `(healthy)` en `docker compose ps`.

- **La API responde `503` por la web:** el gateway no alcanza al servicio de esa ruta. Mira
  `docker compose ps` y `docker compose logs security device backend`.

- **El servicio de seguridad queda `unhealthy` con RabbitMQ arriba:** `RABBITMQ_USERNAME` /
  `RABBITMQ_PASSWORD` no coinciden con el usuario que RabbitMQ creó la primera vez que arrancó su
  volumen. Cámbialo dentro (`docker compose exec rabbitmq rabbitmqctl change_password ...`) o
  borra el volumen `rabbitmq-data` (se pierden los mensajes pendientes).

## Notas

- **Secretos**: `.env`, `.env.prod`, `keys/` y `mosquitto/certs/` están en `.gitignore`; no se versionan.
  `INTERNAL_API_TOKEN` y `RABBITMQ_PASSWORD` son los mismos en todos los servicios: en la pila los toma
  cada contenedor de este `.env`.
- **Producción**: en un servidor se usa `docker-compose.prod.yml` (sección "Producción"), no la
  pila local.
- **Certificados**: si cambia la IP de LAN del PC, actualiza `DEVICE_MQTT_PUBLIC_HOST` y vuelve a
  ejecutar `./prepare.sh` (reemite el certificado del broker con las IPs actuales más
  `DEVICE_MQTT_PUBLIC_HOST`; la CA se reutiliza, así que no hace falta reflashear).
