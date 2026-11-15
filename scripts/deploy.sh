#!/usr/bin/env bash
#
# Actualizar lo que está corriendo en el droplet.
#
#   ./scripts/deploy.sh              todo
#   ./scripts/deploy.sh backend      sólo un servicio
#
# Baja las imágenes que GitHub Actions ya construyó y reinicia lo que cambió.
#
# Antes esto clonaba los cuatro repos y compilaba acá. En 1 GB de RAM el build
# del portal dejaba la máquina sin aire varios minutos —tanto que no se podía
# ni entrar por SSH mientras duraba— y obligaba a tener el código fuente y la
# clave de Clerk en el servidor. Ahora el servidor sólo necesita este repo.

set -euo pipefail

cd "$(dirname "$0")/.."

SERVICIO="${1:-}"

echo "→ Trayendo los cambios de la infraestructura"
git pull --ff-only --quiet && git log -1 --format='   %h %s'

echo "→ Bajando las imágenes de ghcr.io"
# Si una imagen no cambió, `pull` no baja nada y termina al instante.
docker compose pull $SERVICIO

echo "→ Levantando"
docker compose up -d $SERVICIO

echo "→ Esperando a que estén sanos"
sleep 12
docker compose ps

echo "→ Limpiando imágenes viejas"
# Sin esto, cada deploy deja atrás la imagen anterior y el disco se llena.
docker image prune -f >/dev/null
df -h / | tail -1

echo
echo "Salud de la API:"
docker compose exec -T backend node -e "fetch('http://127.0.0.1:3001/api/health').then(r => r.json()).then(j => console.log(JSON.stringify(j)))"
