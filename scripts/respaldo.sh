#!/usr/bin/env bash
#
# Copia de seguridad de la base.
#
#   ./scripts/respaldo.sh            un dump comprimido en ./respaldos
#   ./scripts/respaldo.sh --listar   qué respaldos hay y cuánto pesan
#
# POR QUÉ EXISTE ESTO
#
# El snapshot que vende DigitalOcean respalda el *droplet*: nginx, los .env, los
# contenedores. No respalda un solo peso del banco, porque los datos están en
# Supabase, que es otra máquina de otra empresa. Si mañana se borra el proyecto
# de Supabase —o se pausa por inactividad y se pierde, que en el plan gratis
# pasa— el snapshot del droplet no sirve para recuperar ni una transferencia.
# Esto sí.
#
# LA TRAMPA QUE SÍ NOS COMIMOS
#
# pg_dump tiene que ser de una versión mayor o igual a la del servidor. Supabase
# corre PostgreSQL 17 y Ubuntu 24.04 trae el cliente 16, así que
# `apt install postgresql-client` y después pg_dump da un error de versión y no
# dumpea nada. Por eso corre adentro de un contenedor con la 17: no hay que
# instalar ni mantener nada en el droplet.
#
# (Sobre el puerto: el DATABASE_URL de la app usa el 6543, el pooler en modo
# transacción. Probamos y pg_dump anda igual por ahí, pero el script lo pasa al
# 5432, que es el modo sesión. Es lo que recomienda Supabase para dumps y, de
# paso, el dump no le compite las conexiones del pooler a la app mientras
# corre.)

set -euo pipefail

cd "$(dirname "$0")/.."
RAIZ="$(cd .. && pwd)"

# Fuera del repo a propósito: adentro, un `git add -A` distraído commitea la
# base entera del banco —DNIs, correos, saldos— a GitHub. En el droplet esto
# es /opt/orbital/respaldos.
DESTINO="${RESPALDOS_DIR:-$RAIZ/respaldos}"
DIAS_A_GUARDAR="${DIAS_A_GUARDAR:-14}"
IMAGEN="postgres:17-alpine"

if [[ "${1:-}" == "--listar" ]]; then
  if [[ -d "$DESTINO" ]] && compgen -G "$DESTINO/*.sql.gz" >/dev/null; then
    ls -lh "$DESTINO"/*.sql.gz | awk '{print $9, "\t", $5, "\t", $6, $7, $8}'
    echo
    du -sh "$DESTINO"
  else
    echo "Todavía no hay ningún respaldo en $DESTINO"
  fi
  exit 0
fi

# El .env del backend es el único lugar donde vive la URL de la base. No se
# imprime nunca: tiene la contraseña adentro.
ARCHIVO_ENV="$RAIZ/banco-backend/.env"
[[ -f "$ARCHIVO_ENV" ]] || { echo "No encuentro $ARCHIVO_ENV"; exit 1; }

URL="$(grep -E '^DATABASE_URL=' "$ARCHIVO_ENV" | head -1 | cut -d= -f2- | tr -d '"'"'"'')"
[[ -n "$URL" ]] || { echo "No hay DATABASE_URL en $ARCHIVO_ENV"; exit 1; }

# 6543 (transacción) → 5432 (sesión). Ver la nota del encabezado.
URL_DUMP="${URL/:6543\//:5432/}"
if [[ "$URL" != "$URL_DUMP" ]]; then
  echo "→ Dump por el pooler en modo sesión (5432)"
fi

mkdir -p "$DESTINO"
SALIDA="$DESTINO/orbital-$(date +%Y%m%d-%H%M).sql.gz"

echo "→ Respaldando a $(basename "$SALIDA")"

# --no-owner y --no-acl: los roles de Supabase no existen en otra base, y sin
# esto el restore escupe un error por cada tabla.
# --clean --if-exists: el dump se puede restaurar sobre una base con datos.
# La URL va por variable de entorno, no por argumento, así no queda en el
# `ps` de nadie mientras corre.
if ! docker run --rm -i -e PGURL="$URL_DUMP" "$IMAGEN" \
  sh -c 'pg_dump "$PGURL" --no-owner --no-acl --clean --if-exists' \
  | gzip -9 > "$SALIDA"; then
  echo "Falló el dump. Borro el archivo a medias para que no parezca un respaldo bueno."
  rm -f "$SALIDA"
  exit 1
fi

# Un dump que no tiene el final que escribe pg_dump quedó cortado a la mitad:
# la conexión se cayó, se llenó el disco, lo que sea. Mejor enterarse ahora que
# el día que haga falta restaurarlo.
if ! zcat "$SALIDA" | tail -5 | grep -q 'PostgreSQL database dump complete'; then
  echo "El dump quedó incompleto (no tiene la marca de cierre). Lo borro."
  rm -f "$SALIDA"
  exit 1
fi

TABLAS="$(zcat "$SALIDA" | grep -c '^CREATE TABLE' || true)"
echo "   $(du -h "$SALIDA" | cut -f1) · $TABLAS tablas"

# Rotación. Sin esto el disco de 10 GB se llena solo en unos meses.
BORRADOS="$(find "$DESTINO" -name 'orbital-*.sql.gz' -mtime "+$DIAS_A_GUARDAR" -print -delete | wc -l)"
[[ "$BORRADOS" -gt 0 ]] && echo "→ Borrados $BORRADOS respaldos de más de $DIAS_A_GUARDAR días"

echo "Listo. Hay $(find "$DESTINO" -name 'orbital-*.sql.gz' | wc -l) respaldos, $(du -sh "$DESTINO" | cut -f1) en total."
