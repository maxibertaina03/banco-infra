#!/usr/bin/env bash
#
# Actualizar lo que está corriendo en el droplet.
#
#   ./scripts/deploy.sh              todo
#   ./scripts/deploy.sh backend      sólo un servicio
#
# Trae los cambios de los cuatro repos, reconstruye lo que haga falta y limpia
# la basura del build. Ese último paso no es opcional: el disco es de 10 GB y
# las capas viejas de Docker lo llenan en pocos deploys.

set -euo pipefail

cd "$(dirname "$0")/.."
RAIZ="$(cd .. && pwd)"

SERVICIO="${1:-}"

echo "→ Trayendo cambios"
for repo in banco-backend banco-frontend banco-proveedores banco-infra; do
  if [[ -d "$RAIZ/$repo/.git" ]]; then
    printf '   %-20s ' "$repo"
    git -C "$RAIZ/$repo" pull --ff-only --quiet && git -C "$RAIZ/$repo" log -1 --format='%h %s'
  fi
done

echo "→ Construyendo y levantando"
# En 512 MB el build del frontend se apoya en la swap y tarda unos minutos:
# es normal que parezca colgado en "transforming".
docker compose up -d --build $SERVICIO

echo "→ Esperando a que estén sanos"
sleep 15
docker compose ps

echo "→ Limpiando capas viejas"
docker builder prune -f >/dev/null
docker image prune -f >/dev/null
df -h / | tail -1

echo
echo "Salud de la API:"
docker compose exec -T backend node -e "fetch('http://127.0.0.1:3001/api/health').then(r => r.json()).then(j => console.log(JSON.stringify(j)))"
