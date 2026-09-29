# banco-infra

Todo lo que hace falta para que Banco Orbital viva en un servidor: los
contenedores, nginx, los certificados y el deploy.

La base de datos **no** está acá: sigue siendo la de Supabase. Este repo levanta
la API, el mock de proveedores, el portal compilado y el nginx que los reparte.

```
internet ─→ :443 nginx
              ├── app.orbitalbank.com.ar
              │     ├── /            → frontend (el portal ya compilado)
              │     ├── /api  /auth  → backend:3001
              │     └── /webhooks/   → backend:3001   (Clerk)
              └── orbitalbank.com.ar → landing/
```

---

## Probarlo en tu máquina (sin dominio ni certificados)

```bash
cp .env.example .env                       # y completar
cp env/backend.env.example env/backend.env # y completar
cp env/proveedores.env.example env/proveedores.env

docker compose -f docker-compose.local.yml up --build
```

Portal en http://localhost:8080. **Ojo: usa la base de Supabase de verdad**, así
que lo que toques acá se toca en serio.

---

## Montar el servidor desde cero

### 1. El droplet

DigitalOcean → Create Droplet:

- **Ubuntu 24.04 LTS**
- **Basic / Regular · US$4/mes** (512 MB, 1 vCPU, 10 GB)
- Región **NYC3** (la de mejor latencia desde Argentina)
- Autenticación por **SSH key** (nunca contraseña)

Si no tenés clave todavía:

```bash
ssh-keygen -t ed25519 -C "maxi"
cat ~/.ssh/id_ed25519.pub     # esto es lo que se pega en DigitalOcean
```

### 2. Dejarlo seguro y con swap

Entrando como root la primera vez:

```bash
ssh root@LA_IP

# Usuario propio, para no vivir como root
adduser maxi && usermod -aG sudo maxi
rsync --archive --chown=maxi:maxi ~/.ssh /home/maxi

# Sólo SSH, HTTP y HTTPS
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw --force enable

# Parches de seguridad automáticos
apt update && apt install -y unattended-upgrades
```

**La swap no es opcional en 512 MB**: es lo que permite compilar el portal.

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' >> /etc/sysctl.conf
free -h
```

### 3. Docker

```bash
curl -fsSL https://get.docker.com | sh
usermod -aG docker maxi
# Salir y volver a entrar como maxi para que tome el grupo.
```

### 4. DNS

En el panel del dominio, tres registros **A** apuntando a la IP del droplet:

| Tipo | Nombre | Valor  |
|------|--------|--------|
| A    | `@`    | LA_IP  |
| A    | `www`  | LA_IP  |
| A    | `app`  | LA_IP  |

Antes de seguir, esperar a que resuelvan (puede tardar de minutos a unas horas):

```bash
dig +short app.orbitalbank.com.ar
```

Si no devuelve la IP del droplet, **no sigas**: certbot va a fallar y Let's
Encrypt sólo permite 5 intentos fallidos por hora.

### 5. Clonar y configurar

```bash
sudo mkdir -p /opt/orbital && sudo chown maxi:maxi /opt/orbital && cd /opt/orbital
git clone https://github.com/maxibertaina03/banco-backend.git
git clone https://github.com/maxibertaina03/banco-frontend.git
git clone https://github.com/maxibertaina03/banco-proveedores.git
git clone https://github.com/maxibertaina03/banco-infra.git

cd banco-infra
cp .env.example .env
cp env/backend.env.example env/backend.env
cp env/proveedores.env.example env/proveedores.env
nano .env && nano env/backend.env && nano env/proveedores.env
chmod 600 .env env/*.env
```

En `env/backend.env`, la `DATABASE_URL` tiene que ser la del **Session Pooler**
de Supabase (Connect → Session pooler), no la conexión directa: el droplet sale
por IPv4 y la conexión directa del plan gratis puede resolver sólo por IPv6.

### 6. Levantar y emitir los certificados

```bash
docker compose up -d --build     # tarda unos minutos, la swap trabaja
docker compose ps

./scripts/certificados.sh --prueba   # ensayo, no gasta intentos
./scripts/certificados.sh            # los de verdad
```

El script pide el certificado, activa los server blocks de HTTPS y recarga
nginx. Las renovaciones después las hace solo el contenedor `certbot`.

### 7. Clerk

En el dashboard de Clerk:

- Agregar `https://app.orbitalbank.com.ar` a los dominios permitidos.
- Apuntar el webhook a `https://app.orbitalbank.com.ar/webhooks/clerk`.

Con las claves de desarrollo (`pk_test_…`) el portal funciona, con el cartel de
"Development mode". Pasar a una instancia de producción pide cargar unos CNAME
en el dominio; se puede hacer después sin tocar nada de acá salvo las claves
(y reconstruir el frontend, porque la publicable se hornea en el bundle).

### 8. Comprobar que quedó bien

```bash
curl -s https://app.orbitalbank.com.ar/api/health    # ok:true, db:connected
curl -I https://orbitalbank.com.ar                   # la landing, 200
docker compose ps                                    # todos healthy

# Que la renovación automática va a funcionar en 60 días:
docker compose run --rm --entrypoint certbot certbot renew --dry-run

# Que vuelve solo después de un corte:
sudo reboot
```

Y entrar al portal desde el celular con datos móviles: eso valida DNS,
certificado y el responsive de una sola pasada.

---

## El día a día

```bash
cd /opt/orbital/banco-infra

./scripts/deploy.sh              # traer cambios y actualizar todo
./scripts/deploy.sh backend      # sólo un servicio

docker compose ps                # estado
docker compose logs -f backend   # mirar la API
docker compose restart backend   # reiniciar (apaga ordenado, no corta nada)

free -h                          # memoria
df -h /                          # disco
```

**Las migraciones no las corre ningún contenedor.** Se siguen aplicando desde tu
máquina con psql contra Supabase, como siempre. Es la forma más difícil de
romper la base por accidente.

---

## Cuando algo falla

| Síntoma | Qué mirar |
|---|---|
| `502 Bad Gateway` | `docker compose ps`: algún contenedor caído o unhealthy. `docker compose logs backend`. |
| El portal carga en blanco | Casi siempre el `index.html` viejo en caché del navegador. Recargar con Ctrl+Shift+R. |
| Clerk no aparece | El dominio no está en la lista de permitidos de Clerk, o el `VITE_CLERK_PUBLISHABLE_KEY` con el que se compiló está mal. Ojo: cambiarlo obliga a `--build`, no alcanza con reiniciar. |
| `db: disconnected` en /api/health | La `DATABASE_URL`, o Supabase pausó el proyecto por inactividad. |
| El build se queda colgado | Es la swap. Con 512 MB el frontend tarda 2-4 minutos, no está roto. `docker stats` para confirmar que se mueve. |
| Sin espacio en disco | `docker system prune -af --volumes` (cuidado: `--volumes` borraría los certificados; sin esa bandera es seguro). |
| El certificado venció | `docker compose logs certbot`. Reemitir: `./scripts/certificados.sh`. |

---

## La landing

Hoy `landing/index.html` es un placeholder con un link al portal. Cuando hagas la
landing de verdad, reemplazás el contenido de esa carpeta y listo: nginx ya la
sirve en el dominio raíz y el certificado ya la cubre. Si en algún momento
necesita build propio (Astro, por ejemplo), se agrega como un contenedor más y se
cambia el `root` por un `proxy_pass` en `nginx/plantillas/landing.conf`.
