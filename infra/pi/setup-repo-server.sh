#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 5 — servidor de repo de paquetes en la Raspberry Pi 5
# ------------------------------------------------------------------------------
# Este script NO corre en el contenedor de build (Podman/Windows) -- corre
# DIRECTO en la Raspberry Pi, por SSH, como root o con sudo. Asume Raspberry
# Pi OS (Debian) con apt, que es lo que confirmaste que ya tenés andando.
#
# Qué hace:
#   1. Instala nginx (si no está) para servir el repo de paquetes por HTTP.
#   2. Crea la estructura de directorios que espera `apk` -- mismo layout que
#      usa Alpine: <raíz>/<rama>/<repositorio>/<arquitectura>/. Acá usamos
#      "edge/main/x86_64" porque LINSI-OS compila para x86_64-linsi-linux-gnu
#      (el triplet propio del proyecto, misma arquitectura que x86_64 común) --
#      NO tiene nada que ver con que la Pi en sí sea aarch64, la Pi sólo sirve
#      los archivos, no los ejecuta.
#   3. Deja nginx escuchando SOLO en 127.0.0.1:8088 -- a propósito, nada
#      público en la Pi directo. Todo el tráfico externo entra por el túnel
#      Zero Trust de Cloudflare (que vos ya tenés andando), que es quien habla
#      con este puerto local. Si nginx escuchara en todas las interfaces,
#      el túnel dejaría de ser la única puerta de entrada real.
#      (8088 en vez de 8080 porque el 8080 ya lo tenías ocupado -- si hace
#      falta cambiarlo de nuevo más adelante, no edites el número a mano acá
#      abajo: corré el script con LINSI_REPO_PORT=<otro-puerto> adelante.)
#
# Uso (en la Pi):
#   sudo bash setup-repo-server.sh
#   sudo LINSI_REPO_PORT=9090 bash setup-repo-server.sh   # para usar otro puerto
# ==============================================================================
set -euo pipefail

REPO_ROOT="/srv/linsi-os"
REPO_ARCH_DIR="${REPO_ROOT}/edge/main/x86_64"
LISTEN_ADDR="127.0.0.1"
LISTEN_PORT="${LINSI_REPO_PORT:-8088}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "[error] corré esto con sudo/root (necesita instalar paquetes y escribir en /etc/nginx)" >&2
    exit 1
fi

echo "[setup-repo-server] instalando nginx si hace falta..."
if ! command -v nginx >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends nginx-light
else
    echo "[setup-repo-server] nginx ya está instalado"
fi

echo "[setup-repo-server] creando ${REPO_ARCH_DIR}"
mkdir -p "${REPO_ARCH_DIR}"
# El dueño real de los archivos que se copien acá después (desde el CI/CD o a
# mano) queda a tu criterio -- www-data sólo necesita LECTURA para servirlos.
chown -R root:www-data "${REPO_ROOT}"
find "${REPO_ROOT}" -type d -exec chmod 750 {} +

SITE_CONF="/etc/nginx/sites-available/linsi-os-repo"
cat > "${SITE_CONF}" <<EOF
# LINSI-OS · Fase 5 — repo de paquetes, sólo accesible vía el túnel de
# Cloudflare (que apunta acá, a 127.0.0.1:${LISTEN_PORT}).
server {
    listen ${LISTEN_ADDR}:${LISTEN_PORT};
    server_name _;

    root ${REPO_ROOT};
    autoindex on;
    autoindex_exact_size off;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf "${SITE_CONF}" /etc/nginx/sites-enabled/linsi-os-repo
# El "default" de Debian escucha en el puerto 80 público -- lo sacamos para no
# dejar un server_name _ compitiendo/confundiendo, ya que acá no queremos NADA
# público directo en la Pi (todo entra por el túnel).
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo
echo "[setup-repo-server] listo."
echo "  -> repo servido en http://${LISTEN_ADDR}:${LISTEN_PORT}/edge/main/x86_64/"
echo "  -> directorio real: ${REPO_ARCH_DIR}"
echo "  -> falta: apuntar el túnel de Cloudflare a http://${LISTEN_ADDR}:${LISTEN_PORT}"
echo "     (ver infra/pi/cloudflared-ingress-snippet.yml)"
