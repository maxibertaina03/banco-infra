#!/usr/bin/env bash
#
# Emite los certificados la primera vez y activa los server blocks de HTTPS.
#
# Se corre UNA vez, después del primer `docker compose up -d`. Las renovaciones
# las hace solo el contenedor `certbot`, cada 12 horas.
#
#   ./scripts/certificados.sh            emite de verdad
#   ./scripts/certificados.sh --prueba   usa el entorno de staging de Let's
#                                        Encrypt, que no tiene límite de
#                                        intentos. El navegador va a desconfiar
#                                        del certificado: es sólo para ensayar.
#
# Let's Encrypt permite 5 emisiones fallidas por hora y por dominio. Si algo
# está mal (un registro DNS que todavía no propagó, el puerto 80 cerrado),
# conviene probar primero con --prueba y no quemar los intentos buenos.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "Falta el archivo .env. Copiá .env.example y completalo." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

: "${DOMINIO:?Falta DOMINIO en .env}"
: "${DOMINIO_APP:?Falta DOMINIO_APP en .env}"
# Ojo con los apóstrofos acá adentro: dentro de ${VAR:?mensaje} bash los trata
# como comilla de apertura y se come el resto del archivo. Por eso dice
# "la autoridad" y no "Let's Encrypt".
: "${CERTBOT_EMAIL:?Falta CERTBOT_EMAIL en .env (es donde la autoridad avisa si algo falla)}"

# El ensayo usa un NOMBRE DE CERTIFICADO distinto del real.
#
# Si los dos usaran el mismo, pasa esto: el ensayo deja un certificado de
# staging en /etc/letsencrypt/live/$DOMINIO/, y cuando después pedís el de
# verdad, certbot ve que ya hay uno y contesta "not yet due for renewal; no
# action taken". Te quedás con el de mentira puesto y el navegador lo rechaza.
STAGING=""
NOMBRE_CERT="$DOMINIO"
if [[ "${1:-}" == "--prueba" ]]; then
  STAGING="--staging"
  NOMBRE_CERT="$DOMINIO-ensayo"
  echo "→ Modo prueba: certificados de staging, no sirven para el navegador."
fi

echo "→ Dominios: $DOMINIO, www.$DOMINIO, $DOMINIO_APP"

# El desafío se resuelve por HTTP, así que nginx tiene que estar arriba y el
# puerto 80 abierto desde internet.
if ! docker compose ps proxy --status running --quiet | grep -q .; then
  echo "nginx no está corriendo. Levantalo con: docker compose up -d proxy" >&2
  exit 1
fi

echo "→ Pidiendo el certificado a Let's Encrypt…"
docker compose run --rm --entrypoint certbot certbot \
  certonly --webroot -w /var/www/certbot \
  $STAGING \
  --cert-name "$NOMBRE_CERT" \
  --email "$CERTBOT_EMAIL" \
  --agree-tos --no-eff-email \
  --non-interactive \
  -d "$DOMINIO" -d "www.$DOMINIO" -d "$DOMINIO_APP"

if [[ -n "$STAGING" ]]; then
  echo
  echo "Ensayo terminado sin errores. nginx NO se tocó: un certificado de"
  echo "staging no sirve para el navegador."
  echo "Ahora pedí el de verdad:   ./scripts/certificados.sh"
  exit 0
fi

echo "→ Activando los server blocks de HTTPS…"
for plantilla in nginx/plantillas/*.conf; do
  destino="nginx/https.d/$(basename "$plantilla")"
  sed -e "s/__DOMINIO_APP__/$DOMINIO_APP/g" -e "s/__DOMINIO__/$DOMINIO/g" "$plantilla" > "$destino"
  echo "   $destino"
done

echo "→ Validando la configuración antes de aplicarla…"
docker compose exec proxy nginx -t

docker compose exec proxy nginx -s reload

echo
echo "Listo. Probá:"
echo "   curl -I https://$DOMINIO_APP"
echo "   curl -s https://$DOMINIO_APP/api/health"
echo
echo "Y confirmá que la renovación automática va a funcionar:"
echo "   docker compose run --rm --entrypoint certbot certbot renew --dry-run"
