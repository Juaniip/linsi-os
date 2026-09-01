#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 0 — Entrypoint del contenedor "El Taller"
# ==============================================================================
set -euo pipefail

# shellcheck source=/lfs/scripts/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

mkdir -p "${LFS_SOURCES}" "${LFS_TOOLS}" "${LFS_BUILD}" "${LFS_LOGS}"

# ------------------------------------------------------------------------------
# Log automático por corrida (agregado 2026-08-27 a pedido): cada invocación
# de `podman compose run --rm builder <comando>` queda grabada, sin que haga
# falta acordarse de `| Tee-Object -FilePath ...` del lado de PowerShell.
# Se arma acá (una sola vez, en el ENTRYPOINT), no en cada build-*.sh, porque
# entrypoint.sh es el único punto por el que pasan TODAS las fases.
#
# `exec > >(tee -a "$LOG_FILE") 2>&1` deja el stdout/stderr de este shell
# duplicado hacia el archivo Y hacia la terminal (PowerShell lo sigue viendo
# en vivo, igual que antes) — al ser `exec "$@"` más abajo un exec real (no
# un fork), el comando real (scripts/build-security.sh, por ejemplo) hereda
# esos mismos file descriptors ya redirigidos, así que también queda logueado
# sin que ese script tenga que hacer nada especial.
#
# El nombre de archivo sale del comando + argumento que se le pasó (p.ej.
# "20260827-031845_build-security_all.log"), para poder identificar de un
# vistazo qué corrida es cada log sin tener que abrirlo.
LOG_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_NAME="${LOG_STAMP}_shell"
if [[ $# -gt 0 ]]; then
    LOG_NAME="${LOG_STAMP}_$(basename "${1%.sh}")"
    [[ $# -gt 1 ]] && LOG_NAME="${LOG_NAME}_${2}"
fi
LOG_FILE="${LFS_LOGS}/${LOG_NAME}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "[entrypoint] guardando esta corrida en: ${LOG_FILE}"

cat <<'BANNER'
==============================================================================
  LINSI-OS · Fase 0 — El Taller
  Entorno de construcción aislado (no hereda dependencias del host)
==============================================================================
BANNER

echo "  LFS_TGT       : ${LFS_TGT}"
echo "  LFS_SOURCES   : ${LFS_SOURCES}"
echo "  LFS_TOOLS     : ${LFS_TOOLS}"
echo "  LFS_BUILD     : ${LFS_BUILD}"
echo "  nproc         : $(nproc)"
echo
echo "  Para compilar el cross-toolchain (Binutils + cabeceras Linux + GCC):"
echo "    scripts/build-cross-toolchain.sh"
echo "  Para compilar el kernel endurecido (Fase 1 — requiere el toolchain):"
echo "    scripts/build-kernel.sh"
echo
echo "=============================================================================="
echo

exec "$@"
