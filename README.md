# infra — EnergyMonitor en Docker

Todo lo de Docker de EnergyMonitor vive aquí: base de datos MySQL, cola RabbitMQ, broker MQTT
(Mosquitto), los servicios Spring Boot (API gateway, servicios de seguridad, dispositivos,
mediciones, hogares y notificaciones, y backend) y el frontend React, en tres modos:

| Modo                | Archivos                                        | Para qué                                                                               |
| ------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| Pila completa local | `docker-compose.yml`                            | Correr todo el sistema en este PC (demo, pruebas de punta a punta)                     |
| Desarrollo          | `docker-compose.yml` + `docker-compose.dev.yml` | Solo MySQL, RabbitMQ y broker; los servicios corren en el PC con `./mvnw` (IDE, tests) |
| Producción          | `docker-compose.prod.yml` + `.env.prod`         | Servidor con dominio, Let's Encrypt y proxy HTTPS delante                              |

Los `Dockerfile` siguen en su repositorio (`backend/energy-monitor-backend`,
`backend/en-monitor-security-service`, `backend/en-monitor-device-service`,
`backend/en-monitor-measurement-service`, `backend/en-monitor-home-service`,
`backend/en-monitor-notification-service`, `backend/en-monitor-api-gateway` y
`frontend/energy-monitor-web`): cambian con su código, e infra
los construye desde ahí.

```
red Docker: energy-monitor

  frontend :80 ──/api/──► gateway :8080 ─┬─ /api/v1/auth/**, /api/v1/admin/users|roles/** ─► security :8082
                                         ├─ /api/v1/homes/*/devices/**, /appliance-types ──► device   :8084
                                         ├─ /api/v1/measurements/**, /consumption-levels,
                                         │  /api/v1/homes/*/consumption/** ─────────────────► measurement :8085
                                         ├─ resto de /api/v1/homes/**, /api/v1/home-types/** ► home     :8086
                                         ├─ /api/v1/notifications/**, /admin/notifications ──► notification :8087
                                         ├─ /api/v1/alerts/** ──────────────────────────────► alert    :8088
                                         └─ resto de /api/v1/** ────────────────────────────► backend  :8083

  backend :8083 ── /internal/** (INTERNAL_API_TOKEN) ──► device :8084, measurement :8085 y home :8086
  measurement :8085 ◄── /internal/** ──► device :8084
  backend :8083 ── recommendation.created (rabbitmq) ──► notification :8087
  alert :8088 ── /internal/** ──► home :8086, device :8084 y measurement :8085
  measurement.recorded, device.* (rabbitmq) ──► alert :8088 ── alert.raised ──► notification :8087
  home :8086 ◄── /internal/homes/**, /internal/accounts/** ── security, device, measurement, backend
  home :8086 ── /internal/users/profiles ──► security :8082
  notification :8087 ── /internal/** ──► security :8082, home :8086 y device :8084
  security, device, measurement, home, notification, alert, backend ──► mysql :3306 (misma base)  y  ──► rabbitmq :5672 (eventos, correo)
  mosquitto :1883 / :8883 TLS ── /internal/mqtt/auth ──► device :8084
  device (conectividad, comandos) y measurement (lecturas) ──► mosquitto :1883
```

Solo se publican la web (`:80`), el gateway para la app móvil (`:8080`), MQTT TLS (`:8883`) y, en
`127.0.0.1`, MySQL, AMQP, la consola de RabbitMQ y MQTT sin TLS. Los servicios solo se alcanzan
por la red de Docker y el gateway rechaza `/internal/**`: nunca queda expuesto.

## Requisitos

- Docker Engine 24+ con el plugin `docker compose` 2.24 o superior (probado con Docker 29 /
  Compose v5). El modo desarrollo usa la etiqueta `!override`.
- `openssl` (lo usa `prepare.sh`).
- `jq`, solo para las pruebas de `e2e/`. En Windows: `winget install jqlang.jq` y abre otra
  terminal para que tome el PATH.
- Los repositorios clonados uno al lado del otro:

  ```bash
  mkdir energy-monitor && cd energy-monitor
  git clone https://github.com/Juan-Cortes2045/energy-monitor-infra.git infra
  git clone https://github.com/Juan-Cortes2045/energy-monitor-backend.git backend/energy-monitor-backend
  git clone https://github.com/Juan-Cortes2045/en-monitor-security-service.git backend/en-monitor-security-service
  git clone https://github.com/Juan-Cortes2045/en-monitor-device-service.git backend/en-monitor-device-service
  git clone https://github.com/Juan-Cortes2045/en-monitor-measurement-service.git backend/en-monitor-measurement-service
  git clone https://github.com/angelgarcia0/en-monitor-home-service.git backend/en-monitor-home-service
  git clone https://github.com/angelgarcia0/en-monitor-notification-service.git backend/en-monitor-notification-service
  git clone https://github.com/Juan-Cortes2045/en-monitor-api-gateway.git backend/en-monitor-api-gateway
  git clone https://github.com/Juan-Cortes2045/Energy-Monitor-application.git frontend/energy-monitor-web
  ```

  Otras rutas: `BACKEND_CONTEXT`, `SECURITY_CONTEXT`, `DEVICE_CONTEXT`, `MEASUREMENT_CONTEXT`,
  `HOME_CONTEXT`, `NOTIFICATION_CONTEXT`, `ALERT_CONTEXT`, `GATEWAY_CONTEXT` y `FRONTEND_CONTEXT` en `.env`.

## Estructura

| Ruta                                 | Versionado | Contenido                                                                |
| ------------------------------------ | ---------- | ------------------------------------------------------------------------ |
| `docker-compose.yml`                 | sí         | Pila completa local                                                      |
| `docker-compose.dev.yml`             | sí         | Modo desarrollo (se combina con el anterior)                             |
| `docker-compose.prod.yml`            | sí         | Servidor                                                                 |
| `.env.example` / `.env.prod.example` | sí         | Plantillas de `.env` / `.env.prod`                                       |
| `prepare.sh`                         | sí         | Claves RSA, `.env` y certificado de desarrollo del broker                |
| `make-admin.sh`                      | sí         | Da el rol global `ADMIN` a una cuenta (`--prod` en el servidor)          |
| `e2e/device-flow.sh`                 | sí         | Prueba de punta a punta del servicio de dispositivos sobre la pila local |
| `e2e/measurement-flow.sh`            | sí         | Prueba de punta a punta del servicio de mediciones sobre la pila local   |
| `e2e/activity-flow.sh`               | sí         | Prueba de punta a punta de las notificaciones de actividad               |
| `deploy/nginx-energy-monitor.conf`   | sí         | Sitio de Nginx del servidor (proxy HTTPS)                                |
| `deploy/renew-mqtt-cert.sh`          | sí         | Hook de Certbot: copia el certificado del broker y reinicia `mosquitto`  |
| `deploy/backup-mysql.sh`             | sí         | Respaldo lógico diario de MySQL en el servidor                           |
| `deploy/deploy.sh`                   | sí         | Despliegue de un componente en el servidor (lo llama GitHub Actions)     |
| `.github/workflows/ci-cd.yml`        | sí         | Validación de las compose y scripts, y despliegue de infra               |
| `mosquitto/mosquitto.conf`           | sí         | Configuración del broker (la misma en los tres modos)                    |
| `mosquitto/generate-dev-certs.sh`    | sí         | CA y certificado de desarrollo (lo llama `prepare.sh`)                   |
| `mosquitto/certs/`                   | **no**     | CA, certificado y claves privadas del broker                             |
| `keys/`                              | **no**     | Par RSA de los JWT (privada: solo el servicio de seguridad)              |
| `.env`, `.env.prod`                  | **no**     | Contraseñas y secretos                                                   |

`generate-dev-certs.sh` escribe además
`../backend/energy-monitor-backend/firmware/esp32-pzem-monitor/dev_ca.h` (ignorado por git), para
que el firmware del ESP32 (que vive en el repo backend, ver `firmware/README.md`) confíe en la CA
de desarrollo.

## Arranque rápido (pila completa)

```bash
cd infra
cp .env.example .env      # y rellénalo: sección "Variables de entorno"
./prepare.sh              # genera el par RSA de los JWT y los certificados del broker
docker compose config -q  # nombra la variable obligatoria que falte, si falta alguna
docker compose up -d --build
docker compose ps         # gateway, security, device, measurement, home, notification y backend deben quedar (healthy)
```

Luego abre <http://localhost>. La API responde en el mismo origen, <http://localhost/api/v1/...>,
a través del gateway; la app móvil (APK) en la LAN llama directo al gateway con
`EXPO_PUBLIC_API_BASE_URL=http://<IP de LAN>:8080` (la misma IP que `DEVICE_MQTT_PUBLIC_HOST`;
en Windows, permite el puerto 8080 en el firewall para redes privadas). La consola de RabbitMQ
está en <http://localhost:15672>
(`RABBITMQ_USERNAME` / `RABBITMQ_PASSWORD`). Swagger de cada servicio: en modo desarrollo
(`http://localhost:8082/swagger-ui.html`, `:8084`, `:8085`, `:8086`, `:8087`, `:8088` y `:8083`), porque en la pila
completa no publican puertos.

## Variables de entorno

`docker compose` lee `infra/.env`, la copia de `.env.example`. En modo desarrollo cada servicio lee
además su propio `.env`, con los mismos valores compartidos (tabla al final de esta sección).
Ninguno se versiona. En todos:

- Escribe `CLAVE=valor` sin comillas, sin espacios al final y sin `$`. Spring los lee como
  `.properties` y Compose interpreta `$`.
- No dejes los textos de ejemplo (`CHANGE_ME_...`). El sistema arranca igual, pero esos valores
  están publicados en el repositorio.
- Protege cada archivo con `chmod 600`.

### Paso a paso (`infra/.env`)

1. **Crea el archivo.** `prepare.sh` lo crea si falta y pone tu uid/gid en `BACKEND_UID`/`BACKEND_GID`.

   ```bash
   cd infra
   cp .env.example .env && chmod 600 .env
   ```

2. **Genera los secretos aleatorios.** Este bloque rellena solo los que están vacíos y no
   imprime ninguno:

   ```bash
   gen() { grep -q "^$1=$" .env && sed -i "s|^$1=$|$1=$(openssl rand -hex "$2")|" .env; }
   gen MYSQL_PASSWORD 16;    gen MYSQL_ROOT_PASSWORD 16; gen SECURITY_RESET_PEPPER 32
   gen RABBITMQ_PASSWORD 24; gen INTERNAL_API_TOKEN 32;  gen MQTT_MEASUREMENT_SERVICE_PASS 24
   gen MQTT_DEVICE_SERVICE_PASS 24
   ```

3. **Pon la IP de LAN del PC** y reemite el certificado del broker. Repítelo cada vez que cambie
   la IP, por ejemplo al cambiar de red:

   ```bash
   sed -i "s|^DEVICE_MQTT_PUBLIC_HOST=.*|DEVICE_MQTT_PUBLIC_HOST=$(hostname -I | awk '{print $1}')|" .env
   ./prepare.sh
   ```

4. **Rellena los valores de servicios externos:** correo, Google, VAPID y Expo. Todos son
   opcionales; cómo obtener cada uno está más abajo.

5. **Comprueba:**

   ```bash
   docker compose config -q && echo "compose OK"         # si falta una obligatoria, la nombra
   grep -lE '^[A-Z_]+=.*CHANGE_ME' .env ../backend/*/.env  # no debe listar ningún archivo
   ```

### De dónde sale cada valor

| Variable                                                              | Obligatoria | Cómo se obtiene                                                                                                                                                                                                                        |
| --------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD`                               | sí          | `openssl rand -hex 16`. La primera es la del usuario `energy_app` de los servicios; la segunda, la de `root`. MySQL la toma solo al crear el volumen (ver abajo).                                                                      |
| `SECURITY_RESET_PEPPER`                                               | sí          | `openssl rand -hex 32`. Protege los códigos de recuperación: si lo cambias, los códigos ya enviados dejan de servir.                                                                                                                   |
| `SECURITY_CORS_ALLOWED_ORIGINS`, `NOTIFICATION_WEB_URL`               | no          | `http://localhost`, el origen de la web en la pila completa.                                                                                                                                                                           |
| `BACKEND_UID`, `BACKEND_GID`                                          | no          | `id -u` / `id -g`. Los pone `prepare.sh`.                                                                                                                                                                                              |
| `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD`                              | la clave    | `energy-monitor` y `openssl rand -hex 24`. RabbitMQ los toma solo al crear el volumen (ver abajo).                                                                                                                                     |
| `INTERNAL_API_TOKEN`                                                  | sí          | `openssl rand -hex 32`. Lo comparten seguridad, dispositivos, mediciones, hogares, notificaciones y backend en `/internal/**`.                                                                                                                         |
| `DEVICE_MQTT_PUBLIC_HOST`                                             | sí          | La IP de LAN del PC (`hostname -I`), nunca `localhost`: es la dirección que la web escribe al módulo. Luego `./prepare.sh`.                                                                                                            |
| `DEVICE_MQTT_PUBLIC_PORT`                                             | no          | `8883`.                                                                                                                                                                                                                                |
| `MQTT_MEASUREMENT_SERVICE_USER/PASS`, `MQTT_DEVICE_SERVICE_USER/PASS` | las claves  | Deja los usuarios por defecto y genera cada clave con `openssl rand -hex 24`. El broker no guarda usuarios: los comprueba el servicio de dispositivos. El backend ya no se conecta al broker, así que `MQTT_BACKEND_USER/PASS` sobran. |
| `MAIL_HOST`, `MAIL_PORT`                                              | no          | `smtp.gmail.com` y `587`.                                                                                                                                                                                                              |
| `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_FROM`                         | no          | La cuenta de Gmail y su contraseña de aplicación (ver abajo). En `MAIL_FROM`: `EnergyMonitor <esa cuenta>`. Sin ellas no salen los correos de verificación, recuperación ni alertas.                                                   |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `VITE_GOOGLE_CLIENT_ID`   | no          | El cliente OAuth de Google (ver abajo). `VITE_GOOGLE_CLIENT_ID` lleva el mismo ID. Si están vacías, no aparece el botón de Google.                                                                                                     |
| `NOTIFICATION_VAPID_PUBLIC_KEY`, `NOTIFICATION_VAPID_PRIVATE_KEY`     | no          | Comandos de abajo, una vez por entorno. Las recibe el servicio de notificaciones: no las cambies, o cada navegador suscrito deja de recibir push. Si están vacías, no hay notificaciones push en el navegador.            |
| `EXPO_ACCESS_TOKEN`                                                   | no          | En expo.dev: _Account settings → Access tokens → Create token_. Si está vacía, no hay push en la app móvil. Va solo en el servidor, nunca en la app.                                                                                   |
| `HOME_OUTBOX_RELAY_ENABLED`, `ACCOUNT_DELETED_CONSUMER_ENABLED`       | no          | `true` (por defecto). `false` solo para volver atrás a un backend que aún tenga su módulo de hogares (ver "Servicio de hogares").                                                                                                       |
| `SECURITY_EVENTS_CONSUMER_ENABLED`, `ALERT_EVENTS_CONSUMER_ENABLED`, `ALERT_OUTBOX_RELAY_ENABLED` | no | `true` (por defecto). `false` solo para volver atrás a un backend que aún tenga su módulo de notificaciones (ver "Servicio de notificaciones").                                                                                |
| `ALERT_CONSUMERS_ENABLED`, `ALERT_SERVICE_OUTBOX_RELAY_ENABLED` | no | El primero `false` por defecto: el servicio de alertas no crea alertas hasta el corte (ver "Servicio de alertas"). El segundo `true`. |
| `*_CONTEXT`                                                           | no          | Solo si los repositorios no están clonados uno al lado del otro (ver "Requisitos").                                                                                                                                                    |

**Contraseña de aplicación de Gmail** (`MAIL_PASSWORD`). Tu contraseña normal de Gmail no sirve
para SMTP:

1. Con la cuenta que enviará los correos, activa la **Verificación en 2 pasos** en
   <https://myaccount.google.com/security>.
2. Abre <https://myaccount.google.com/apppasswords>, escribe un nombre (`EnergyMonitor`) y pulsa
   _Crear_.
3. Copia los 16 caracteres **sin espacios** en `MAIL_PASSWORD`.

**Cliente OAuth de Google** (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`):

1. En <https://console.cloud.google.com>, crea o elige un proyecto.
2. Abre la pantalla de consentimiento (_Google Auth Platform_, o _APIs y servicios → Pantalla de
   consentimiento de OAuth_) y elige el tipo _Externo_. Mientras esté en _Testing_, agrega en
   _Test users_ las cuentas que van a probar.
3. Ve a _Credenciales → Crear credenciales → ID de cliente de OAuth_ y elige el tipo **Aplicación
   web**. En _Orígenes autorizados de JavaScript_ agrega `http://localhost` (pila completa) y
   `http://localhost:5173` (web de Vite en modo desarrollo).
4. Copia el _ID de cliente_ en `GOOGLE_CLIENT_ID` y en `VITE_GOOGLE_CLIENT_ID`, y el _Secreto del
   cliente_ en `GOOGLE_CLIENT_SECRET`. `VITE_GOOGLE_CLIENT_ID` va dentro del build: si lo cambias,
   corre `docker compose up -d --build frontend`.

**Claves VAPID** (push en el navegador). Genéralas una vez por entorno; cambiarlas invalida las
suscripciones:

```bash
openssl ecparam -name prime256v1 -genkey -noout -out vapid.pem
echo "NOTIFICATION_VAPID_PRIVATE_KEY=$(openssl ec -in vapid.pem -outform DER | tail -c +8 | head -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
echo "NOTIFICATION_VAPID_PUBLIC_KEY=$(openssl ec -in vapid.pem -pubout -outform DER | tail -c 65 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
rm vapid.pem
```

### Valores que guarda un volumen

MySQL y RabbitMQ crean su usuario con los valores de `.env` solo la primera vez que arranca su
volumen. Si después cambias `MYSQL_PASSWORD` o `RABBITMQ_PASSWORD` en `.env`, el servicio rechaza
la clave nueva hasta que la cambies también dentro. Estos comandos leen la clave de `.env`, así que
no hace falta escribirla:

```bash
grep '^RABBITMQ_PASSWORD=' .env | cut -d= -f2- \
  | docker exec -i energy-monitor-rabbitmq rabbitmqctl change_password energy-monitor
docker exec -e MYSQL_PWD="$(grep '^MYSQL_ROOT_PASSWORD=' .env | cut -d= -f2-)" energy-monitor-mysql \
  mysql -uroot -e "ALTER USER 'energy_app'@'%' IDENTIFIED BY '$(grep '^MYSQL_PASSWORD=' .env | cut -d= -f2-)'"
docker compose up -d      # recrea los servicios con los valores nuevos
```

Otra opción es `docker compose down -v`, que vuelve a crear los usuarios pero borra los datos.

### Los `.env` de cada servicio (modo desarrollo)

Cada servicio que corre en el PC lee el `.env` de su carpeta, copiado de su `.env.example`, y el
`application-local.yaml`, copiado de su `.example`. Los valores compartidos son los de
`infra/.env`. `MYSQL_PASSWORD` cambia de nombre: allí se llama `SPRING_DATASOURCE_PASSWORD`.

| Archivo                                       | Valores de `infra/.env`                                                                                                                                | Propios del modo desarrollo                                                                                                                                                                  |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `backend/en-monitor-security-service/.env`    | `MYSQL_PASSWORD`, `SECURITY_RESET_PEPPER`, `GOOGLE_CLIENT_ID/SECRET`, `RABBITMQ_*`, `INTERNAL_API_TOKEN`                                               | `SECURITY_JWT_PRIVATE_KEY_PATH`, `SECURITY_JWT_PUBLIC_KEY_PATH`, `SECURITY_SESSION_COOKIE_SECURE=false`                                                                                      |
| `backend/en-monitor-device-service/.env`      | `MYSQL_PASSWORD`, `RABBITMQ_*`, `INTERNAL_API_TOKEN`, `MQTT_MEASUREMENT_SERVICE_USER/PASS`, `MQTT_DEVICE_SERVICE_USER/PASS`, `DEVICE_MQTT_PUBLIC_HOST` | `SECURITY_JWT_PUBLIC_KEY_PATH`                                                                                                                                                               |
| `backend/en-monitor-measurement-service/.env` | `MYSQL_PASSWORD`, `RABBITMQ_*`, `INTERNAL_API_TOKEN`, `MQTT_MEASUREMENT_SERVICE_USER/PASS`                                                             | `SECURITY_JWT_PUBLIC_KEY_PATH`, `MEASUREMENT_MQTT_ENABLED=true`                                                                                                                              |
| `backend/en-monitor-home-service/.env`        | `MYSQL_PASSWORD`, `RABBITMQ_*`, `INTERNAL_API_TOKEN`                                                                                                   | `SECURITY_JWT_PUBLIC_KEY_PATH`, `SECURITY_SERVICE_URL=http://localhost:8082`                                                                                                                 |
| `backend/en-monitor-notification-service/.env` | `MYSQL_PASSWORD`, `MAIL_*`, `RABBITMQ_*`, `INTERNAL_API_TOKEN`, VAPID, `EXPO_ACCESS_TOKEN`                                                            | `SECURITY_JWT_PUBLIC_KEY_PATH`, `NOTIFICATION_WEB_URL=http://localhost:5173`, `SECURITY_SERVICE_URL`, `HOME_SERVICE_URL`, `DEVICE_SERVICE_URL` (los de `localhost`)                           |
| `backend/energy-monitor-backend/.env`         | `MYSQL_PASSWORD`, `RABBITMQ_*`, `INTERNAL_API_TOKEN`                                                                                                   | `SECURITY_JWT_PUBLIC_KEY_PATH`, `MEASUREMENT_SERVICE_URL=http://localhost:8085`                                                                                                              |
| `backend/en-monitor-api-gateway/.env`         | —                                                                                                                                                      | `SECURITY_JWT_PUBLIC_KEY_PATH`, `SECURITY_CORS_ALLOWED_ORIGINS=http://localhost:5173`                                                                                                        |
| `frontend/energy-monitor-web/.env.local`      | `VITE_GOOGLE_CLIENT_ID`                                                                                                                                | Nada más: Vite reenvía `/api` al gateway de `:8080` (otro puerto: `VITE_DEV_API_TARGET`)                                                                                                     |
| `frontend/energy-monitor-mobile/.env`         | —                                                                                                                                                      | `EXPO_PUBLIC_API_BASE_URL`: `http://<IP de LAN>:8080` en modo desarrollo o `http://<IP de LAN>` con la pila completa. `EXPO_PUBLIC_EAS_PROJECT_ID`: expo.dev → proyecto → _Project settings_ |

Las rutas de las claves deben ser absolutas, porque Java no expande `~`. Los servicios del PC
pueden usar su propio par de claves:

```bash
mkdir -p ~/.energy-monitor/keys && chmod 700 ~/.energy-monitor/keys
openssl genpkey -algorithm RSA -out ~/.energy-monitor/keys/private.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -in ~/.energy-monitor/keys/private.pem -pubout -out ~/.energy-monitor/keys/public.pem
```

También pueden apuntar a `infra/keys/`, el par de la pila completa.

Para comprobar que un valor compartido es el mismo en todos los archivos sin mostrarlo, compara
sus resúmenes:

```bash
for v in RABBITMQ_PASSWORD INTERNAL_API_TOKEN MQTT_MEASUREMENT_SERVICE_PASS; do
  for f in .env ../backend/*/.env; do
    grep -q "^$v=" "$f" && echo "$v $(grep "^$v=" "$f" | cut -d= -f2- | sha256sum | cut -c1-8) $f"
  done
done      # cada variable debe dar el mismo resumen en todos sus archivos
```

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
  Google Cloud Console → _APIs & Services → Credentials → (tu OAuth client, tipo Web
  application)_ → **Authorized JavaScript origins**: añade `http://localhost` (y la URL de
  producción más adelante). Si la app está en modo _Testing_, agrega además la cuenta de
  Google en **Test users**. Sin ambos, Google bloquea el inicio de sesión.

## Imágenes

| Imagen                                             | Origen                                                 | Notas                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `energy-monitor-gateway:local`                     | `../backend/en-monitor-api-gateway/Dockerfile`         | Multi-stage Maven + JRE 21, uid 10001. Solo recibe `public.pem`.                                      |
| `energy-monitor-security:local`                    | `../backend/en-monitor-security-service/Dockerfile`    | Igual; lee `private.pem`, así que corre como `BACKEND_UID:BACKEND_GID`.                               |
| `energy-monitor-device:local`                      | `../backend/en-monitor-device-service/Dockerfile`      | Igual; solo recibe `public.pem`.                                                                      |
| `energy-monitor-measurement:local`                 | `../backend/en-monitor-measurement-service/Dockerfile` | Igual; solo recibe `public.pem`. Suscrito a la telemetría (`MEASUREMENT_MQTT_ENABLED=true`).          |
| `energy-monitor-home:local`                        | `../backend/en-monitor-home-service/Dockerfile`        | Igual; solo recibe `public.pem`.                                                                      |
| `energy-monitor-backend:local`                     | `../backend/energy-monitor-backend/Dockerfile`         | Igual; solo recibe `public.pem`.                                                                      |
| `energy-monitor-frontend:local`                    | `../frontend/energy-monitor-web/Dockerfile`            | Build con Vite y se sirve con nginx.                                                                  |
| `mysql:8.4`                                        | Docker Hub                                             | Base de datos compartida por los servicios, con volumen `mysql-data`.                                 |
| `rabbitmq:4.1-management`                          | Docker Hub                                             | Eventos de cuentas, hogares y dispositivos y pedidos de correo (outbox), con volumen `rabbitmq-data`. |
| `iegomez/mosquitto-go-auth:3.0.0-mosquitto_2.0.18` | Docker Hub                                             | Broker MQTT; autentica contra el servicio de dispositivos.                                            |

El frontend se construye con `VITE_API_BASE_URL` **vacío**, así que el navegador
llama a `/api/v1/...` en su propio origen y nginx lo reenvía a `gateway:8080`
(mismo origen: **no hace falta CORS**). Los seis servicios Java tienen `healthcheck` con
`/actuator/health`; el de los servicios de seguridad, dispositivos, mediciones y hogares y el del
backend incluyen RabbitMQ y MySQL.

## Modo desarrollo (servicios en el PC)

Para trabajar los servicios desde el IDE o con `./mvnw spring-boot:run` / `./mvnw test`, levanta
solo MySQL, RabbitMQ y el broker, y cada servicio en su terminal:

```bash
docker compose stop gateway security device measurement home notification alert backend frontend    # si la pila completa estaba arriba
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d mysql rabbitmq mosquitto
cd ../backend/en-monitor-security-service && ./mvnw spring-boot:run   # :8082
cd ../backend/en-monitor-device-service   && ./mvnw spring-boot:run   # :8084
cd ../backend/en-monitor-measurement-service && ./mvnw spring-boot:run   # :8085
cd ../backend/en-monitor-home-service     && ./mvnw spring-boot:run   # :8086
cd ../backend/en-monitor-notification-service && ./mvnw spring-boot:run   # :8087
cd ../backend/en-monitor-alert-service && ./mvnw spring-boot:run   # :8088
cd ../backend/energy-monitor-backend      && ./mvnw spring-boot:run   # :8083
cd ../backend/en-monitor-api-gateway      && ./mvnw spring-boot:run   # :8080
```

- Es la **misma base, la misma cola y el mismo broker** que la pila completa (mismos volúmenes y
  `.env`): lo que hagas en un modo se ve en el otro.
- Cada servicio se conecta con su `application-local.yaml` y su `.env`, con los valores de
  `infra/.env` (tabla en "Variables de entorno"). La web de Vite (`:5173`) llama al gateway en
  `:8080`.
- En este modo `device` (quien autentica cada cliente MQTT) apunta al host con `host-gateway`.
  En Linux con `ufw` permite solo las redes de Docker, una vez:

  ```bash
  sudo ufw allow from 172.16.0.0/12 to any port 8084 proto tcp comment 'mosquitto -> device'
  ```

- Para volver a la pila completa: `docker compose up -d` (recrea el broker sin `host-gateway`).

## Producción (servidor)

`docker-compose.prod.yml` corre MySQL, RabbitMQ, broker, el gateway, los cinco servicios y el
frontend en un servidor (VPS Ubuntu con Docker, Nginx y Certbot). El procedimiento completo, con verificación y reversión, está en el
manual de despliegue (`energy-monitor-docs-final/17-despliegue`). En resumen:

1. **DNS**: registros A de `DOMINIO`, `www.DOMINIO` y `mqtt.DOMINIO` hacia la IP del VPS.
2. **Servidor**: Docker, Nginx y Certbot; firewall con 22, 80, 443 y 8883 abiertos.
3. **Código** en `/opt/energy-monitor` (`infra`, `backend/energy-monitor-backend`,
   `backend/en-monitor-security-service`, `backend/en-monitor-device-service`,
   `backend/en-monitor-measurement-service`, `backend/en-monitor-home-service`,
   `backend/en-monitor-api-gateway`, `frontend/energy-monitor-web`), como en "Requisitos".
4. **Claves JWT** en `JWT_KEYS_DIR` (`/opt/energy-monitor/keys`): `private.pem` legible por
   `BACKEND_UID` (10001, el servicio de seguridad) y `public.pem` legible por todos (644).
5. **Nginx y certificados**: `deploy/nginx-energy-monitor.conf` (sitio que reenvía todo el dominio a
   `127.0.0.1:${WEB_PORT}`, por defecto 8081) y Certbot. El del broker va aparte
   (`certbot certonly --nginx -d mqtt.DOMINIO`) y `deploy/renew-mqtt-cert.sh`, instalado como hook
   de renovación, lo copia a `MQTT_CERT_DIR` y reinicia `mosquitto`. El firmware no cambia: confía
   en las raíces de Let's Encrypt.
6. **Configuración**: `cp .env.prod.example .env.prod` y rellénalo (contraseñas, pepper,
   `RABBITMQ_PASSWORD`, `INTERNAL_API_TOKEN`, `MQTT_MEASUREMENT_SERVICE_PASS`, `MQTT_DEVICE_SERVICE_PASS`, `DEVICE_MQTT_PUBLIC_HOST=mqtt.DOMINIO`, `https://DOMINIO` como origen y URL
   pública, correo, Google, VAPID, Expo; cómo obtener cada uno está en "Variables de entorno").
   `chmod 600 .env.prod`.
7. **Arranque**: `docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build`
8. **Primer administrador**: registra la cuenta en la web y `./make-admin.sh --prod correo@ejemplo.com`.
9. **Respaldo diario**: `deploy/backup-mysql.sh` en el cron de root.

El nginx del frontend solo pasa `/api/` al gateway, que rechaza `/internal/**`, y ni el gateway ni
los servicios publican puertos. El gateway y el servicio de seguridad toman la IP real del cliente
de `X-Forwarded-For` solo si la conexión viene de loopback o de la red de Docker. 1883, 3306, 8081
y 15672 no se abren en el firewall; la consola de RabbitMQ se abre con un túnel
(`ssh -L 15672:127.0.0.1:15672 servidor`). Varias instancias del servicio de dispositivos o del
de mediciones necesitan `MQTT_CLIENT_ID` distintos.

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

**Primer despliegue con el servicio de mediciones** (el backend aún guardaba las lecturas): va
junto, en `main`, con el backend sin módulo de mediciones, las rutas nuevas del gateway y el
servicio de dispositivos que reconoce al usuario MQTT nuevo; `en-monitor-measurement-service` debe
tener ya su `Dockerfile` en `main`.

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. Clona `en-monitor-measurement-service` en `backend/` (`-b main`) y agrega a `.env.prod`
   `MEASUREMENT_CONTEXT` y `MQTT_MEASUREMENT_SERVICE_PASS` (`openssl rand -hex 24`).
   `MQTT_BACKEND_USER/PASS` ya no se usan; pueden quedarse o borrarse.
3. Despliega primero el servicio de dispositivos (`deploy.sh device`): desde ahí el broker acepta
   al usuario de mediciones.
4. `deploy/deploy.sh infra`: construye el servicio de mediciones (aplica `measurement-004`, su
   outbox), recrea el backend sin cliente MQTT y el gateway con las rutas nuevas. Las lecturas
   siguen en la misma tabla: el historial no se mueve.
5. Los changesets `measurement-001` a `measurement-003` ya aplicados por el backend se reconocen en
   `DATABASECHANGELOG`.

### Servicio de hogares

`home` atiende los hogares, sus miembros y umbrales y los tipos de hogar, y responde a los otros
servicios quién puede actuar sobre un hogar. El gateway le manda `/api/v1/homes/**` (salvo los
dispositivos y el consumo de un hogar) y `/api/v1/home-types/**`; seguridad, dispositivos y
mediciones le preguntan en `HOME_SERVICE_URL`, y el backend lee de él los hogares de las alertas,
notificaciones y recomendaciones. Es el único dueño de las tablas `home*`: publica `home.deleted`
desde su outbox (`HOME_OUTBOX_RELAY_ENABLED`) y limpia las cuentas borradas en la cola
`home-service.home.account-deleted` (`ACCOUNT_DELETED_CONSUMER_ENABLED`), las dos encendidas por
defecto. En `false` solo sirven para volver atrás a un backend que aún tenga su módulo de hogares,
que hacía ambas cosas: con los dos encendidos cada mensaje se procesaría dos veces.

**Corte desde el despliegue en dos pasos** (el servidor tenía el servicio de hogares con los dos
interruptores apagados y el backend con su módulo de hogares):

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. `deploy/deploy.sh infra`: recrea `home` con el relay y el consumidor encendidos y quita
   `BACKEND_INTERNAL_URL` de seguridad, dispositivos y mediciones (ya preguntan al servicio de
   hogares).
3. Enseguida `deploy/deploy.sh backend`, con el backend sin módulo de hogares. Entre los dos pasos
   los dos relays y los dos consumidores corren a la vez: un `home.deleted` puede salir dos veces y
   un `account.deleted` procesarse dos veces, lo que los consumidores toleran (son idempotentes).
   El orden inverso perdería los `account.deleted` de ese intervalo.
4. La cola del backend ya no tiene consumidor y se llenaría con cada cuenta borrada: bórrala.

   ```bash
   docker compose -f docker-compose.prod.yml --env-file .env.prod exec rabbitmq \
     rabbitmqctl delete_queue energy-monitor-backend.home.account-deleted
   docker compose -f docker-compose.prod.yml --env-file .env.prod exec rabbitmq \
     rabbitmqctl delete_queue energy-monitor-backend.home.account-deleted.dlq
   ```

**Primer despliegue con el servicio de hogares:** el contenedor `home` debe estar arriba **antes**
que el gateway con las rutas nuevas y que los servicios que le preguntan; si no, esas rutas
responden 503.

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. Clona `en-monitor-home-service` en `backend/` (`-b main`) y agrega a `.env.prod` `HOME_CONTEXT`.
   No necesita secretos nuevos: usa `MYSQL_PASSWORD`, `RABBITMQ_*` e `INTERNAL_API_TOKEN`.
3. `deploy/deploy.sh infra`: construye el servicio de hogares y recrea el resto con
   `HOME_SERVICE_URL`. Los changesets `home-001` a `home-007` ya aplicados por el backend se
   reconocen en `DATABASECHANGELOG` y no se ejecuta ninguno.
4. Después, en cualquier orden: `deploy.sh gateway`, `security`, `device`, `measurement` y
   `backend`, con las versiones que llaman al servicio de hogares.

### Servicio de notificaciones

`notification` atiende los canales de cada usuario (preferencias de correo y push, suscripciones
Web Push de los navegadores y dispositivos de la app) y las notificaciones de los administradores:
el gateway le manda `/api/v1/notifications/**` y `/api/v1/admin/notifications/**`. Pregunta a
seguridad (nombres, correos, administradores y el permiso `USER.READ`), a hogares (miembros y
nombre de un hogar) y a dispositivos (nombre de un dispositivo). Usa las tablas `notification`,
`notification_preference`, `push_subscription` y `push_device` de la base compartida.

Recibe las variables de correo, `NOTIFICATION_WEB_URL`, las llaves VAPID y `EXPO_ACCESS_TOKEN`
(el backend ya no las usa). **Las llaves VAPID deben ser las que tenía el backend**: cada navegador
liga su suscripción a la pública, y con otras dejaría de recibir push.

Es el único que atiende los eventos de cuenta y los códigos de correo y que entrega las alertas y
recomendaciones: el backend ya no tiene módulo de notificaciones. Tres interruptores, encendidos por
defecto; en `false` solo sirven para volver atrás a un backend que aún tenga el módulo (el cuarto,
de la actividad, se explica más abajo):

| Variable | Servicio | Qué enciende |
|---|---|---|
| `SECURITY_EVENTS_CONSUMER_ENABLED` | notification | Colas `notification-service.notification.account-events` y `.mail`: notificaciones de administrador, limpieza de cuentas borradas y envío de los códigos |
| `ALERT_EVENTS_CONSUMER_ENABLED` | notification | Colas `notification-service.notification.alert-raised` y `.recommendation-created`: entrega de alertas y recomendaciones |
| `ALERT_OUTBOX_RELAY_ENABLED` | backend | Publica `alert.raised` y `recommendation.created` desde `backend_outbox` |
| `ACTIVITY_CONSUMER_ENABLED` | notification | Cola `notification-service.notification.activity`: bienvenida y actividad de hogares y dispositivos |

Con el relay apagado el backend guarda sus eventos en `backend_outbox` sin publicarlos, y los
publica en orden cuando se enciende.

**Primer despliegue con el servicio de notificaciones:** el contenedor `notification` debe estar
arriba **antes** que el gateway con las rutas nuevas; si no, esas rutas responden 503.

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. Clona `en-monitor-notification-service` en `backend/` (`-b main`) y agrega a `.env.prod`
   `NOTIFICATION_CONTEXT`. No necesita secretos nuevos: usa los de correo, VAPID, Expo,
   `MYSQL_PASSWORD`, `RABBITMQ_*` e `INTERNAL_API_TOKEN` que ya tiene el backend.
3. `deploy/deploy.sh infra`: construye el servicio de notificaciones con los interruptores
   apagados. Los changesets `notification-001` a `notification-005` ya aplicados por el backend se
   reconocen en `DATABASECHANGELOG` y no se ejecuta ninguno.
4. `deploy/deploy.sh backend`, con el outbox (changeset `outbox-001`, relay apagado), y después
   `deploy/deploy.sh gateway`, con las rutas al servicio.

**Corte desde ese despliegue** (el servicio de notificaciones con los interruptores apagados y el
backend con su módulo de notificaciones):

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. Descarta las alertas y recomendaciones que el backend guardó en el outbox mientras las entregaba
   él mismo; si no, el servicio las enviaría otra vez:

   ```bash
   docker compose -f docker-compose.prod.yml --env-file .env.prod exec mysql \
     sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" energy_monitor -e "UPDATE backend_outbox SET discarded_at = NOW() WHERE published_at IS NULL AND discarded_at IS NULL"'
   ```

3. `deploy/deploy.sh infra`: recrea `notification` con los consumidores encendidos y el backend
   con el relay encendido, sin las variables de correo, push y `SECURITY_SERVICE_URL`.
4. Enseguida `deploy/deploy.sh backend`, con el backend sin módulo de notificaciones. Entre los dos
   pasos el backend todavía entrega en proceso y el servicio también: un código de correo no sale
   dos veces (el id del mensaje es el id del envío en la tabla compartida), pero una alerta o una
   notificación de administrador de ese intervalo puede llegar dos veces. El orden inverso dejaría
   ese intervalo sin códigos ni alertas.
5. Las colas del backend ya no tienen consumidor y se llenarían con cada evento de cuenta: bórralas.
   El servicio recibe los mismos mensajes en las suyas.

   ```bash
   for q in energy-monitor-backend.notification.account-events energy-monitor-backend.notification.mail; do
     for s in "" .dlq; do
       docker compose -f docker-compose.prod.yml --env-file .env.prod exec rabbitmq \
         rabbitmqctl delete_queue "$q$s"
     done
   done
   ```

6. Si habías puesto `SECURITY_EVENTS_CONSUMER_ENABLED`, `ALERT_EVENTS_CONSUMER_ENABLED` o
   `ALERT_OUTBOX_RELAY_ENABLED` en `false` en `.env.prod`, bórralos.

**Volver atrás** a un backend con módulo de notificaciones: pon los tres interruptores en `false`
en `.env.prod`, `deploy/deploy.sh infra` y despliega esa versión del backend.

#### Notificaciones de actividad

Además de las alertas y recomendaciones, el servicio cuenta a cada persona lo que pasó en su cuenta
y en sus hogares, por los canales que eligió en Configuración (correo y push) y siempre en la
bandeja de la web y la app (pestaña **Actividad**, con filtro por hogar):

| Evento | Lo publica | A quién le llega |
|---|---|---|
| `account.first-signed-in` | security, en el primer ingreso de una cuenta verificada | La cuenta: bienvenida |
| `home.created` | home | Quien lo creó |
| `home.member-joined` | home | Quien se unió ("te uniste") y los demás miembros |
| `home.thresholds-updated` | home | Los miembros, menos quien los cambió |
| `home.member-left` | home | Los miembros que quedan |
| `home.member-removed` | home | Quien fue quitado y los demás, menos el propietario que lo quitó |
| `home.ownership-transferred` | home | El nuevo propietario, el anterior y los demás, cada uno con su texto |
| `home.deleted` | home | Los miembros que tenía; quien lo borró, con su texto |
| `device.linked` / `device.unlinked` | device | Los miembros del hogar |

Todo entra por una sola cola, `notification-service.notification.activity` (con su `.dlq`), que el
servicio declara al arrancar si `ACTIVITY_CONSUMER_ENABLED` no es `false`. Un mensaje repetido se
descarta por su id. Cada notificación guarda la clave del texto (`activity.home.member-joined.v1`)
y los nombres de ese momento (`message_params`, changeset `notification-007`): la web y la app la
traducen al idioma del usuario, y "Se eliminó «Casa»" se sigue leyendo aunque el hogar ya no exista.
`home.deleted` y `home.ownership-transferred` traen ahora el nombre del hogar y sus miembros; el
servicio de dispositivos ignora los campos que no conoce.

**Despliegue: primero `notification`, después `security` y `home`.** Los dos publican estos eventos
desde su outbox, y un outbox se detiene ante un mensaje que ninguna cola recibe: si salen antes de
que exista la cola, sus demás eventos (`account.deleted`, `home.deleted`, …) quedan esperando
detrás.

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. `deploy/deploy.sh notification`: aplica `notification-006` y `notification-007` y declara la cola.
   Comprueba que existe:

   ```bash
   docker compose -f docker-compose.prod.yml --env-file .env.prod exec rabbitmq \
     rabbitmqctl list_queues name messages | grep notification.activity
   ```

3. `deploy/deploy.sh security` y `deploy/deploy.sh home`, en cualquier orden.
4. `deploy/deploy.sh frontend`; la app móvil, con su próxima versión. Las dos piden la actividad a
   `/api/v1/notifications/activity`, que el gateway ya manda al servicio.

**Volver atrás:** las versiones anteriores de seguridad y hogares no publican estos eventos, así
que basta con desplegarlas. Para dejar de entregar la actividad sin bajar de versión, pon
`ACTIVITY_CONSUMER_ENABLED=false` en `.env.prod` y `deploy/deploy.sh infra`; **antes** borra la cola
y su `.dlq` (`rabbitmqctl delete_queue`), o se llenaría con cada evento.

### Servicio de alertas

`alert` crea las alertas de un hogar —una lectura sobre el umbral de potencia (HIGH/CRITICAL), el
límite de consumo del hogar alcanzado, un dispositivo que perdió la conexión y la primera lectura de
un dispositivo recién vinculado— y las anuncia (`alert.raised`) al servicio de notificaciones, que
las entrega. El gateway le manda `/api/v1/alerts/**`, con las mismas rutas y respuestas que tenía el
backend. Pregunta a hogares (quién es miembro y los límites), a dispositivos (el hogar de un
dispositivo) y a mediciones (niveles de consumo y energía). Usa la tabla `alert`, la misma que el
backend, y su propio outbox, `alert_outbox` (changeset `alert-004`).

| Variable | Servicio | Qué enciende |
|---|---|---|
| `ALERT_CONSUMERS_ENABLED` | alert | Colas `alert-service.measurement.recorded` y `alert-service.device.events`: crear las alertas. **Apagado** por defecto |
| `ALERT_SERVICE_OUTBOX_RELAY_ENABLED` | alert | Publica `alert.raised` desde `alert_outbox`. Encendido por defecto |

Las dos colas se declaran siempre al arrancar, con el interruptor apagado también: así acumulan las
lecturas y los eventos de dispositivos mientras el backend todavía crea las alertas desde las suyas.
Con los dos creándolas, cada alerta saldría dos veces.

**Primer despliegue con el servicio de alertas** (el backend sigue creando las alertas):

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. Clona `en-monitor-alert-service` en `backend/` (`-b main`) y agrega a `.env.prod`
   `ALERT_CONTEXT`. No necesita secretos nuevos: usa `MYSQL_PASSWORD`, `RABBITMQ_*`,
   `INTERNAL_API_TOKEN` y la llave pública que ya tienen los otros servicios.
3. `deploy/deploy.sh infra`: construye `alert` con los consumidores apagados. Los changesets
   `alert-001` a `alert-003` ya aplicados por el backend se reconocen en `DATABASECHANGELOG`; solo
   se ejecuta `alert-004` (crea `alert_outbox`).
4. `deploy/deploy.sh gateway`, con `/api/v1/alerts/**` al servicio. **Después** del paso 3: con el
   gateway nuevo y sin el contenedor, las alertas responden 503. Las dos versiones leen la misma
   tabla, así que la web y la app ven las mismas alertas.

**Corte**, cuando `main` del backend ya no tenga el módulo de alertas:

1. Respaldo de MySQL (`deploy/backup-mysql.sh`).
2. Vacía las colas del servicio. Lo que guardan ya lo procesó el backend, y una lectura vieja podría
   volver a crear una alerta que ya se resolvió:

   ```bash
   for q in alert-service.measurement.recorded alert-service.device.events; do
     docker compose -f docker-compose.prod.yml --env-file .env.prod exec rabbitmq \
       rabbitmqctl purge_queue "$q"
   done
   ```

3. Enseguida `deploy/deploy.sh backend`, el backend sin módulo de alertas. Desde aquí nadie crea
   alertas, pero no se pierde nada: las colas del servicio guardan lo que va llegando.
4. Pon `ALERT_CONSUMERS_ENABLED=true` en `.env.prod` y `deploy/deploy.sh infra`: el servicio
   procesa lo que se acumuló desde el paso 3 y sigue. Solo lo que llegó entre los pasos 2 y 3 lo
   procesan los dos; una alerta que el backend dejó pendiente no se repite, porque las reglas
   miran la misma tabla.
5. El backend sin alertas ya no consume `energy-monitor-backend.measurement.recorded`: bórrala
   con su `.dlq`, o se llenaría con cada lectura. Su cola `energy-monitor-backend.device.events`
   sigue (escucha los vínculos para las recomendaciones), pero RabbitMQ conserva las uniones a
   `device.connectivity-*` de la versión anterior: bórrala también y reinicia el backend, que la
   declara de nuevo solo con `device.linked` y `device.unlinked`. Mientras tanto descarta esos
   eventos sin error.

   ```bash
   for q in energy-monitor-backend.measurement.recorded energy-monitor-backend.device.events; do
     for s in "" .dlq; do
       docker compose -f docker-compose.prod.yml --env-file .env.prod exec rabbitmq \
         rabbitmqctl delete_queue "$q$s"
     done
   done
   docker compose -f docker-compose.prod.yml --env-file .env.prod restart backend
   ```

**Volver atrás:** `ALERT_CONSUMERS_ENABLED=false` en `.env.prod`, `deploy/deploy.sh infra` y
despliega una versión del backend con el módulo de alertas. El gateway puede quedar como está.

## CI/CD con GitHub Actions

Cada repositorio (gateway, servicios de seguridad, dispositivos, mediciones y hogares, backend, web e infra) tiene
`.github/workflows/ci-cd.yml`:

- **CI** en cada PR y push a `dev`/`main`: backend y servicios de seguridad, dispositivos, mediciones y hogares `./mvnw test` contra
  MySQL 8.4 (servicio del runner), gateway `./mvnw test` (no necesita nada más), web `vitest` +
  `npm run build`, infra `docker compose config` de los tres modos, `shellcheck` y `nginx -t` de la
  plantilla.
- **CD** solo desde `main` (push o _Run workflow_), después de los tests y de la aprobación del
  environment `production`: entra por SSH al VPS y ejecuta
  `deploy/deploy.sh backend|security|device|measurement|home|gateway|frontend|infra`. El script respalda MySQL, hace
  `git pull` de `main`, reconstruye solo ese servicio y espera a que los seis servicios Java estén
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
  la conectividad y es el único que publica comandos; el servicio de mediciones
  (`MQTT_MEASUREMENT_SERVICE_USER`) solo lee la telemetría para guardar las lecturas. Los dos por
  el listener interno sin TLS (`MQTT_BROKER_URL=tcp://mosquitto:1883`). El backend no se conecta
  al broker: oye cada lectura por RabbitMQ (`measurement.recorded`) para las alertas.
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

| Puerto | Servicio         | Para qué                                                         |
| ------ | ---------------- | ---------------------------------------------------------------- |
| 80     | frontend (nginx) | La web; reenvía `/api/` al gateway.                              |
| 8080   | gateway          | La API para la app móvil en la LAN (`http://<IP de LAN>:8080`).  |
| 8883   | mosquitto        | MQTT sobre TLS, para los dispositivos.                           |
| 1883   | mosquitto        | MQTT sin TLS, solo en `127.0.0.1`.                               |
| 3306   | mysql            | Base de datos, solo en `127.0.0.1` (para depurar desde este PC). |
| 5672   | rabbitmq         | AMQP, solo en `127.0.0.1` (servicios del PC en modo desarrollo). |
| 15672  | rabbitmq         | Consola web, solo en `127.0.0.1`.                                |

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
docker compose ps                                                     # gateway, security, device, measurement, home, notification, backend (healthy)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/          # 200 (web)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/v1/homes  # 401 sin sesión: lo responde el gateway
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' \
  http://localhost/api/v1/auth/login                                  # 400: llegó al servicio de seguridad
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/v1/appliance-types  # 401: ruta del servicio de dispositivos
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/v1/consumption-levels  # 401: ruta del servicio de mediciones
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/v1/home-types  # 401: ruta del servicio de hogares
# MQTT: los dos servicios ya están suscritos; confírmalo en el log del broker
docker compose logs mosquitto | grep "New client connected"          # ... u'em-measurement-service' y u'em-device-service'
```

### Prueba de punta a punta (servicio de dispositivos)

Con la pila completa arriba y los cinco servicios `(healthy)`:

```bash
./e2e/device-flow.sh
```

Crea una cuenta (`MAIL_USERNAME` con el sufijo `+e2e-…`, porque el registro exige un dominio que
reciba correo) y un hogar de prueba; comprueba que el registro responde 202 sin crear la cuenta,
que sin verificar el correo el login responde 403, y verifica la dirección por la API con el código
calculado como lo calcula el servicio de seguridad (con `SECURITY_RESET_PEPPER` del `.env`): ahí se
crea la cuenta y se borra la solicitud de registro. Luego recorre lo que cruza los servicios:
rutas del gateway, vincular un módulo (el servicio de dispositivos pregunta al backend), el broker
autenticando contra `device:8084` (clave correcta e incorrecta), telemetría (`ONLINE` en el servicio
de dispositivos y la lectura guardada en el servicio de mediciones), estado `offline` (evento
`device.connectivity-lost` y alerta `CONNECTIVITY` en el backend) y borrar el hogar (`home.deleted`:
el módulo queda desvinculado y recibe el comando `unlink`). Termina con el número de comprobaciones
que pasaron y sale con error si alguna falla. No imprime la API key del módulo. Usa `jq` y
`openssl`, y `mosquitto_pub` dentro del contenedor del broker.

Publicar telemetría de prueba requiere un dispositivo aprovisionado (su `device_code`/`api_key`)
o las credenciales del backend con ACL de publicación; el broker **no** acepta clientes anónimos.

### Prueba de punta a punta (servicio de mediciones)

```bash
./e2e/measurement-flow.sh
```

Con la misma clase de cuenta y hogar de prueba, vincula un módulo y publica dos lecturas por el
broker. Comprueba que el servicio de mediciones guarda cada una **una sola vez** (el backend ya no
se suscribe), que la anuncia por su outbox (`measurement.recorded`), que la lectura alta levanta
la alerta `THRESHOLD` en el backend con el nivel que lee del servicio y la baja la resuelve, que el
consumo del hogar, el historial, las estadísticas y los niveles responden por el gateway, y que
`energy-monitor-backend.measurement.recorded` y su `.dlq` quedan vacías. Al final borra el hogar.

### Prueba de punta a punta (notificaciones de actividad)

```bash
./e2e/activity-flow.sh
```

Crea tres cuentas de prueba (Ana, Luis y Sara, con el mismo sufijo `+e2e-…`) y recorre cada evento
de la tabla de "Notificaciones de actividad": la bienvenida del primer ingreso (y que un segundo
ingreso no la repite), crear el hogar, unirse, cambiar los umbrales, vincular un módulo, salir,
transferir el hogar, quitar a un miembro y borrarlo. Para cada uno comprueba que llega a quien
debe, con los nombres guardados, y no a quien no (quien cambió los umbrales, o quien ya no es
miembro cuando se borra el hogar). Espera a que los outboxes de seguridad, hogares y dispositivos
queden publicados y la cola de actividad y su `.dlq` vacías, y prueba la bandeja: filtro por hogar,
marcar una o todas como leídas, eliminar, y que otra cuenta no puede tocarla. Luis y Sara apagan el
correo y el push al empezar, y la prueba comprueba que no reciben ninguno pero sí ven todo en la
bandeja. Con `MAIL_HOST` configurado, Ana deja el correo encendido, así que ese buzón recibe unos
ocho correos de la prueba.

### Prueba de punta a punta (servicio de alertas)

Con la pila como queda después del corte de "Servicio de alertas": el backend sin módulo de
alertas y el servicio con sus consumidores encendidos. En local, sin tocar `.env`:

```bash
ALERT_CONSUMERS_ENABLED=true docker compose up -d alert
./e2e/alert-flow.sh
```

Crea una cuenta de prueba (`+e2e-alert-…`), un hogar y un módulo. Comprueba que el servicio
consume sus dos colas y que el backend ya no consume las lecturas. Después recorre una alerta de
punta a punta:
- **Umbral:** una lectura alta guardada por mediciones llega por `measurement.recorded` y crea
  **una** alerta THRESHOLD que apunta a esa lectura, aunque llegue otra lectura alta. Su
  `alert.raised` sale de `alert_outbox` y notificaciones lo consume sin dejar nada en la `.dlq`. Una
  lectura baja la resuelve.
- **Dispositivo vinculado:** la primera lectura crea la alerta DEVICE.
- **Conectividad:** el estado offline crea una alerta CONNECTIVITY y la telemetría siguiente la
  resuelve.
- **API por el gateway:** un hogar ajeno da 404, marcar como leída una alerta del sistema da 409,
  y se borran una alerta y las resueltas del hogar.

Al final espera las colas del servicio vacías y sin nada en sus `.dlq`, y borra el hogar.

## Solución de problemas

- **`required variable X is missing a value: X is required`** al levantar la pila: `X` está vacía
  en `infra/.env`, o falta su línea. Rellénala (sección "Variables de entorno") y repite
  `docker compose config -q` hasta que no nombre ninguna.

- **`ERROR 1045 ... Access denied for user 'root'@'localhost'`** al usar `docker exec ... mysql -u root -p`:
  la contraseña de `root` es la de `MYSQL_ROOT_PASSWORD` en `.env`. Usa la variable, no la escribas a mano:

  ```bash
  docker exec -e MYSQL_PWD="$(grep '^MYSQL_ROOT_PASSWORD=' .env | cut -d= -f2-)" \
    -it energy-monitor-mysql mysql -uroot energy_monitor
  ```

  El usuario de la aplicación es `energy_app` con `MYSQL_PASSWORD` (no `root`).

- **`origin_mismatch` al iniciar sesión con Google:** falta `http://localhost` en
  _Authorized JavaScript origins_ del cliente OAuth (ver sección de cuentas arriba) y, en
  modo _Testing_, la cuenta en _Test users_.

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
  reconoce sus credenciales. Para el servicio de mediciones y el propio servicio, `MQTT_MEASUREMENT_SERVICE_USER/PASS` y
  `MQTT_DEVICE_SERVICE_USER/PASS` deben ser los mismos en el contenedor (o el `.env`) de quien se
  conecta y en el del servicio de dispositivos.

- **Los servicios tardan ~2 min en el primer arranque:** Liquibase
  ejecuta sus changesets sobre la base nueva. Es normal; espera a `(healthy)` en `docker compose ps`.

- **La API responde `503` por la web:** el gateway no alcanza al servicio de esa ruta. Mira
  `docker compose ps` y `docker compose logs security device measurement home backend`.

- **El servicio de seguridad queda `unhealthy` con RabbitMQ arriba:** `RABBITMQ_USERNAME` /
  `RABBITMQ_PASSWORD` no coinciden con el usuario que RabbitMQ creó la primera vez que arrancó su
  volumen. Cámbiala dentro con el comando de "Valores que guarda un volumen", o borra el volumen
  `rabbitmq-data` (se pierden los mensajes pendientes).

## Notas

- **Secretos**: `.env`, `.env.prod`, `keys/` y `mosquitto/certs/` están en `.gitignore`; no se versionan.
- **Sesión de la web**: los tokens viajan en cookies HttpOnly que pone el servicio de seguridad
  (ver su README, "Sessions"). `docker-compose.yml` las deja sin `Secure` porque la pila local se
  sirve por `http://`; `docker-compose.prod.yml` las marca `Secure` (el sitio va por HTTPS). En
  modo desarrollo el `.env` del servicio de seguridad lleva `SECURITY_SESSION_COOKIE_SECURE=false`.
  `INTERNAL_API_TOKEN` y `RABBITMQ_PASSWORD` son los mismos en todos los servicios: en la pila los toma
  cada contenedor de este `.env`.
- **Producción**: en un servidor se usa `docker-compose.prod.yml` (sección "Producción"), no la
  pila local.
- **Certificados**: si cambia la IP de LAN del PC, actualiza `DEVICE_MQTT_PUBLIC_HOST` y vuelve a
  ejecutar `./prepare.sh` (reemite el certificado del broker con las IPs actuales más
  `DEVICE_MQTT_PUBLIC_HOST`; la CA se reutiliza, así que no hace falta reflashear).
